import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/constants.dart';
import 'package:test/test.dart';

/// Stands between a client and a server as a link with a small MTU does (a
/// mobile carrier's tunnel, 464XLAT) when a packet may not be fragmented:
/// every datagram larger than [maxSize] is dropped, in both directions; 0
/// passes everything. It counts the client's datagrams.
class _SmallMtuPath {
  _SmallMtuPath._(this.inside, this.outside, this.server, this.maxSize) {
    inside.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = inside.receive();
      if (d == null) return;
      sent++;
      if (!_passes(d.data.length)) return;
      _client = d;
      outside.send(d.data, server.address, server.port);
    });
    outside.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = outside.receive();
      final client = _client;
      if (d == null || client == null || !_passes(d.data.length)) return;
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

  /// The largest datagram the path carries from now on; 0 for any.
  int maxSize;

  /// Datagrams the client has sent.
  int sent = 0;
  Datagram? _client;

  bool _passes(int n) => maxSize == 0 || n <= maxSize;

  void close() {
    inside.close();
    outside.close();
  }
}

/// A client stream and the server's end of it, connected through [path].
/// The server's data is a single-subscription stream: it is read once, here,
/// into [_received].
class _Pair {
  _Pair(this.socket, this.client, this.server) {
    server.data.listen((data) {
      _received.add(data);
      final waiting = _waiting;
      if (waiting != null && _received.length >= _target) {
        _waiting = null;
        waiting.complete();
      }
    });
  }
  final UDPSocket socket;
  final UDXStream client;
  final UDXStream server;
  final _received = BytesBuilder(copy: false);
  Completer<void>? _waiting;
  int _target = 0;

  /// Writes [size] bytes and waits for the server to have them all, intact.
  Future<void> transfer(int size, {Duration within = const Duration(seconds: 10)}) async {
    final payload = Uint8List.fromList(List.generate(size, (i) => i % 251));
    final start = _received.length;
    _target = start + size;
    final all = _waiting = Completer<void>();
    await client.add(payload).timeout(within);
    await all.future.timeout(within);
    expect(Uint8List.sublistView(_received.toBytes(), start, start + size), equals(payload));
  }

  /// Waits for the validated datagram size to reach [atLeast].
  Future<void> waitForSize(int atLeast) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (socket.maxDatagram < atLeast) {
      if (DateTime.now().isAfter(deadline)) {
        fail('the datagram size reached ${socket.maxDatagram}, want at least $atLeast');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

Future<_Pair> _connect(int maxSize) async {
  final udx = UDX();
  final clientRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final serverRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final client = UDXMultiplexer(clientRaw);
  final server = UDXMultiplexer(serverRaw);
  final path = await _SmallMtuPath.start(serverRaw, maxSize);
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
  return _Pair(socket, clientStream, await serverStream.future.timeout(const Duration(seconds: 5)))
    .._path = path;
}

extension on _Pair {
  static final _paths = Expando<_SmallMtuPath>();
  _SmallMtuPath get path => _paths[this]!;
  set _path(_SmallMtuPath p) => _paths[this] = p;
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
    // A 1350-byte path, less the IPv4 and UDP headers.
    final pair = await _connect(1350 - 28);
    await pair.transfer(8 * 1024);
    await pair.client.close();
  });

  // Over loopback the search validates full-size datagrams during the
  // first transfer, and the next transfer goes out in them.
  test('over loopback the search reaches full-size datagrams', () async {
    final pair = await _connect(0);
    const size = 64 * 1024;
    await pair.transfer(size);
    await pair.waitForSize(maxDatagramSize);

    final before = pair.path.sent;
    await pair.transfer(size);
    final datagrams = pair.path.sent - before;
    final atMost = size ~/ (maxDatagramSize - streamPacketOverhead) + 4;
    expect(datagrams, lessThanOrEqualTo(atMost), reason: '$datagrams datagrams for $size bytes at ${pair.socket.maxDatagram}');
    await pair.client.close();
  });

  // Over a path that carries less than a full frame the search settles
  // under what it carries, and above the base.
  test('on a 1350-byte path the search settles under what it carries', () async {
    const path = 1350 - 28;
    final pair = await _connect(path);
    await pair.transfer(512 * 1024, within: const Duration(seconds: 20));
    await pair.waitForSize(path - mtuSearchStep + 1);
    expect(pair.socket.maxDatagram, lessThanOrEqualTo(path));
    await pair.client.close();
  });

  // A path that shrinks under a validated size (a carrier's tunnel after a
  // handover) drops every full-size packet: the socket falls back to the
  // base, re-chunks what it re-sends, and the transfer completes.
  test('a path that shrinks under the validated size: fall back to the base and complete', () async {
    final pair = await _connect(0);
    const size = 64 * 1024;
    await pair.transfer(size);
    await pair.waitForSize(maxDatagramSize);

    pair.path.maxSize = 1350 - 28;
    final start = DateTime.now();
    await pair.transfer(size, within: const Duration(seconds: 15));
    expect(pair.socket.maxDatagram, safeDatagramSize, reason: 'back at the base after the path shrank');
    // ignore: avoid_print
    print('recovered in ${DateTime.now().difference(start).inMilliseconds} ms');
    await pair.client.close();
  });
}
