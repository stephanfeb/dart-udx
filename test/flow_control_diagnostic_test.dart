import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:dart_udx/src/multiplexer.dart';
import 'package:test/test.dart';
import 'package:dart_udx/udx.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';

void main() {
  group('Flow Control Diagnostic Tests', () {
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

      clientSocket = clientMultiplexer.createSocket(udx, serverAddress.address, serverPort);

      final serverConnectionCompleter = Completer<UDPSocket>();
      serverMultiplexer.connections.listen(serverConnectionCompleter.complete);

      clientStream = await UDXStream.createOutgoing(
        udx,
        clientSocket!,
        5001,
        5002,
        serverAddress.address,
        serverPort,
      );

      serverSocket = await serverConnectionCompleter.future.timeout(const Duration(seconds: 2));

      final serverStreamCompleter = Completer<UDXStream>();
      serverSocket!.on('stream').listen((event) {
        if (!serverStreamCompleter.isCompleted) {
          serverStreamCompleter.complete(event.data as UDXStream);
        }
      });
      serverSocket!.flushStreamBuffer();
      
      serverStream = await serverStreamCompleter.future.timeout(const Duration(seconds: 2));
    }

    test('diagnose flow control in large payload transfer', () async {
      await setupTestEnvironment();

      final connectionWindow = UDPSocket.defaultInitialConnectionWindow;
      final payloadSize = connectionWindow + 50000;
      print('[DIAGNOSTIC] Connection window: $connectionWindow, Payload size: $payloadSize');

      final largePayload = Uint8List(payloadSize);
      for (int i = 0; i < payloadSize; i++) {
        largePayload[i] = i % 256;
      }

      final receivedData = <int>[];
      final dataReceivedCompleter = Completer<Uint8List>();
      
      int bytesReceivedSinceUpdate = 0;
      final windowUpdateThreshold = connectionWindow ~/ 4;
      
      Timer? periodicLogger;
      
      clientSocket!.on('remoteConnectionWindowUpdate').listen((event) {
        final eventData = event.data as Map<String, dynamic>?;
        final newMaxData = eventData?['maxData'] as int?;
        print('[DIAGNOSTIC] ClientSocket received remoteConnectionWindowUpdate event: maxData=$newMaxData');
      });
      
      clientSocket!.on('processedMaxDataFrame').listen((event) {
        final eventData = event.data as Map<String, dynamic>?;
        final maxData = eventData?['maxData'] as int?;
        print('[DIAGNOSTIC] ClientSocket processed MaxDataFrame from peer: maxData=$maxData');
      });

      serverStream!.data.listen((data) {
        receivedData.addAll(data);
        bytesReceivedSinceUpdate += data.length;

        if (bytesReceivedSinceUpdate >= windowUpdateThreshold) {
          print('[DIAGNOSTIC] Received $bytesReceivedSinceUpdate bytes, sending connection window update');
          serverSocket!.sendMaxDataFrame(connectionWindow * 2);
          bytesReceivedSinceUpdate = 0;
        }

        if (receivedData.length == payloadSize) {
          print('[DIAGNOSTIC] All data received, completing dataReceivedCompleter');
          if (!dataReceivedCompleter.isCompleted) {
            dataReceivedCompleter.complete(Uint8List.fromList(receivedData));
          }
        }
      }, onDone: () {
        print('[DIAGNOSTIC] Server stream is done. Received ${receivedData.length}/$payloadSize bytes');
        if (!dataReceivedCompleter.isCompleted && receivedData.isNotEmpty) {
          dataReceivedCompleter.complete(Uint8List.fromList(receivedData));
        }
      });

      periodicLogger = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (clientStream != null) {
          print('[DIAGNOSTIC] ClientStream - cwnd: ${clientStream!.cwnd}, inflight: ${clientStream!.inflight}, remoteReceiveWindow: ${clientStream!.remoteReceiveWindow}');
        }
        print('[DIAGNOSTIC] Received ${receivedData.length}/$payloadSize bytes (${(receivedData.length / payloadSize * 100).toStringAsFixed(2)}%)');
      });

      print('[DIAGNOSTIC] Sending very large payload of size: $payloadSize bytes');
      await clientStream!.add(largePayload);
      print('[DIAGNOSTIC] Send future completed.');
      
      Uint8List? receivedPayload;
      try {
        receivedPayload = await dataReceivedCompleter.future.timeout(const Duration(seconds: 60));
        print('[DIAGNOSTIC] Data received completer completed successfully');
      } catch (e) {
        print('[DIAGNOSTIC] Data received completer timed out: $e');
      } finally {
        periodicLogger.cancel();
      }

      expect(receivedPayload, isNotNull, reason: "Payload should have been received");
      expect(receivedPayload!.length, equals(largePayload.length), reason: "Received payload length should match sent payload length");
      
      bool contentMatches = true;
      for (int i = 0; i < payloadSize; i++) {
        if (receivedPayload[i] != largePayload[i]) {
          contentMatches = false;
          print('[DIAGNOSTIC] Mismatch at index $i: expected ${largePayload[i]}, got ${receivedPayload[i]}');
          break;
        }
      }
      expect(contentMatches, isTrue, reason: "Received payload content should match sent payload content");

    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
