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

// A raw UDP peer that behaves like go-udx and js-udx: it opens a stream with
// destination stream id 0 and never learns this side's id, so every later
// packet for the stream is addressed by its own (source) id alone.
void main() {
  group('STREAM_DATA_BLOCKED from a go-udx / js-udx peer', () {
    late RawDatagramSocket serverRaw;
    late RawDatagramSocket peer;
    late UDXMultiplexer server;
    final received = <UDXPacket>[];
    final dcid = ConnectionId(Uint8List.fromList([1, 1, 1, 1, 1, 1, 1, 1]));
    final scid = ConnectionId(Uint8List.fromList([2, 2, 2, 2, 2, 2, 2, 2]));
    const peerStreamId = 11;
    var seq = 0;

    void send(List<Frame> frames, {int dst = 0, int src = 0, int? sequence}) {
      final pkt = UDXPacket(
        destinationCid: dcid,
        sourceCid: scid,
        destinationStreamId: dst,
        sourceStreamId: src,
        sequence: sequence ?? seq++,
        frames: frames,
      );
      peer.send(pkt.toBytes(), serverRaw.address, serverRaw.port);
    }

    Future<List<WindowUpdateFrame>> windowUpdatesAfter(void Function() action) async {
      final before = received.length;
      action();
      await Future.delayed(const Duration(milliseconds: 200));
      return [
        for (final p in received.skip(before))
          if (p.destinationStreamId == peerStreamId) ...p.frames.whereType<WindowUpdateFrame>()
      ];
    }

    setUp(() async {
      received.clear();
      seq = 0;
      serverRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      peer = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      peer.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = peer.receive();
        if (d == null) return;
        try {
          received.add(UDXPacket.fromBytes(d.data));
        } catch (_) {}
      });
      server = UDXMultiplexer(serverRaw);
      final streamReady = Completer<UDXStream>();
      server.connections.listen((UDPSocket socket) {
        socket.on('stream').listen((e) {
          if (!streamReady.isCompleted) streamReady.complete(e.data as UDXStream);
        });
        socket.flushStreamBuffer();
      });

      // Connection SYN, then a stream opened go-udx style (dst 0, src 11).
      send([StreamFrame(data: Uint8List(0), isSyn: true)]);
      send([StreamFrame(data: Uint8List.fromList([1, 2, 3]), isSyn: true)], src: peerStreamId);
      await streamReady.future.timeout(const Duration(seconds: 2));
    });

    tearDown(() {
      server.close();
      peer.close();
    });

    test('is answered with a WINDOW_UPDATE re-advertising the current limit', () async {
      final updates = await windowUpdatesAfter(() => send(
            [StreamDataBlockedFrame(streamId: peerStreamId, maxStreamData: 65536)],
            src: peerStreamId,
            sequence: 0,
          ));
      expect(updates, hasLength(1));
      expect(updates.single.windowSize, greaterThanOrEqualTo(65536));
    });

    test('does not grow the window', () async {
      final first = await windowUpdatesAfter(() => send(
            [StreamDataBlockedFrame(streamId: peerStreamId, maxStreamData: 65536)],
            src: peerStreamId,
            sequence: 0,
          ));
      final second = await windowUpdatesAfter(() => send(
            [StreamDataBlockedFrame(streamId: peerStreamId, maxStreamData: 65536)],
            src: peerStreamId,
            sequence: 0,
          ));
      expect(second.single.windowSize, first.single.windowSize);
    });

    test('is routed by the sender\'s stream id when the destination id is not ours', () async {
      final updates = await windowUpdatesAfter(() => send(
            [StreamDataBlockedFrame(streamId: peerStreamId, maxStreamData: 65536)],
            dst: 9999,
            src: peerStreamId,
            sequence: 0,
          ));
      expect(updates, hasLength(1));
    });
  });
}
