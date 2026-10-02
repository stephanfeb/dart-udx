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

// go-udx and js-udx dial every connection from one shared socket, so a
// listener sees several connections from the same address, told apart only
// by connection ID.
void main() {
  test('two connections from one address are separate connections', () async {
    final serverRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peer = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = UDXMultiplexer(serverRaw);
    addTearDown(() {
      server.close();
      peer.close();
    });

    final sockets = <UDPSocket>[];
    final received = <UDPSocket, List<int>>{};
    final done = Completer<void>();
    server.connections.listen((socket) {
      sockets.add(socket);
      received[socket] = [];
      socket.on('stream').listen((e) {
        (e.data as UDXStream).data.listen((chunk) {
          received[socket]!.addAll(chunk);
          if (received.values.where((r) => r.isNotEmpty).length == 2 && !done.isCompleted) done.complete();
        });
      });
      socket.flushStreamBuffer();
    });

    void send(int cidByte, List<Frame> frames, {int src = 0, int seq = 0}) {
      final pkt = UDXPacket(
        destinationCid: ConnectionId(Uint8List.fromList(List.filled(8, cidByte))),
        sourceCid: ConnectionId(Uint8List.fromList(List.filled(8, cidByte + 0x80))),
        destinationStreamId: 0,
        sourceStreamId: src,
        sequence: seq,
        frames: frames,
      );
      peer.send(pkt.toBytes(), serverRaw.address, serverRaw.port);
    }

    for (final (cid, payload) in [(0x01, [1, 1, 1]), (0x02, [2, 2])]) {
      send(cid, [StreamFrame(data: Uint8List(0), isSyn: true)]);
      send(cid, [StreamFrame(data: Uint8List.fromList(payload), isSyn: true)], src: 1, seq: 1);
    }
    await done.future.timeout(const Duration(seconds: 3));

    expect(sockets, hasLength(2));
    expect(identical(sockets[0], sockets[1]), isFalse);
    expect(sockets.map((s) => s.cids.localCid.bytes.first).toSet(), {0x01, 0x02});
    expect(received[sockets[0]], [1, 1, 1]);
    expect(received[sockets[1]], [2, 2]);
  });
}
