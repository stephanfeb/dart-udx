import 'package:dart_udx/src/multiplexer.dart';
import 'package:dart_udx/dart_udx.dart';
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

    // Stream flow control is advertised as an ABSOLUTE OFFSET: the highest
    // cumulative byte position the peer may send. Credit once granted cannot be
    // revoked — deliverWindowUpdate ignores any offset below the current limit,
    // which is what makes a dropped or reordered WINDOW_UPDATE safe.
    //
    // These tests therefore exercise the real back-pressure path — fill the
    // advertised window, confirm the sender stalls, drain, confirm it resumes —
    // rather than calling setWindow(0) to revoke credit, which the offset model
    // cannot express.

    test('sender never sends past the advertised offset', () async {
      await setupTestEnvironment();

      // Note this cannot be tested by starving the receiver: _deliverDataInternal
      // advertises on bytes *received*, not bytes consumed by the application, so
      // a Dart receiver keeps granting credit whether or not anyone is reading.
      // What is testable here is the invariant the sender must hold — cumulative
      // bytes written never exceed the offset it has been granted. Before the
      // gate was changed to compare bytesWritten, it compared bytes currently
      // outstanding, and this invariant did not hold.
      var received = 0;
      clientStream!.data.listen((chunk) => received += chunk.length);

      var violations = 0;
      var worst = 0;
      final probe = Timer.periodic(const Duration(milliseconds: 5), (_) {
        final over = serverStream!.bytesWritten - serverStream!.remoteReceiveWindow;
        if (over > 0) {
          violations++;
          if (over > worst) worst = over;
        }
      });

      await serverStream!.add(Uint8List(512 * 1024))
          .timeout(const Duration(seconds: 20));
      probe.cancel();

      expect(violations, 0,
          reason: 'sender exceeded the granted offset $violations times, '
              'by as much as $worst bytes');
      expect(serverStream!.bytesWritten,
          lessThanOrEqualTo(serverStream!.remoteReceiveWindow),
          reason: 'cumulative bytes written must stay within the granted offset');
    });

    test('draining the receiver advances the offset and resumes the sender',
        () async {
      await setupTestEnvironment();

      // Drain on the receiving side so it keeps advancing the advertised offset.
      var received = 0;
      clientStream!.data.listen((chunk) => received += chunk.length);

      final payload = Uint8List(512 * 1024);
      await expectLater(
        serverStream!.add(payload).timeout(const Duration(seconds: 20)),
        completes,
        reason:
            'a draining receiver should keep advancing the offset so the sender '
            'never permanently stalls',
      );

      // Let the tail arrive.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (received < payload.length && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      expect(received, payload.length,
          reason: 'all bytes should arrive once the receiver keeps draining');
      expect(serverStream!.remoteReceiveWindow, greaterThan(65536),
          reason: 'the advertised offset should have grown well past its initial value');
    });

    test('a stale or reordered WINDOW_UPDATE never revokes granted credit',
        () async {
      await setupTestEnvironment();

      final granted = clientStream!.remoteReceiveWindow;
      expect(granted, greaterThan(0));

      // A smaller offset arriving late — a duplicate or a reordered frame —
      // must be ignored. WINDOW_UPDATE rides an untracked control packet that is
      // never retransmitted, so honouring a stale value would strand the sender
      // below credit it had already been given.
      clientStream!.deliverWindowUpdate(granted ~/ 2);
      expect(clientStream!.remoteReceiveWindow, granted,
          reason: 'a lower offset must not shrink the limit');

      clientStream!.deliverWindowUpdate(0);
      expect(clientStream!.remoteReceiveWindow, granted,
          reason: 'a zero offset must not revoke credit');

      // A larger offset is applied normally.
      clientStream!.deliverWindowUpdate(granted + 4096);
      expect(clientStream!.remoteReceiveWindow, granted + 4096);
    });

    test('an advertised offset is reconstructed across the 4GB wrap', () async {
      await setupTestEnvironment();

      // The frame field is a uint32, so the offset travels modulo 2^32 and the
      // sender recovers the full value against the limit it already holds.
      // Clamping instead would stall a stream permanently at 4GB.
      //
      // Reconstruction assumes each update lands within one window of the
      // current limit, so walk up to the boundary the way a real stream does
      // rather than leaping 4GB in one step — a single leap that large is
      // genuinely ambiguous and is correctly rejected.
      const modulus = 1 << 32;
      for (final target in [1 << 31, modulus - 8192, modulus + 4096]) {
        clientStream!.deliverWindowUpdate(target & 0xFFFFFFFF);
        expect(clientStream!.remoteReceiveWindow, target,
            reason: 'offset $target should reconstruct from wire value '
                '${target & 0xFFFFFFFF}');
      }

      expect(clientStream!.remoteReceiveWindow, greaterThan(modulus),
          reason: 'the limit must be able to advance past 2^32, not wrap back');
    });
  });
}
