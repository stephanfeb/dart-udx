import 'dart:io';
import 'dart:typed_data';
import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/multiplexer.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:dart_udx/udx.dart';
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';

import 'socket_handshake_test.mocks.dart';

@GenerateMocks([UDXMultiplexer])
void main() {
  group('UDPSocket Handshake', () {
    late UDPSocket socket;
    late MockUDXMultiplexer mockMultiplexer;
    late UDX udx;
    final remoteAddress = InternetAddress.loopbackIPv4;
    const remotePort = 12345;

    setUp(() {
      udx = UDX();
      mockMultiplexer = MockUDXMultiplexer();
      final initialCids = ConnectionCids(
        ConnectionId.random(), // localCid
        ConnectionId.random(), // remoteCid
      );
      socket = UDPSocket(
        udx: udx,
        multiplexer: mockMultiplexer,
        remoteAddress: remoteAddress,
        remotePort: remotePort,
        cids: initialCids,
      );
    });

    test('should update remoteCid on every handshake packet', () {
      // 1. Create the first SYN packet from a client
      final clientCid1 = ConnectionId.random();
      final serverTempCid = socket.cids.localCid;
      final synPacket1 = UDXPacket(
        destinationCid: serverTempCid,
        sourceCid: clientCid1,
        destinationStreamId: 1,
        sourceStreamId: 1,
        sequence: 0,
        frames: [StreamFrame(data: Uint8List(0), isSyn: true)],
      );
      final synBytes1 = synPacket1.toBytes();

      // 2. Simulate the server socket receiving this first packet
      socket.handleIncomingDatagram(synBytes1, remoteAddress, remotePort);

      // 3. Assert that the remoteCid was updated correctly
      expect(socket.cids.remoteCid, equals(clientCid1));

      // 4. Create a retransmitted SYN packet. This time, the client might have
      //    a different source CID (this is unlikely but possible, the key is that the socket should handle it)
      final clientCid2 = ConnectionId.random();
      final synPacket2 = UDXPacket(
        destinationCid: serverTempCid,
        sourceCid: clientCid2,
        destinationStreamId: 1,
        sourceStreamId: 1,
        sequence: 0, // Same sequence number
        frames: [StreamFrame(data: Uint8List(0), isSyn: true)],
      );
      final synBytes2 = synPacket2.toBytes();

      // 5. Simulate receiving the retransmitted packet
      socket.handleIncomingDatagram(synBytes2, remoteAddress, remotePort);

      // 6. Assert that the remoteCid is updated AGAIN. This is the part that will fail.
      //    The current code only updates the CID if `_handshakeCompleted` is false.
      expect(socket.cids.remoteCid, equals(clientCid2),
          reason:
              'Socket should update remoteCid even on retransmitted SYNs when handshake is considered complete');
    });
  });
}
