import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/multiplexer.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';

void main() {
  group('UDXStream Half-Close', () {
    late UDX udx;
    late UDXMultiplexer clientMultiplexer;
    late UDXMultiplexer serverMultiplexer;
    late RawDatagramSocket clientRawSocket;
    late RawDatagramSocket serverRawSocket;
    late UDPSocket clientSocket;
    late UDPSocket serverSocket;
    late UDXStream stream1;
    late UDXStream stream2;

    setUp(() async {
      udx = UDX();
      clientRawSocket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      serverRawSocket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      clientMultiplexer = UDXMultiplexer(clientRawSocket);
      serverMultiplexer = UDXMultiplexer(serverRawSocket);

      final serverAddress = serverRawSocket.address;
      final serverPort = serverRawSocket.port;

      // Client creates a socket to connect to the server
      clientSocket = clientMultiplexer.createSocket(
        udx,
        serverAddress.address,
        serverPort,
      );

      final serverSocketCompleter = Completer<UDPSocket>();
      serverMultiplexer.connections.listen(serverSocketCompleter.complete);

      // Client creates outgoing stream
      stream1 = await UDXStream.createOutgoing(
        udx,
        clientSocket,
        1,
        2,
        serverAddress.address,
        serverPort,
      );

      // Server receives incoming connection
      serverSocket = await serverSocketCompleter.future.timeout(const Duration(seconds: 5));

      // Server gets the incoming stream
      final stream2Completer = Completer<UDXStream>();
      serverSocket.on('stream').listen((event) {
        if (!stream2Completer.isCompleted) {
          stream2Completer.complete(event.data as UDXStream);
        }
      });
      serverSocket.flushStreamBuffer();

      stream2 = await stream2Completer.future.timeout(const Duration(seconds: 5));

      // Wait for connections to be fully established
      await Future.delayed(Duration(milliseconds: 200));
    });

    tearDown(() async {
      try {
        await stream1.close();
      } catch (_) {}
      try {
        await stream2.close();
      } catch (_) {}
      clientMultiplexer.close();
      serverMultiplexer.close();
    });

    test('closeWrite() prevents further writes', () async {
      await stream1.closeWrite();

      // Attempting to write should throw StateError
      expect(
        () => stream1.add(Uint8List.fromList([1, 2, 3])),
        throwsStateError,
      );
    });

    test('closeWrite() allows continued reads', () async {
      // Stream1 closes its write side
      await stream1.closeWrite();

      // Stream2 should still be able to send data to stream1
      final testData = Uint8List.fromList([4, 5, 6, 7, 8]);
      final receivedCompleter = Completer<Uint8List>();
      
      stream1.data.listen((data) {
        if (!receivedCompleter.isCompleted) {
          receivedCompleter.complete(data);
        }
      });

      await stream2.add(testData);

      // Stream1 should receive the data
      final received = await receivedCompleter.future.timeout(
        Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('Did not receive data'),
      );

      expect(received, equals(testData));
    });

    test('closeWrite() sends FIN to remote peer', () async {
      // Set up listener for 'end' event on stream2
      final endCompleter = Completer<void>();
      stream2.on('end').listen((_) {
        if (!endCompleter.isCompleted) {
          endCompleter.complete();
        }
      });

      // Stream1 closes its write side
      await stream1.closeWrite();

      // Stream2 should receive FIN (end event)
      await endCompleter.future.timeout(
        Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('Did not receive FIN'),
      );
    });

    test('bidirectional half-close allows independent write closure', () async {
      // Track when each stream receives FIN
      final stream1EndCompleter = Completer<void>();
      final stream2EndCompleter = Completer<void>();

      stream1.on('end').listen((_) {
        if (!stream1EndCompleter.isCompleted) {
          stream1EndCompleter.complete();
        }
      });

      stream2.on('end').listen((_) {
        if (!stream2EndCompleter.isCompleted) {
          stream2EndCompleter.complete();
        }
      });

      // Stream1 closes write
      await stream1.closeWrite();

      // Stream2 should receive FIN
      await stream2EndCompleter.future.timeout(
        Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('Stream2 did not receive FIN from stream1'),
      );

      // Stream2 can still send data to stream1
      final testData = Uint8List.fromList([10, 20, 30]);
      final receivedCompleter = Completer<Uint8List>();
      
      stream1.data.listen((data) {
        if (!receivedCompleter.isCompleted) {
          receivedCompleter.complete(data);
        }
      });

      await stream2.add(testData);
      final received = await receivedCompleter.future.timeout(
        Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('Stream1 did not receive data'),
      );
      expect(received, equals(testData));

      // Now stream2 closes its write side
      await stream2.closeWrite();

      // Stream1 should receive FIN
      await stream1EndCompleter.future.timeout(
        Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('Stream1 did not receive FIN from stream2'),
      );
    });

    test('full close after both sides closeWrite()', () async {
      // Track close events
      final stream1CloseCompleter = Completer<void>();
      final stream2CloseCompleter = Completer<void>();

      stream1.on('close').listen((_) {
        if (!stream1CloseCompleter.isCompleted) {
          stream1CloseCompleter.complete();
        }
      });

      stream2.on('close').listen((_) {
        if (!stream2CloseCompleter.isCompleted) {
          stream2CloseCompleter.complete();
        }
      });

      // Both sides close their write sides
      await stream1.closeWrite();
      await stream2.closeWrite();

      // Both streams should fully close
      await Future.wait([
        stream1CloseCompleter.future.timeout(
          Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('Stream1 did not close'),
        ),
        stream2CloseCompleter.future.timeout(
          Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('Stream2 did not close'),
        ),
      ]);

      // Verify streams are no longer connected
      expect(stream1.connected, isFalse);
      expect(stream2.connected, isFalse);
    });

    test('close() after closeWrite() completes successfully', () async {
      await stream1.closeWrite();

      // Full close should work without error
      await stream1.close();

      expect(stream1.connected, isFalse);
    });

    test('multiple closeWrite() calls are idempotent', () async {
      await stream1.closeWrite();
      await stream1.closeWrite();
      await stream1.closeWrite();

      // Should not throw errors
      expect(stream1.connected, isTrue); // Still connected for reading
    });

    test('data exchange before and after half-close', () async {
      // Exchange data bidirectionally before half-close
      final testData1 = Uint8List.fromList([1, 2, 3]);
      final testData2 = Uint8List.fromList([4, 5, 6]);
      final testData3 = Uint8List.fromList([7, 8, 9]);

      final receivedStream1 = <Uint8List>[];
      final receivedStream2 = <Uint8List>[];

      stream1.data.listen((data) => receivedStream1.add(data));
      stream2.data.listen((data) => receivedStream2.add(data));

      // Before half-close: bidirectional communication
      await stream1.add(testData1);
      await stream2.add(testData2);

      await Future.delayed(Duration(milliseconds: 300));

      expect(receivedStream2.any((d) => d.toString() == testData1.toString()), isTrue);
      expect(receivedStream1.any((d) => d.toString() == testData2.toString()), isTrue);

      // Stream1 closes write
      await stream1.closeWrite();

      // Stream2 can still send to stream1
      await stream2.add(testData3);

      await Future.delayed(Duration(milliseconds: 300));

      expect(receivedStream1.any((d) => d.toString() == testData3.toString()), isTrue);

      // Stream1 cannot send
      expect(
        () => stream1.add(Uint8List.fromList([10])),
        throwsStateError,
      );
    });

    test('large data transfer with half-close', () async {
      // Set up FIN listener BEFORE closing write
      final endCompleter = Completer<void>();
      stream2.on('end').listen((_) {
        if (!endCompleter.isCompleted) {
          endCompleter.complete();
        }
      });

      // Create large data (multiple MTU-sized chunks)
      final largeData = Uint8List(10000);
      for (int i = 0; i < largeData.length; i++) {
        largeData[i] = i % 256;
      }

      final receivedCompleter = Completer<List<int>>();
      final received = <int>[];

      stream2.data.listen((chunk) {
        received.addAll(chunk);
        if (received.length >= largeData.length) {
          if (!receivedCompleter.isCompleted) {
            receivedCompleter.complete(received);
          }
        }
      });

      // Send large data
      await stream1.add(largeData);

      // Wait for all data to be received
      final receivedData = await receivedCompleter.future.timeout(
        Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('Did not receive all data'),
      );

      expect(receivedData.length, equals(largeData.length));
      expect(receivedData, equals(largeData));

      // Now close write side
      await stream1.closeWrite();

      // Verify FIN received
      await endCompleter.future.timeout(
        Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('Did not receive FIN after large transfer'),
      );
    });
  });
}

