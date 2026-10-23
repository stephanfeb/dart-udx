/// A retransmitted packet's bytes come back when its resend is acknowledged.
///
/// The ACK path used to look each acknowledged sequence up in a map keyed by
/// the ORIGINAL sequence. A retransmission is re-keyed under a fresh sequence
/// (PacketManager.retransmit), so the ACK of a resend found nothing, and the
/// packet's bytes stayed in flight and in the connection's send window for the
/// rest of the connection. Every loss shrank the usable window for good; after
/// a dozen the sender could only write through a 30 s escape hatch.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

/// A relay between a client and a server that drops the first transmission of
/// the first [drops] data-bearing packets it sees, and passes everything else:
/// the retransmissions included.
class _LossyPath {
  _LossyPath._(this.inside, this.outside, this.server, this.drops) {
    inside.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = inside.receive();
      if (d == null) return;
      _client = d;
      if (dropped < drops) {
        try {
          final p = UDXPacket.fromBytes(d.data);
          if (p.frames.any((f) => f is StreamFrame && f.data.isNotEmpty)) {
            dropped++;
            droppedBytes += p.dataBytes;
            return;
          }
        } catch (_) {}
      }
      outside.send(d.data, server.address, server.port);
    });
    outside.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = outside.receive();
      final client = _client;
      if (d == null || client == null) return;
      inside.send(d.data, client.address, client.port);
    });
  }

  static Future<_LossyPath> start(RawDatagramSocket server, int drops) async => _LossyPath._(
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
        server,
        drops,
      );

  final RawDatagramSocket inside;
  final RawDatagramSocket outside;
  final RawDatagramSocket server;
  final int drops;
  Datagram? _client;
  int dropped = 0;
  int droppedBytes = 0;

  void close() {
    inside.close();
    outside.close();
  }
}

/// A client stream to a server across [path], with the server's end of it.
Future<(UDPSocket, UDXStream, UDXStream)> _connect(
    UDX udx, UDXMultiplexer client, UDXMultiplexer server, _LossyPath path) async {
  final serverConnection = Completer<UDPSocket>();
  server.connections.listen(serverConnection.complete);
  final socket = client.createSocket(udx, path.inside.address.address, path.inside.port);
  final clientStream = await UDXStream.createOutgoing(
    udx,
    socket,
    1,
    2,
    path.inside.address.address,
    path.inside.port,
  );
  final serverSocket = await serverConnection.future.timeout(const Duration(seconds: 5));
  final serverStream = Completer<UDXStream>();
  serverSocket.on('stream').listen((event) {
    final s = event.data as UDXStream;
    if (s.id == 2 && !serverStream.isCompleted) serverStream.complete(s);
  });
  serverSocket.flushStreamBuffer();
  return (socket, clientStream, await serverStream.future.timeout(const Duration(seconds: 5)));
}

/// Reads a stream once and lets a test wait for a byte count.
class _Receiver {
  _Receiver(UDXStream stream) {
    stream.data.listen((d) {
      received += d.length;
      for (final waiter in List.of(_waiters)) {
        if (received >= waiter.$1) {
          _waiters.remove(waiter);
          waiter.$2.complete();
        }
      }
    });
  }

  int received = 0;
  final List<(int, Completer<void>)> _waiters = [];

  Future<void> until(int total) {
    if (received >= total) return Future.value();
    final c = Completer<void>();
    _waiters.add((total, c));
    return c.future.timeout(const Duration(seconds: 10));
  }
}

Future<void> _transfer(UDXStream from, _Receiver to, Uint8List payload) async {
  final total = to.received + payload.length;
  await from.add(payload);
  await to.until(total);
}

void main() {
  late UDX udx;
  late RawDatagramSocket clientRaw;
  late RawDatagramSocket serverRaw;
  late UDXMultiplexer client;
  late UDXMultiplexer server;

  setUp(() async {
    udx = UDX();
    clientRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    serverRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    client = UDXMultiplexer(clientRaw);
    server = UDXMultiplexer(serverRaw);
  });

  tearDown(() {
    client.close();
    server.close();
  });

  for (final drops in [1, 5]) {
    test('inflight and the connection send window are fully credited after $drops dropped packet(s)', () async {
      final path = await _LossyPath.start(serverRaw, drops);
      addTearDown(path.close);
      final (socket, clientStream, serverStream) = await _connect(udx, client, server, path);

      final payload = Uint8List.fromList(List.generate(12 * 1024, (i) => i % 251));
      await _transfer(clientStream, _Receiver(serverStream), payload);
      expect(path.dropped, drops, reason: 'the relay dropped $drops data packets');

      // The last ACK may still be on its way.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(socket.packetManager.getSentPacketsTestHook(), isEmpty, reason: 'everything was acknowledged');
      expect(socket.congestionController.inflight, 0,
          reason: 'retransmitted packets leave flight when their resend is acknowledged');
      expect(socket.getAvailableConnectionSendWindow(), UDPSocket.defaultInitialConnectionWindow,
          reason: 'the connection send window is credited back for retransmitted packets too');
      await clientStream.close();
    });
  }

  test('a connection keeps adapting after a loss: the RTT is still sampled and the window still grows', () async {
    final path = await _LossyPath.start(serverRaw, 1);
    addTearDown(path.close);
    final (socket, clientStream, serverStream) = await _connect(udx, client, server, path);
    final cc = socket.congestionController;
    final receiver = _Receiver(serverStream);

    final payload = Uint8List.fromList(List.generate(12 * 1024, (i) => i % 251));
    await _transfer(clientStream, receiver, payload);
    expect(path.dropped, 1);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(cc.isInRecoveryForTest, isFalse, reason: 'recovery ends once a packet sent after it is acknowledged');

    // Everything after the loss: ACKs of fresh sequences must still be heard.
    final cwndBefore = cc.cwnd;
    final rttBefore = cc.smoothedRtt;
    const marker = Duration(seconds: 2); // a value no loopback sample would leave in place
    cc.setSmoothedRtt(marker);
    // Enough packets for a dozen ACKs at full-size datagrams (one ACK per
    // two packets).
    await _transfer(clientStream, receiver, Uint8List.fromList(List.generate(32 * 1024, (i) => i % 251)));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // Smoothing is 1/8 per sample, so a dozen loopback samples bring the
    // marker well down; the latest sample itself is a loopback round trip.
    expect(cc.smoothedRtt, lessThan(const Duration(seconds: 1)),
        reason: 'ACKs after the loss still produce RTT samples (was $rttBefore before the marker)');
    expect(cc.latestRttForTest, lessThan(const Duration(milliseconds: 500)));
    expect(cc.cwnd, greaterThan(cwndBefore), reason: 'ACKs after the loss still grow the window');
    expect(cc.inflight, 0);
    await clientStream.close();
  });
}
