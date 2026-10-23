/// The receiver acknowledges after every second packet or when the ACK timer
/// fires, at once when something is out of order, and every ACK carries the
/// receive history as ranges (RFC 9000 section 13.2).
///
/// Every packet used to be acknowledged on arrival, with only itself in the
/// frame: one datagram sent for each received, and a go-udx sender, which
/// declares loss only from the gaps in an ACK, never saw a gap from this side.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/constants.dart';
import 'package:test/test.dart';

/// A relay from a client to a server that counts what passes each way, can
/// drop chosen data packets (by the offset of their stream data, first
/// transmission only) and records every ACK frame the server sends back.
class _Relay {
  _Relay._(this.inside, this.outside, this.server) {
    inside.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = inside.receive();
      if (d == null) return;
      _client = d;
      try {
        final p = UDXPacket.fromBytes(d.data);
        for (final f in p.frames) {
          if (f is StreamFrame && f.data.isNotEmpty) {
            dataPackets++;
            if (dropOffsets.remove(f.offset)) return;
          }
        }
      } catch (_) {}
      outside.send(d.data, server.address, server.port);
    });
    outside.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = outside.receive();
      final client = _client;
      if (d == null || client == null) return;
      try {
        final p = UDXPacket.fromBytes(d.data);
        for (final f in p.frames) {
          if (f is AckFrame) acks.add(f);
        }
      } catch (_) {}
      inside.send(d.data, client.address, client.port);
    });
  }

  static Future<_Relay> start(RawDatagramSocket server) async => _Relay._(
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
        server,
      );

  final RawDatagramSocket inside;
  final RawDatagramSocket outside;
  final RawDatagramSocket server;
  Datagram? _client;
  final Set<int> dropOffsets = {};
  int dataPackets = 0;
  final List<AckFrame> acks = [];

  void close() {
    inside.close();
    outside.close();
  }
}

/// The sequences an ACK frame acknowledges.
Set<int> acknowledged(AckFrame f) {
  final out = <int>{};
  for (var i = 0; i < f.firstAckRangeLength; i++) {
    out.add(f.largestAcked - i);
  }
  var cursor = f.largestAcked - f.firstAckRangeLength;
  for (final r in f.ackRanges) {
    final end = cursor - r.gap;
    for (var i = 0; i < r.ackRangeLength; i++) {
      out.add(end - i);
    }
    cursor = end - r.ackRangeLength;
  }
  return out;
}

void main() {
  late UDX udx;
  late UDXMultiplexer client;
  late UDXMultiplexer server;
  late RawDatagramSocket serverRaw;
  late _Relay relay;

  setUp(() async {
    udx = UDX();
    client = UDXMultiplexer(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));
    serverRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    server = UDXMultiplexer(serverRaw);
    relay = await _Relay.start(serverRaw);
  });

  tearDown(() {
    client.close();
    server.close();
    relay.close();
  });

  Future<(UDXStream, UDXStream)> connect() async {
    final host = relay.inside.address.address;
    final port = relay.inside.port;
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
    return (clientStream, await serverStream.future.timeout(const Duration(seconds: 5)));
  }

  Future<void> transfer(UDXStream from, UDXStream to, Uint8List payload) async {
    var received = 0;
    final all = Completer<void>();
    final sub = to.data.listen((d) {
      received += d.length;
      if (received >= payload.length && !all.isCompleted) all.complete();
    });
    await from.add(payload);
    await all.future.timeout(const Duration(seconds: 10));
    await sub.cancel();
  }

  test('in order, about one ACK per two data packets, each reporting a delay of at most 25 ms', () async {
    final (clientStream, serverStream) = await connect();
    await Future<void>.delayed(const Duration(milliseconds: 50)); // the SYN's ACK
    relay.acks.clear();

    // 60 full packets, at whatever datagram size the path has been found
    // to carry by now (the search runs on the first ACKs).
    final perPacket = clientStream.mtu - streamPacketOverhead;
    await transfer(clientStream, serverStream, Uint8List(60 * perPacket));
    await Future<void>.delayed(const Duration(milliseconds: 100)); // the timer's last ACK

    expect(relay.dataPackets, greaterThanOrEqualTo(60));
    expect(relay.acks.length, lessThan(relay.dataPackets * 3 ~/ 4),
        reason: 'far fewer ACKs than data packets (${relay.acks.length} for ${relay.dataPackets})');
    expect(relay.acks.length, greaterThanOrEqualTo(relay.dataPackets ~/ 2 - 2));
    for (final a in relay.acks) {
      expect(a.ackDelay, lessThanOrEqualTo(25 + 10), reason: 'the ACK timer is at most 25 ms (plus scheduling)');
      expect(a.ackRanges, isEmpty, reason: 'nothing was lost');
    }
    await clientStream.close();
  });

  test('a packet arriving out of order is acknowledged at once, with the gap, repeated in later ACKs', () async {
    final (clientStream, serverStream) = await connect();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    relay.acks.clear();
    final perPacket = clientStream.mtu - streamPacketOverhead;
    relay.dropOffsets.add(2 * perPacket); // the third data packet, first transmission only

    await transfer(clientStream, serverStream, Uint8List(8 * perPacket));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final withGap = relay.acks.where((a) => a.ackRanges.isNotEmpty).toList();
    expect(withGap, isNotEmpty, reason: 'the ACK after the hole names it');
    expect(withGap.first.ackRanges.first.gap, 1);
    expect(withGap.length, greaterThan(1), reason: 'the gap is repeated until the resend fills it');
    // The resend goes out under a fresh sequence, so the dropped sequence is
    // never received and its gap stays in the history; the sender no longer
    // tracks that sequence, so the gap costs nothing. The last ACK names
    // every sequence that arrived: the SYN, the path-MTU probe that went
    // out on the SYN's ACK, the seven other originals and the resend (one
    // per data packet the relay saw), around the one hole.
    final last = relay.acks.last;
    expect(last.ackRanges.map((r) => (r.gap, r.ackRangeLength)).toList(), [(1, 4)],
        reason: 'below the hole: the SYN, the probe and two data packets');
    expect(acknowledged(last).length, relay.dataPackets + 1, reason: 'the data packets and the probe');
    expect(last.largestAcked, relay.dataPackets + 1, reason: 'the resend has the newest sequence');
    await clientStream.close();
  });
}
