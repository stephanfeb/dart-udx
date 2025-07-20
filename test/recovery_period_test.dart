import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/congestion.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:test/test.dart';

void main() {
  group('Congestion Recovery Period', () {
    late CongestionController controller;
    late PacketManager packetManager;

    setUp(() {
      packetManager = PacketManager();
      controller = CongestionController(packetManager: packetManager, initialCwnd: 15000);
      packetManager.congestionController = controller;
    });

    test('cwnd is only reduced once per recovery period', () {
      // Simulate sending 5 packets
      packetManager.sendPacket(UDXPacket(destinationCid: ConnectionId.random(), sourceCid: ConnectionId.random(), destinationStreamId: 1, sourceStreamId: 2, sequence: 0, frames: []));
      controller.onPacketSent(1500);
      packetManager.sendPacket(UDXPacket(destinationCid: ConnectionId.random(), sourceCid: ConnectionId.random(), destinationStreamId: 1, sourceStreamId: 2, sequence: 1, frames: []));
      controller.onPacketSent(1500);
      packetManager.sendPacket(UDXPacket(destinationCid: ConnectionId.random(), sourceCid: ConnectionId.random(), destinationStreamId: 1, sourceStreamId: 2, sequence: 2, frames: []));
      controller.onPacketSent(1500);
      packetManager.sendPacket(UDXPacket(destinationCid: ConnectionId.random(), sourceCid: ConnectionId.random(), destinationStreamId: 1, sourceStreamId: 2, sequence: 3, frames: []));
      controller.onPacketSent(1500);
      packetManager.sendPacket(UDXPacket(destinationCid: ConnectionId.random(), sourceCid: ConnectionId.random(), destinationStreamId: 1, sourceStreamId: 2, sequence: 4, frames: []));
      controller.onPacketSent(1500);

      final initialCwnd = controller.cwnd;
      
      // 1. First loss event. Enter recovery.
      controller.onPacketLost(1500, []);
      final cwndAfterFirstLoss = controller.cwnd;

      expect(controller.isInRecoveryForTest, isTrue, reason: 'Controller should be in recovery after the first loss.');
      expect(cwndAfterFirstLoss, lessThan(initialCwnd), reason: 'CWND should be reduced after the first loss.');
      expect(cwndAfterFirstLoss, equals(controller.ssthresh), reason: 'CWND should be set to ssthresh.');

      // 2. Second loss event within the same recovery period.
      controller.onPacketLost(1500, []);
      final cwndAfterSecondLoss = controller.cwnd;

      expect(cwndAfterSecondLoss, equals(cwndAfterFirstLoss), reason: 'CWND should NOT be reduced again while already in recovery.');

      // 3. Acknowledge a packet sent *after* the recovery period started.
      // The last sent packet was 4, so that's what _recoveryEndPacketNumber is set to.
      // We need to send and ack a new packet.
      packetManager.sendPacket(UDXPacket(destinationCid: ConnectionId.random(), sourceCid: ConnectionId.random(), destinationStreamId: 1, sourceStreamId: 2, sequence: 5, frames: []));
      controller.onPacketSent(1500);
      
      // Acknowledging packet 5 should exit recovery.
      controller.onPacketAcked(1500, DateTime.now(), Duration.zero, true, 5);
      expect(controller.isInRecoveryForTest, isFalse, reason: 'Controller should exit recovery after a new packet is acknowledged.');

      // 4. Third loss event, after recovery has ended.
      // This should trigger a new CWND reduction.
      controller.onPacketLost(1500, []);
      final cwndAfterThirdLoss = controller.cwnd;
      expect(cwndAfterThirdLoss, lessThan(cwndAfterSecondLoss), reason: 'CWND should be reduced again after exiting recovery.');
    });
  });
}
