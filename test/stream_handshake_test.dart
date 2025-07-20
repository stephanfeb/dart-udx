import 'dart:io';
import 'dart:typed_data';
import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:dart_udx/udx.dart';
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';

import 'stream_handshake_test.mocks.dart';

@GenerateMocks([UDPSocket])
void main() {
  group('UDXStream Handshake', () {
    late MockUDPSocket mockSocket;
    late UDX udx;

    setUp(() {
      udx = UDX();
      mockSocket = MockUDPSocket();
      // Mock the necessary properties of the socket
      when(mockSocket.cids).thenReturn(ConnectionCids(
        ConnectionId.random(), // local
        ConnectionId.random(), // remote
      ));
      when(mockSocket.multiplexer).thenReturn(mockMultiplexer);
      when(mockSocket.closing).thenReturn(false);
      when(mockSocket.getAvailableConnectionSendWindow()).thenReturn(1500);
      when(mockSocket.on(any)).thenAnswer((_) => Stream.empty());
      // We will set up popInitialPacket on a per-test basis
      when(mockSocket.sendMaxDataFrame(any, streamId: anyNamed('streamId')))
          .thenAnswer((_) async {});
    });

    test('incoming stream should send a SYN-ACK', () {
      final remoteAddress = InternetAddress.loopbackIPv4.address;
      const remotePort = 12345;
      final clientCid = ConnectionId.random();
      final serverCid = ConnectionId.random();

      // 1. Create a fake incoming SYN packet that the socket will "receive".
      final incomingSynPacket = UDXPacket(
        destinationCid: serverCid,
        sourceCid: clientCid,
        destinationStreamId: 101,
        sourceStreamId: 100,
        sequence: 0, // Initial sequence from client
        frames: [StreamFrame(data: Uint8List(0), isSyn: true)],
      );
      final incomingSynBytes = incomingSynPacket.toBytes();

      // 2. Stub the popInitialPacket method to return our fake SYN packet.
      when(mockSocket.popInitialPacket(101)).thenReturn(incomingSynBytes);

      // 3. When the stream is created, it should now process the packet and send a SYN-ACK.
      final newStream = UDXStream.createIncoming(
        udx,
        mockSocket,
        101, // streamId
        100, // remoteStreamId
        remoteAddress,
        remotePort,
        initialSeq: 1,
        destinationCid: serverCid,
        sourceCid: clientCid,
      );

      // We need to verify that the `send` method on the socket was called.
      // The argument passed to `send` should be a Uint8List representing a UDXPacket.
      final verification = verify(mockSocket.send(captureAny));
      verification.called(1);

      // Now, let's inspect the captured packet to ensure it's a SYN-ACK.
      final captured = verification.captured.first as Uint8List;
      final sentPacket = UDXPacket.fromBytes(captured);

      final hasSynStreamFrame = sentPacket.frames.any((f) => f is StreamFrame && f.isSyn);
      final hasAckFrame = sentPacket.frames.any((f) => f is AckFrame);

      expect(hasSynStreamFrame, isTrue, reason: 'The response packet must contain a StreamFrame with the SYN flag set.');
      expect(hasAckFrame, isTrue, reason: 'The response packet must contain an AckFrame.');
      expect(sentPacket.destinationCid, equals(clientCid),
          reason: 'The packet should be addressed to the client CID.');
    });
  });
}

// We need a mock multiplexer for the socket mock to work
class MockUDXMultiplexer extends Mock implements UDXMultiplexer {}
final mockMultiplexer = MockUDXMultiplexer();
