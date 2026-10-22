import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/constants.dart';
import 'package:test/test.dart';

/// Stands between a client and a server as a link with a small MTU does (a
/// mobile carrier's tunnel, 464XLAT) when a packet may not be fragmented:
/// every datagram larger than [maxSize] is dropped.
class _SmallMtuPath {
  _SmallMtuPath._(this.inside, this.outside, this.server, this.maxSize) {
    inside.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = inside.receive();
      if (d == null || d.data.length > maxSize) return;
      _client = d;
      outside.send(d.data, server.address, server.port);
    });
    outside.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = outside.receive();
      final client = _client;
      if (d == null || client == null || d.data.length > maxSize) return;
      inside.send(d.data, client.address, client.port);
    });
  }

  static Future<_SmallMtuPath> start(RawDatagramSocket server, int maxSize) async => _SmallMtuPath._(
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
        server,
        maxSize,
      );

  final RawDatagramSocket inside;
  final RawDatagramSocket outside;
  final RawDatagramSocket server;
  final int maxSize;
  Datagram? _client;

  void close() {
    inside.close();
    outside.close();
  }
}

void main() {
  test('a full stream packet fits a safe datagram, with the longest connection IDs', () {
    final packet = UDXPacket(
      destinationCid: ConnectionId.random(length: ConnectionId.maxCidLength),
      sourceCid: ConnectionId.random(length: ConnectionId.maxCidLength),
      destinationStreamId: 0x7fffffff,
      sourceStreamId: 0x7fffffff,
      sequence: 0x7fffffff,
      frames: [StreamFrame(data: Uint8List(UDXStream.getMaxPayloadSizeTestHook()), offset: 0x7fffffff)],
    );
    expect(packet.toBytes().length, lessThanOrEqualTo(safeDatagramSize));
  });

  test('a write larger than one packet crosses a path that carries less than 1500 bytes', () async {
    final udx = UDX();
    final clientRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final serverRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final client = UDXMultiplexer(clientRaw);
    final server = UDXMultiplexer(serverRaw);
    // A 1350-byte path, less the IPv4 and UDP headers.
    final path = await _SmallMtuPath.start(serverRaw, 1350 - 28);
    addTearDown(() {
      client.close();
      server.close();
      path.close();
    });

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

    final payload = Uint8List.fromList(List.generate(8 * 1024, (i) => i % 251));
    final writing = clientStream.add(payload);
    final received = <int>[];
    final all = Completer<void>();
    (await serverStream.future.timeout(const Duration(seconds: 5))).data.listen((data) {
      received.addAll(data);
      if (received.length >= payload.length && !all.isCompleted) all.complete();
    });
    await writing;
    await all.future.timeout(const Duration(seconds: 5));
    expect(Uint8List.fromList(received), equals(payload));
    await clientStream.close();
  });
}
