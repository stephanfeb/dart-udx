import 'package:dart_udx/src/multiplexer.dart';
import 'package:dart_udx/udx.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:test/test.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

void main() {
  group('UDX Stream-Level Flow Control', () {
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

    // Helper to establish a connection and a stream pair for tests
    Future<void> setupTestEnvironment() async {
      final serverAddress = serverRawSocket.address;
      final serverPort = serverRawSocket.port;

      // 1. Client creates a socket to connect to the server
      clientSocket = clientMultiplexer.createSocket(udx, serverAddress.address, serverPort);

      // 2. Server waits for the connection
      final serverConnectionCompleter = Completer<UDPSocket>();
      serverMultiplexer.connections.listen(serverConnectionCompleter.complete);

      // 3. Client creates an outgoing stream, which sends a SYN
      clientStream = await UDXStream.createOutgoing(
        udx,
        clientSocket!,
        1,
        2,
        serverAddress.address,
        serverPort,
      );

      serverSocket = await serverConnectionCompleter.future.timeout(const Duration(seconds: 2));

      // 4. Server waits for the incoming stream
      final serverStreamCompleter = Completer<UDXStream>();
      serverSocket!.on('stream').listen((event) {
        if (!serverStreamCompleter.isCompleted) {
          serverStreamCompleter.complete(event.data as UDXStream);
        }
      });
      serverSocket!.flushStreamBuffer();
      
      serverStream = await serverStreamCompleter.future.timeout(const Duration(seconds: 2));
    }

    test('setWindow sends a WindowUpdateFrame, unblocking the peer', () async {
      await setupTestEnvironment();

      // 1. Set the receiver's window to 0 to block the sender.
      clientStream!.setWindow(0);
      // Give it a moment to propagate
      await Future.delayed(const Duration(milliseconds: 100));

      // 2. Try to send data. It should block.
      final data = Uint8List(100);
      final sendFuture = serverStream!.add(data);
      
      await expectLater(
        sendFuture.timeout(const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
        reason: "Sender should block when window is 0",
      );

      // 3. Set up a completer that will resolve when the sender is unblocked.
      final drainCompleter = Completer<void>();
      serverStream!.drain.listen((_) {
        if (!drainCompleter.isCompleted) {
          drainCompleter.complete();
        }
      });

      // 4. Now, update the window on the client, which should unblock the server.
      clientStream!.setWindow(65536);

      // 5. The original send future should now complete, and the drain event should fire.
      await expectLater(sendFuture, completes, reason: "Send should complete after window update");
      await expectLater(drainCompleter.future, completes, reason: "Drain event should fire after window update");
    });

    test('sender respects receiver flow control window', () async {
      await setupTestEnvironment();

      // 1. Set a zero window on the receiver to ensure sender blocks
      serverStream!.setWindow(0);

      // Let the window update propagate
      await Future.delayed(const Duration(milliseconds: 100));

      final data = Uint8List(100); // Data to send
      final sendFuture = clientStream!.add(data);

      // 2. The sender should pause, so the future should not complete immediately
      await expectLater(
        sendFuture.timeout(const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );

      // 3. Now, open up the window
      serverStream!.setWindow(65536);

      // 4. The sender should now be able to send the data
      await expectLater(sendFuture, completes);
    });
  });
}
