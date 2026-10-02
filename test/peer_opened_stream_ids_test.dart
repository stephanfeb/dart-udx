import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/multiplexer.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:test/test.dart';

// go-udx and js-udx never learn the id we give a stream they open: they
// address it to destination 0 for its whole life and identify it by their own
// (source) id. Each such stream must still get its own local id here, or every
// one after the first lands in the first.
void main() {
  late RawDatagramSocket serverRaw;
  late RawDatagramSocket peer;
  late UDXMultiplexer server;
  final streams = <UDXStream>[];
  final received = <UDXStream, List<int>>{};
  final replies = <UDXPacket>[];
  var seq = 0;

  setUp(() async {
    serverRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    peer = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    server = UDXMultiplexer(serverRaw);
    streams.clear();
    received.clear();
    replies.clear();
    seq = 0;
    server.connections.listen((UDPSocket socket) {
      socket.on('stream').listen((e) {
        final s = e.data as UDXStream;
        if (received.containsKey(s)) return;
        streams.add(s);
        received[s] = [];
        s.data.listen((chunk) => received[s]!.addAll(chunk));
      });
      socket.flushStreamBuffer();
    });
    peer.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = peer.receive();
      if (d != null) replies.add(UDXPacket.fromBytes(d.data));
    });
  });

  tearDown(() {
    server.close();
    peer.close();
  });

  void send(List<Frame> frames, {int dst = 0, required int src}) {
    final pkt = UDXPacket(
      destinationCid: ConnectionId(Uint8List.fromList(List.filled(8, 0x11))),
      sourceCid: ConnectionId(Uint8List.fromList(List.filled(8, 0x22))),
      destinationStreamId: dst,
      sourceStreamId: src,
      sequence: seq++,
      frames: frames,
    );
    peer.send(pkt.toBytes(), serverRaw.address, serverRaw.port);
  }

  Future<void> until(bool Function() cond) async {
    final end = DateTime.now().add(const Duration(seconds: 3));
    while (!cond()) {
      if (DateTime.now().isAfter(end)) fail('timed out');
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  StreamFrame syn(List<int> data) => StreamFrame(data: Uint8List.fromList(data), isSyn: true);

  test('streams a peer opens to destination 0 get distinct local ids', () async {
    send([syn([1, 1, 1])], src: 1);
    send([syn([3, 3])], src: 3);
    await until(() => streams.length == 2 && received.values.every((r) => r.isNotEmpty));
    send([StreamFrame(data: Uint8List.fromList([1]), offset: 3)], src: 1);
    send([StreamFrame(data: Uint8List.fromList([3]), offset: 2)], src: 3);
    await until(() => received[streams[0]]!.length == 4 && received[streams[1]]!.length == 3);

    expect(streams.map((s) => s.remoteId).toList(), [1, 3]);
    expect(received[streams[0]], [1, 1, 1, 1]);
    expect(received[streams[1]], [3, 3, 3]);
    expect(streams[0].id, isNot(0));
    expect(streams[1].id, isNot(0));
    expect(streams[0].id, isNot(streams[1].id));

    // Replies tell the peer which of its streams they belong to, and our id.
    await until(() => replies.any((p) => p.destinationStreamId == 3));
    final toThree = replies.firstWhere((p) => p.destinationStreamId == 3 && p.frames.any((f) => f is StreamFrame));
    expect(toThree.sourceStreamId, streams[1].id);
  });

  test('a stream opened while the previous one is closing gets its own id', () async {
    send([syn([1])], src: 1);
    await until(() => streams.length == 1);
    // Both ends finish stream 1; Dart keeps it registered while it closes.
    send([StreamFrame(data: Uint8List(0), isFin: true, offset: 1)], src: 1);
    unawaited(streams[0].closeWrite());
    send([syn([5, 5])], src: 5);
    await until(() => streams.length == 2 && received[streams[1]]!.length == 2);
    expect(streams[1].remoteId, 5);
    expect(received[streams[1]], [5, 5]);
  });

  test('a peer that names our id keeps it (dart-libp2p picks both ids)', () async {
    send([syn([7])], dst: 777, src: 9);
    await until(() => streams.length == 1);
    expect(streams[0].id, 777);
    expect(streams[0].remoteId, 9);
  });
}
