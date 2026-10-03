import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/multiplexer.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:test/test.dart';

// A hole punch has both peers dial each other at once. Each dial is its own
// connection, as it is over go-udx and js-udx, which never merge them: a
// peer that folded the other's SYN into its own pending dial ended up
// answering both of the other side's connections from one socket.
void main() {
  group('UDX simultaneous open', () {
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

    /// Collects the connections [mux] accepts and the bytes each one receives.
    (List<UDPSocket>, Map<UDPSocket, List<int>>) accept(UDXMultiplexer mux) {
      final sockets = <UDPSocket>[];
      final received = <UDPSocket, List<int>>{};
      mux.connections.listen((socket) {
        sockets.add(socket);
        received[socket] = [];
        socket.on('stream').listen((e) {
          final stream = e.data as UDXStream;
          streams.add(stream);
          stream.data.listen(received[socket]!.addAll);
        });
        socket.flushStreamBuffer();
      });
      return (sockets, received);
    }

    Future<void> until(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out');
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }

    test('dials crossing each other are two connections', () async {
      final (acceptedA, receivedA) = accept(muxA);
      final (acceptedB, receivedB) = accept(muxB);

      final dialA = muxA.createSocket(udx, rawB.address.address, rawB.port);
      final dialB = muxB.createSocket(udx, rawA.address.address, rawA.port);
      final opened = await Future.wait([
        UDXStream.createOutgoing(udx, dialA, 100, 101, rawB.address.address, rawB.port),
        UDXStream.createOutgoing(udx, dialB, 200, 201, rawA.address.address, rawA.port),
      ]);
      streams.addAll(opened);

      await opened[0].add(Uint8List.fromList([1, 2, 3]));
      await opened[1].add(Uint8List.fromList([4, 5, 6]));
      await until(() =>
          acceptedA.length == 1 &&
          acceptedB.length == 1 &&
          receivedA[acceptedA.single]!.length == 3 &&
          receivedB[acceptedB.single]!.length == 3);

      expect(identical(acceptedA.single, dialA), isFalse);
      expect(identical(acceptedB.single, dialB), isFalse);
      expect(receivedB[acceptedB.single], [1, 2, 3]);
      expect(receivedA[acceptedA.single], [4, 5, 6]);
    });

    test('a dial does not reuse a connection the peer opened', () async {
      final (acceptedB, _) = accept(muxB);

      final dialA = muxA.createSocket(udx, rawB.address.address, rawB.port);
      streams.add(await UDXStream.createOutgoing(
          udx, dialA, 100, 101, rawB.address.address, rawB.port));
      await until(() => acceptedB.length == 1);

      final dialB = muxB.createSocket(udx, rawA.address.address, rawA.port);
      expect(identical(dialB, acceptedB.single), isFalse);
      expect(dialB.isServer, isFalse);
      expect(identical(muxB.createSocket(udx, rawA.address.address, rawA.port), dialB), isTrue,
          reason: 'a second dial to the same address still shares the first');
    });
  });
}
