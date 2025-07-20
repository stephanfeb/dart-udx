import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_udx/src/multiplexer.dart';
import 'package:test/test.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';

void main() {
  group('Connection-Level Flow Control Tests', () {
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
        100,
        101,
        serverAddress.address,
        serverPort,
        initialCwnd: 1472 * 30,
      );

      serverSocket = await serverConnectionCompleter.future.timeout(Duration(seconds: 2));

      final serverStreamCompleter = Completer<UDXStream>();
      serverSocket!.on('stream').listen((event) {
        if (!serverStreamCompleter.isCompleted) {
          serverStreamCompleter.complete(event.data as UDXStream);
        }
      });
      serverSocket!.flushStreamBuffer();
      
      serverStream = await serverStreamCompleter.future.timeout(const Duration(seconds: 2));

      final largeStreamWindow = UDPSocket.defaultInitialConnectionWindow * 2;
      serverStream!.setWindow(largeStreamWindow);
      clientStream!.setWindow(largeStreamWindow);
      await Future.delayed(Duration(milliseconds: 50));
    }

    test('Client sends initial MaxDataFrame upon stream creation', () async {
      final serverAddress = serverRawSocket.address;
      final serverPort = serverRawSocket.port;
      clientSocket = clientMultiplexer.createSocket(udx, serverAddress.address, serverPort);

      final serverConnectionCompleter = Completer<UDPSocket>();
      serverMultiplexer.connections.listen(serverConnectionCompleter.complete);

      final maxDataCompleter = Completer<int>();
      clientSocket!.on('processedMaxDataFrame').listen((event) {
        final eventData = event.data as Map<String, dynamic>;
        maxDataCompleter.complete(eventData['maxData'] as int);
      });

      clientStream = await UDXStream.createOutgoing(
        udx,
        clientSocket!,
        200,
        201,
        serverAddress.address,
        serverPort,
      );

      serverSocket = await serverConnectionCompleter.future.timeout(Duration(seconds: 2));
      
      final receivedMaxData = await maxDataCompleter.future.timeout(Duration(seconds: 2));
      expect(receivedMaxData, equals(UDPSocket.defaultInitialConnectionWindow));
    });

    test('Sender stops sending when connection window is exhausted', () async {
      await setupTestEnvironment();

      final serverInitialMaxData = UDPSocket.defaultInitialConnectionWindow;
      final largeData = Uint8List(serverInitialMaxData + 2000);
      int bytesReceivedByServer = 0;

      serverStream!.data.listen((data) {
        bytesReceivedByServer += data.length;
      });

      final sendFuture = clientStream!.add(largeData);

      await Future.delayed(Duration(milliseconds: 500));

      expect(bytesReceivedByServer, lessThanOrEqualTo(serverInitialMaxData + clientStream!.mtu));

      bool sendFutureCompleted = false;
      sendFuture.then((_) => sendFutureCompleted = true);
      await Future.delayed(Duration(milliseconds: 200));
      expect(sendFutureCompleted, isFalse);
    }, timeout: Timeout(Duration(seconds: 5)));

    test('Sender resumes sending after MaxDataFrame increases window', () async {
      await setupTestEnvironment();

      final serverInitialMaxData = UDPSocket.defaultInitialConnectionWindow;
      final dataPart1Size = serverInitialMaxData - 1000;
      final dataPart2Size = 3000;
      final dataPart1 = Uint8List(dataPart1Size);
      final dataPart2 = Uint8List.fromList(List.generate(dataPart2Size, (i) => i % 256));
      final allData = Uint8List.fromList([...dataPart1, ...dataPart2]);

      int bytesReceivedByServer = 0;
      final serverReceivesAllData = Completer<void>();

      serverStream!.data.listen((data) {
        bytesReceivedByServer += data.length;
        if (bytesReceivedByServer >= allData.length) {
          if (!serverReceivesAllData.isCompleted) {
            serverReceivesAllData.complete();
          }
        }
      });

      final sendFuture = clientStream!.add(allData);

      await Future.delayed(Duration(milliseconds: 500));

      bool sendFutureCompletedInitially = false;
      sendFuture.then((_) => sendFutureCompletedInitially = true);
      await Future.delayed(Duration(milliseconds: 50));
      expect(sendFutureCompletedInitially, isFalse);

      final newMaxData = serverInitialMaxData + dataPart2Size + 5000;
      await serverSocket!.sendMaxDataFrame(newMaxData, streamId: serverStream!.remoteId!);

      await expectLater(sendFuture, completes);
      await expectLater(serverReceivesAllData.future, completes);
      expect(bytesReceivedByServer, equals(allData.length));
    }, timeout: Timeout(Duration(seconds: 10)));
  });
}
