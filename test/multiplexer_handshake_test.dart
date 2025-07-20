import 'dart:io';
import 'dart:typed_data';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/udx.dart';
import 'package:test/test.dart';

void main() {
  group('UDXMultiplexer Handshake', () {
    late RawDatagramSocket rawSocket;
    late UDXMultiplexer multiplexer;

    setUp(() async {
      rawSocket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      multiplexer = UDXMultiplexer(rawSocket);
    });

    tearDown(() {
      multiplexer.close();
    });

    test('should only create one socket on retransmitted SYN', () async {
      final remoteAddress = InternetAddress.loopbackIPv4;
      const remotePort = 12345;

      final clientCid = ConnectionId.random();
      final initialDestCid = ConnectionId.random(); // The temporary CID

      final synPacket = UDXPacket(
        destinationCid: initialDestCid,
        sourceCid: clientCid,
        destinationStreamId: 1,
        sourceStreamId: 1,
        sequence: 0,
        frames: [StreamFrame(data: Uint8List(0), isSyn: true)],
      );
      final synBytes = synPacket.toBytes();

      // We expect the connections stream to emit exactly one socket.
      // The bug will cause it to emit two.
      final expectation = expectAsync1((_) {}, count: 1);
      multiplexer.connections.listen(expectation);

      // Simulate receiving the first SYN
      multiplexer.handleIncomingDatagramForTest(
          synBytes, remoteAddress, remotePort);

      // Simulate receiving the retransmitted SYN
      multiplexer.handleIncomingDatagramForTest(
          synBytes, remoteAddress, remotePort);
    });

    test('createSocket should be idempotent for the same peer', () {
      final udx = UDX();
      // 1. Call multiplexer.createSocket for a specific peer (host/port).
      final socket1 = multiplexer.createSocket(
        udx, '127.0.0.1', 12345
      );

      // 2. Call it a second time for the exact same peer.
      final socket2 = multiplexer.createSocket(
        udx, '127.0.0.1', 12345
      );

      // 3. Assert that the two returned socket instances are the same.
      expect(identical(socket1, socket2), isTrue);

      // 4. Assert that the multiplexer's internal socket list still only has one entry.
      expect(multiplexer.getSocketsForTest().length, 1);
    });

    test('server-side socket should be created with the client-specified destination CID', () async {
      final remoteAddress = InternetAddress.loopbackIPv4;
      const remotePort = 54321;

      final clientCid = ConnectionId.random();
      final serverCid = ConnectionId.random(); // This is the CID the client wants the server to use.

      final synPacket = UDXPacket(
        destinationCid: serverCid, // Client sends to this specific CID
        sourceCid: clientCid,
        destinationStreamId: 1,
        sourceStreamId: 1,
        sequence: 0,
        frames: [StreamFrame(data: Uint8List(0), isSyn: true)],
      );
      final synBytes = synPacket.toBytes();

      // We expect the new socket to have the CID specified by the client.
      final expectation = expectAsync1((UDPSocket newSocket) {
        expect(newSocket.cids.localCid, equals(serverCid));
      });
      multiplexer.connections.listen(expectation);

      // Simulate receiving the SYN packet.
      multiplexer.handleIncomingDatagramForTest(
          synBytes, remoteAddress, remotePort);
    });
  });
}
