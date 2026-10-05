import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/multiplexer.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:test/test.dart';

// Two callers that dial the same address at once must not share one
// connection: the caller that gives up on its dial closes its socket, and
// that also closed the other caller's connection. With `shared: false` each
// dial is its own connection, as in go-udx.
void main() {
  group('UDX unshared dials', () {
    late UDX udx;
    late RawDatagramSocket rawA;
    late RawDatagramSocket rawB;
    late UDXMultiplexer muxA;
    late UDXMultiplexer muxB;
    final streams = <UDXStream>[];

    setUp(() async {
      udx = UDX();
      rawA = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      rawB = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      muxA = UDXMultiplexer(rawA);
      muxB = UDXMultiplexer(rawB);
    });

    tearDown(() async {
      for (final s in streams) {
        await s.close();
      }
      streams.clear();
      muxA.close();
      muxB.close();
    });

    Future<void> until(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out');
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }

    test('two dials to one address are two connections', () async {
      final host = rawB.address.address;
      final first = muxA.createSocket(udx, host, rawB.port, shared: false);
      final second = muxA.createSocket(udx, host, rawB.port, shared: false);

      expect(identical(first, second), isFalse);
      expect(first.cids.localCid == second.cids.localCid, isFalse);
      expect(muxA.socketsByPeer, isEmpty, reason: 'an unshared dial is not reused');
      expect(identical(muxA.createSocket(udx, host, rawB.port), first), isFalse);
    });

    test('closing one dial leaves the other connection working', () async {
      final accepted = <UDPSocket>[];
      final received = <UDPSocket, List<int>>{};
      muxB.connections.listen((socket) {
        accepted.add(socket);
        received[socket] = [];
        socket.on('stream').listen((e) {
          final stream = e.data as UDXStream;
          streams.add(stream);
          stream.data.listen(received[socket]!.addAll);
        });
        socket.flushStreamBuffer();
      });

      final host = rawB.address.address;
      final keep = muxA.createSocket(udx, host, rawB.port, shared: false);
      final drop = muxA.createSocket(udx, host, rawB.port, shared: false);
      final keepStream = await UDXStream.createOutgoing(udx, keep, 1, 2, host, rawB.port);
      final dropStream = await UDXStream.createOutgoing(udx, drop, 3, 4, host, rawB.port);
      streams.addAll([keepStream, dropStream]);
      await until(() => accepted.length == 2);

      var keepClosed = false;
      keep.on('close').listen((_) => keepClosed = true);
      await drop.close();

      await keepStream.add(Uint8List.fromList([7, 8, 9]));
      await until(() => received.values.any((bytes) => bytes.length == 3));
      expect(keepClosed, isFalse);
      expect(keep.closing, isFalse);
    });
  });
}
