/// The PTO probe and the liveness PING carry fresh sequence numbers.
///
/// The probe used to be a PING under the last data packet's sequence. Both
/// peers acknowledge a numbered PING, so when that data packet was lost and
/// the PING got through, the ACK marked the data acknowledged and it was never
/// re-sent: the stream hung at that offset. The RTO timer and the PTO fire
/// together, so the PING went out under the resend's fresh sequence just as
/// the resend did, and one lost resend was enough.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

/// A relay that drops the first [drops] transmissions of the stream data at
/// offset 0 (the original and its resends alike) and passes everything else,
/// PINGs included.
class _DropsFirstChunk {
  _DropsFirstChunk._(this.inside, this.outside, this.server, this.drops) {
    inside.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = inside.receive();
      if (d == null) return;
      _client = d;
      try {
        final p = UDXPacket.fromBytes(d.data);
        if (p.frames.any((f) => f is StreamFrame && f.data.isNotEmpty && f.offset == 0)) {
          transmissions++;
          if (transmissions <= drops) return;
        }
        if (p.frames.any((f) => f is PingFrame)) pings++;
      } catch (_) {}
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

  static Future<_DropsFirstChunk> start(RawDatagramSocket server, int drops) async => _DropsFirstChunk._(
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
  int transmissions = 0;
  int pings = 0;

  void close() {
    inside.close();
    outside.close();
  }
}

void main() {
  late UDX udx;
  late UDXMultiplexer client;
  late UDXMultiplexer server;
  late RawDatagramSocket serverRaw;

  setUp(() async {
    udx = UDX();
    client = UDXMultiplexer(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));
    serverRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    server = UDXMultiplexer(serverRaw);
  });

  tearDown(() {
    client.close();
    server.close();
  });

  Future<(UDPSocket, UDXStream, UDPSocket, UDXStream)> connect(String host, int port) async {
    final serverConnection = Completer<UDPSocket>();
    server.connections.listen(serverConnection.complete);
    final socket = client.createSocket(udx, host, port);
    final clientStream = await UDXStream.createOutgoing(udx, socket, 1, 2, host, port);
    final serverSocket = await serverConnection.future.timeout(const Duration(seconds: 5));
    final serverStream = Completer<UDXStream>();
    serverSocket.on('stream').listen((event) {
      final s = event.data as UDXStream;
      if (s.id == 2 && !serverStream.isCompleted) serverStream.complete(s);
    });
    serverSocket.flushStreamBuffer();
    return (socket, clientStream, serverSocket, await serverStream.future.timeout(const Duration(seconds: 5)));
  }

  test('data whose first two transmissions are lost still arrives: no probe can acknowledge it', () async {
    final path = await _DropsFirstChunk.start(serverRaw, 2);
    addTearDown(path.close);
    final (socket, clientStream, _, serverStream) = await connect(path.inside.address.address, path.inside.port);

    final payload = Uint8List.fromList(List.generate(3000, (i) => i % 251));
    final received = <int>[];
    final all = Completer<void>();
    serverStream.data.listen((d) {
      received.addAll(d);
      if (received.length >= payload.length && !all.isCompleted) all.complete();
    });
    await clientStream.add(payload);
    // Two RTOs (200 ms floor, then 400 ms) plus the delivery.
    await all.future.timeout(const Duration(seconds: 10));

    expect(Uint8List.fromList(received), equals(payload));
    expect(path.transmissions, greaterThanOrEqualTo(3), reason: 'the chunk was re-sent until it got through');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(socket.packetManager.getSentPacketsTestHook(), isEmpty);
    expect(socket.congestionController.inflight, 0);
    await clientStream.close();
  });

  test('ping() is answered on a connection with nothing else in flight', () async {
    final (socket, clientStream, _, _) = await connect(serverRaw.address.address, serverRaw.port);
    await Future<void>.delayed(const Duration(milliseconds: 100)); // the SYN's ACK

    expect(await socket.ping(timeout: const Duration(seconds: 2)), isTrue);
    expect(socket.packetManager.getSentPacketsTestHook(), isEmpty, reason: 'the PING is forgotten once answered');
    expect(socket.congestionController.inflight, 0, reason: 'a PING is not stream data');
    await clientStream.close();
  });
}
