import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

/// Stands between a client and a server as a path with latency does: every
/// datagram arrives [delay] later, in order (timers due at the same instant
/// fire in the order they were set).
class _DelayedPath {
  _DelayedPath._(this.inside, this.outside, this.server, this.delay) {
    inside.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = inside.receive();
      if (d == null) return;
      _client = d;
      Timer(delay, () => outside.send(d.data, server.address, server.port));
    });
    outside.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = outside.receive();
      final client = _client;
      if (d == null || client == null) return;
      Timer(delay, () => inside.send(d.data, client.address, client.port));
    });
  }

  static Future<_DelayedPath> start(RawDatagramSocket server, Duration delay) async => _DelayedPath._(
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
        server,
        delay,
      );

  final RawDatagramSocket inside;
  final RawDatagramSocket outside;
  final RawDatagramSocket server;
  final Duration delay;
  Datagram? _client;

  void close() {
    inside.close();
    outside.close();
  }
}

void main() {
  // A sender's rate follows its window: slow start runs until the first loss
  // and the pacer is told of every change to the window. Over a lossless
  // path with a 40 ms round trip (20 ms each way) 2 MB takes a few hundred
  // milliseconds. Slow start used to end at a 64 KB ssthresh, and the window
  // crawled up from there at CUBIC's pace with the sender window-bound.
  test("a sender's rate follows its window over a 40 ms path", () async {
    final udx = UDX();
    final clientRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final serverRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final client = UDXMultiplexer(clientRaw);
    final server = UDXMultiplexer(serverRaw);
    final path = await _DelayedPath.start(serverRaw, const Duration(milliseconds: 20));
    addTearDown(() {
      client.close();
      server.close();
      path.close();
    });

    final serverConnection = Completer<UDPSocket>();
    server.connections.listen(serverConnection.complete);
    final socket = client.createSocket(udx, path.inside.address.address, path.inside.port);
    final clientStream = await UDXStream.createOutgoing(udx, socket, 1, 2, path.inside.address.address, path.inside.port);
    final serverSocket = await serverConnection.future.timeout(const Duration(seconds: 5));
    final serverStream = Completer<UDXStream>();
    serverSocket.on('stream').listen((event) {
      final s = event.data as UDXStream;
      if (s.id == 2 && !serverStream.isCompleted) serverStream.complete(s);
    });
    serverSocket.flushStreamBuffer();

    const size = 2 * 1024 * 1024;
    var received = 0;
    final all = Completer<void>();
    (await serverStream.future.timeout(const Duration(seconds: 5))).data.listen((data) {
      received += data.length;
      if (received >= size && !all.isCompleted) all.complete();
    });

    final start = DateTime.now();
    await clientStream.add(Uint8List(size));
    await all.future.timeout(const Duration(seconds: 10));
    final elapsed = DateTime.now().difference(start);
    final cc = socket.congestionController;
    // ignore: avoid_print
    print('2 MB over a 40 ms path in ${elapsed.inMilliseconds} ms: '
        '${(size / elapsed.inMicroseconds).toStringAsFixed(1)} MB/s; '
        'cwnd ${cc.cwnd}, srtt ${cc.smoothedRtt.inMilliseconds} ms, rate ${cc.pacingController.pacingRateBytesPerSec.round()} B/s');
    expect(elapsed, lessThan(const Duration(seconds: 2)),
        reason: 'the window or the pacing rate is not following the path');
    await clientStream.close();
  });
}
