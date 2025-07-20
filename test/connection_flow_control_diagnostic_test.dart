import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_udx/src/multiplexer.dart';
import 'package:test/test.dart';
import 'package:dart_udx/udx.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';

void main() {
  group('Connection Flow Control Diagnostic Tests', () {
    late UDX udx;
    late UDXMultiplexer clientMultiplexer;
    late UDXMultiplexer serverMultiplexer;
    late RawDatagramSocket clientRawSocket;
    late RawDatagramSocket serverRawSocket;
    UDPSocket? clientSocket;
    UDPSocket? serverSocket;
    UDXStream? clientStream;
    UDXStream? serverStream;

    setUp(() async {
      udx = UDX();
      clientRawSocket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      serverRawSocket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      clientMultiplexer = UDXMultiplexer(clientRawSocket);
      serverMultiplexer = UDXMultiplexer(serverRawSocket);
    });

    tearDown(() async {
      await clientStream?.close();
      await serverStream?.close();
      clientMultiplexer.close();
      serverMultiplexer.close();
    });

    Future<void> setupTestEnvironment() async {
      final serverAddress = serverRawSocket.address;
      final serverPort = serverRawSocket.port;

      // Create client socket that will connect to the server
      clientSocket = clientMultiplexer.createSocket(udx, serverAddress.address, serverPort);

      final serverConnectionCompleter = Completer<UDPSocket>();
      serverMultiplexer.connections.first.then(serverConnectionCompleter.complete);

      const clientStreamId = 1;
      const serverStreamId = 2;

      print('[DEBUG_LOG] Client creating outgoing stream $clientStreamId to $serverStreamId');
      clientStream = await UDXStream.createOutgoing(
        udx,
        clientSocket!,
        clientStreamId,
        serverStreamId,
        serverAddress.address,
        serverPort,
        initialCwnd: 1472 * 30,
      );
      
      serverSocket = await serverConnectionCompleter.future.timeout(const Duration(seconds: 2));
      await serverSocket!.handshakeComplete;
      await clientSocket!.handshakeComplete;
      
      final serverStreamCreatedCompleter = Completer<UDXStream>();
      serverSocket!.on('stream').listen((event) {
        final newStream = event.data as UDXStream;
        print('[DEBUG_LOG] Server received stream event with ID: ${newStream.id}, expected: $serverStreamId');
        // Accept any stream for now to see what's happening
        if (!serverStreamCreatedCompleter.isCompleted) {
          serverStream = newStream;
          print('[DEBUG_LOG] Server stream accepted with ID: ${newStream.id}');
          serverStreamCreatedCompleter.complete(newStream);
        }
      });
      
      serverSocket!.on('unmatchedUDXPacket').listen((event) {
        final payload = event.data as Map<String, dynamic>;
        final packet = payload['packet'] as UDXPacket;
        print('[DEBUG_LOG] Server received unmatched packet: destId=${packet.destinationStreamId}, srcId=${packet.sourceStreamId}, frames=${packet.frames.map((f) => f.type).toList()}');
      });

      // Check if there are already buffered streams
      final bufferedStreams = serverSocket!.getStreamBuffer();
      print('[DEBUG_LOG] Server has ${bufferedStreams.length} buffered streams');
      if (bufferedStreams.isNotEmpty) {
        serverStream = bufferedStreams.first;
        print('[DEBUG_LOG] Using buffered stream with ID: ${serverStream!.id}');
        serverStreamCreatedCompleter.complete(serverStream!);
      }
      
      serverSocket!.flushStreamBuffer();

      try {
        serverStream = await serverStreamCreatedCompleter.future.timeout(const Duration(seconds: 2));
        print('[DEBUG_LOG] Server stream created with ID: ${serverStream!.id}');
      } catch (e) {
        print('[DEBUG_LOG] Error waiting for server stream: $e');
        print('[DEBUG_LOG] Server socket registered streams: ${serverSocket!.getRegisteredStreamsCount()}');
        throw Exception('Failed to create server stream: $e');
      }

      if (serverStream != null && clientStream != null) {
        final largeStreamWindow = UDPSocket.defaultInitialConnectionWindow * 2;
        serverStream!.setWindow(largeStreamWindow);
        clientStream!.setWindow(largeStreamWindow);
        await Future.delayed(const Duration(milliseconds: 50));
      } else {
        throw Exception('Server or client stream is null after setup');
      }
    }

    void addDiagnosticListeners() {
      clientSocket!.on('processedMaxDataFrame').listen((event) {
        final eventData = event.data as Map<String, dynamic>;
        final maxData = eventData['maxData'] as int;
        final remoteAddress = eventData['remoteAddress'] as String;
        final remotePort = eventData['remotePort'] as int;
        print('[DEBUG_LOG] Client processed MaxDataFrame: maxData=$maxData from $remoteAddress:$remotePort');
      });

      clientSocket!.on('remoteConnectionWindowUpdate').listen((event) {
        final eventData = event.data as Map<String, dynamic>;
        final maxData = eventData['maxData'] as int;
        print('[DEBUG_LOG] Client received remoteConnectionWindowUpdate: maxData=$maxData');
      });

      serverSocket!.on('processedMaxDataFrame').listen((event) {
        final eventData = event.data as Map<String, dynamic>;
        final maxData = eventData['maxData'] as int;
        final remoteAddress = eventData['remoteAddress'] as String;
        final remotePort = eventData['remotePort'] as int;
        print('[DEBUG_LOG] Server processed MaxDataFrame: maxData=$maxData from $remoteAddress:$remotePort');
      });

      serverSocket!.on('remoteConnectionWindowUpdate').listen((event) {
        final eventData = event.data as Map<String, dynamic>;
        final maxData = eventData['maxData'] as int;
        print('[DEBUG_LOG] Server received remoteConnectionWindowUpdate: maxData=$maxData');
      });
    }

    void logDrainConditions(UDXStream stream, UDPSocket socket) {
      final connWindowAvailable = socket.getAvailableConnectionSendWindow();
      print('[DEBUG_LOG] Drain conditions: inflight=${stream.inflight}, cwnd=${stream.cwnd}, remoteReceiveWindow=${stream.remoteReceiveWindow}, connWindowAvailable=$connWindowAvailable');
    }

    test('Diagnostic: MaxDataFrame with streamId=0', () async {
      await setupTestEnvironment();
      addDiagnosticListeners();

      final serverInitialMaxData = UDPSocket.defaultInitialConnectionWindow;
      final dataPart1Size = serverInitialMaxData - 1000;
      final dataPart2Size = 3000;
      final allData = Uint8List.fromList([...Uint8List(dataPart1Size), ...Uint8List.fromList(List.generate(dataPart2Size, (i) => i % 256))]);

      int bytesReceivedByServer = 0;
      final serverReceivesAllData = Completer<void>();

      final periodicLogger = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (clientStream != null && clientSocket != null) {
          logDrainConditions(clientStream!, clientSocket!);
        }
      });

      serverStream!.data.listen((data) {
        bytesReceivedByServer += data.length;
        print('[DEBUG_LOG] Server received ${data.length} bytes, total: $bytesReceivedByServer/${allData.length}');
        if (bytesReceivedByServer >= allData.length) {
          if (!serverReceivesAllData.isCompleted) serverReceivesAllData.complete();
        }
      });

      print('[DEBUG_LOG] Client starting to send ${allData.length} bytes');
      final sendFuture = clientStream!.add(allData);
      await Future.delayed(const Duration(milliseconds: 500));

      print('[DEBUG_LOG] After 500ms: Server received $bytesReceivedByServer/${allData.length} bytes');
      logDrainConditions(clientStream!, clientSocket!);

      final newMaxData = serverInitialMaxData + dataPart2Size + 5000;
      print('[DEBUG_LOG] Server sending MaxDataFrame with streamId=0, newMaxData=$newMaxData');
      await serverSocket!.sendMaxDataFrame(newMaxData, streamId: 0);

      await Future.delayed(const Duration(milliseconds: 100));
      logDrainConditions(clientStream!, clientSocket!);

      try {
        await sendFuture.timeout(const Duration(seconds: 5));
      } finally {
        periodicLogger.cancel();
      }
      await serverReceivesAllData.future.timeout(const Duration(seconds: 2));
      expect(bytesReceivedByServer, equals(allData.length));
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
