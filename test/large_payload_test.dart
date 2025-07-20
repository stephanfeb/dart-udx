import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_udx/src/multiplexer.dart';
import 'package:test/test.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';

void main() {
  group('UDX Large Payload Tests', () {
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

    Future<void> setupTestEnvironment(int clientStreamId, int serverStreamId) async {
      final serverAddress = serverRawSocket.address;
      final serverPort = serverRawSocket.port;

      clientSocket = clientMultiplexer.createSocket(udx, serverAddress.address, serverPort);

      final serverConnectionCompleter = Completer<UDPSocket>();
      serverMultiplexer.connections.listen(serverConnectionCompleter.complete);

      clientStream = await UDXStream.createOutgoing(
        udx,
        clientSocket!,
        clientStreamId,
        serverStreamId,
        serverAddress.address,
        serverPort,
      );

      serverSocket = await serverConnectionCompleter.future.timeout(const Duration(seconds: 2));

      final serverStreamCompleter = Completer<UDXStream>();
      serverSocket!.on('stream').listen((event) {
        final newStream = event.data as UDXStream;
        if (newStream.id == serverStreamId) {
          serverStream = newStream;
          serverStreamCompleter.complete(newStream);
        }
      });
      serverSocket!.flushStreamBuffer();
      
      await serverStreamCompleter.future.timeout(const Duration(seconds: 2));
    }

    test('large payload is fragmented according to MTU size', () async {
      await setupTestEnvironment(1001, 1002);

      final dataReceivedCompleter = Completer<Uint8List>();
      final receivedData = <int>[];
      
      final maxPayloadSize = UDXStream.getMaxPayloadSizeTestHook();
      final payloadSize = maxPayloadSize * 5;
      final largePayload = Uint8List(payloadSize);
      for (int i = 0; i < payloadSize; i++) {
        largePayload[i] = i % 256;
      }

      serverStream!.data.listen((data) {
        receivedData.addAll(data);
        if (receivedData.length == payloadSize) {
          dataReceivedCompleter.complete(Uint8List.fromList(receivedData));
        }
      });

      await clientStream!.add(largePayload);
      final receivedPayload = await dataReceivedCompleter.future.timeout(const Duration(seconds: 10));

      expect(receivedPayload, equals(largePayload));
    });

    test('multiple large payloads are correctly transmitted', () async {
      await setupTestEnvironment(2001, 2002);

      final maxPayloadSize = UDXStream.getMaxPayloadSizeTestHook();
      final payloadSizes = [
        maxPayloadSize - 100,
        maxPayloadSize,
        maxPayloadSize + 100,
        maxPayloadSize * 3 + 50
      ];
      final payloads = payloadSizes.map((size) {
        final payload = Uint8List(size);
        for (int i = 0; i < size; i++) {
          payload[i] = (i + size) % 256;
        }
        return payload;
      }).toList();

      final allDataReceivedCompleter = Completer<List<Uint8List>>();
      final receivedPayloads = <Uint8List>[];
      List<int> currentPayloadBuffer = [];
      int payloadIndex = 0;

      serverStream!.data.listen((data) {
        currentPayloadBuffer.addAll(data);
        while (payloadIndex < payloads.length && currentPayloadBuffer.length >= payloads[payloadIndex].length) {
          final currentExpectedSize = payloads[payloadIndex].length;
          final payloadData = currentPayloadBuffer.sublist(0, currentExpectedSize);
          receivedPayloads.add(Uint8List.fromList(payloadData));
          currentPayloadBuffer = currentPayloadBuffer.sublist(currentExpectedSize);
          payloadIndex++;
        }
        if (receivedPayloads.length == payloads.length) {
          allDataReceivedCompleter.complete(receivedPayloads);
        }
      });

      for (final payload in payloads) {
        await clientStream!.add(payload);
        await Future.delayed(const Duration(milliseconds: 100));
      }

      final receivedData = await allDataReceivedCompleter.future.timeout(const Duration(seconds: 15));
      
      expect(receivedData.length, equals(payloads.length));
      for (int i = 0; i < payloads.length; i++) {
        expect(receivedData[i], equals(payloads[i]));
      }
    });

    test('very large payload exceeding connection window is correctly transmitted', () async {
      await setupTestEnvironment(3001, 3002);

      final connectionWindow = UDPSocket.defaultInitialConnectionWindow;
      final payloadSize = connectionWindow + 50000;
      final largePayload = Uint8List(payloadSize);
      for (int i = 0; i < payloadSize; i++) {
        largePayload[i] = i % 256;
      }

      final dataReceivedCompleter = Completer<Uint8List>();
      final receivedData = <int>[];
      int bytesReceived = 0;
      final windowUpdateThreshold = connectionWindow ~/ 2;

      serverStream!.data.listen((data) {
        receivedData.addAll(data);
        bytesReceived += data.length;
        if (bytesReceived >= windowUpdateThreshold) {
          serverSocket!.sendMaxDataFrame(UDPSocket.defaultInitialConnectionWindow * 2);
          bytesReceived = 0;
        }
        if (receivedData.length == payloadSize) {
          dataReceivedCompleter.complete(Uint8List.fromList(receivedData));
        }
      });

      final sendFuture = clientStream!.add(largePayload);
      final receivedPayload = await dataReceivedCompleter.future.timeout(const Duration(seconds: 60));
      await sendFuture;

      expect(receivedPayload, equals(largePayload));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
