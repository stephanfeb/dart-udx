import 'dart:io';
import 'dart:typed_data';
import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:dart_udx/dart_udx.dart';
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
      when(mockSocket.metricsObserver).thenReturn(null); // Metrics observer is optional
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

      // Verify that sendStreamPacket was called to send the SYN-ACK.
      // With per-connection sequencing, createIncoming calls socket.sendStreamPacket()
      // which handles sequence assignment and sends the packet.
      final verification = verify(mockSocket.sendStreamPacket(
        captureAny, captureAny, captureAny,
        trackForRetransmit: captureAnyNamed('trackForRetransmit'),
      ));
      // At least one call for SYN-ACK, possibly more for MaxDataFrame etc.
      verification.called(greaterThanOrEqualTo(1));

      // Inspect the captured frames to ensure SYN was sent
      final capturedFrames = verification.captured[2] as List<Frame>;
      final hasSynStreamFrame = capturedFrames.any((f) => f is StreamFrame && (f as StreamFrame).isSyn);
      expect(hasSynStreamFrame, isTrue, reason: 'The response must contain a StreamFrame with the SYN flag set.');
    });
  });
}

// We need a mock multiplexer for the socket mock to work
class MockUDXMultiplexer extends Mock implements UDXMultiplexer {}
final mockMultiplexer = MockUDXMultiplexer();
