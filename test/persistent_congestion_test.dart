import 'dart:typed_data';

import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/congestion.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:test/test.dart';

void main() {
  group('Persistent Congestion', () {
    late CongestionController controller;
    late PacketManager packetManager;

    setUp(() {
      packetManager = PacketManager();
      controller = CongestionController(packetManager: packetManager);
      packetManager.congestionController = controller;
    });

    test('collapses cwnd to minimum on persistent congestion', () async {
      // 1. Get an RTT sample
      controller.onPacketSent(1000);
      await Future.delayed(const Duration(milliseconds: 100));
      controller.onPacketAcked(1000, DateTime.now().subtract(const Duration(milliseconds: 100)), Duration.zero, true, 0);
      expect(controller.smoothedRtt, isNot(equals(const Duration(milliseconds: 100)))); // Ensure RTT has been updated

      // 2. Send a burst of packets that will be lost
      final lostPackets = <UDXPacket>[];
      for (int i = 1; i <= 5; i++) {
        final packet = UDXPacket(destinationCid: ConnectionId.random(), sourceCid: ConnectionId.random(), destinationStreamId: 1, sourceStreamId: 2, sequence: i, frames: [StreamFrame(data: Uint8List(100))]);
        packetManager.sendPacket(packet);
        controller.onPacketSent(100);
        lostPackets.add(packet);
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // 3. Let enough time pass to exceed the persistent congestion threshold
      // PTO is ~300ms. Threshold is 3. So we need to wait > 900ms.
      await Future.delayed(const Duration(milliseconds: 1000));

      // 4. Trigger loss detection by acknowledging a later packet
      final ackPacket = UDXPacket(destinationCid: ConnectionId.random(), sourceCid: ConnectionId.random(), destinationStreamId: 1, sourceStreamId: 2, sequence: 6, frames: []);
      packetManager.sendPacket(ackPacket);
      controller.onPacketSent(0);
      controller.onPacketAcked(0, DateTime.now(), Duration.zero, true, 6);

      // 5. Manually trigger onPacketLost for the lost packets
      controller.onPacketLost(500, lostPackets);

      // 6. Verify that cwnd is collapsed to the minimum
      expect(controller.cwnd, equals(CongestionController.minCwnd));
    });
  });
}
