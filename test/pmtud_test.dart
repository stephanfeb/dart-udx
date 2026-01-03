import 'package:test/test.dart';
import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/pmtud.dart';
import 'package:dart_udx/src/packet.dart';

void main() {
  group('PathMtuDiscoveryController', () {
    late PathMtuDiscoveryController controller;

    setUp(() {
      controller = PathMtuDiscoveryController(minMtu: 1280, maxMtu: 1500);
    });

    test('initial state is correct', () {
      expect(controller.state, PmtudState.initial);
      expect(controller.currentMtu, 1280);
    });

    test('buildProbePacket creates a correctly sized packet and updates state', () {
      expect(controller.state, PmtudState.initial);

      final (packet, sequence) = controller.buildProbePacket(
          ConnectionId.random(), ConnectionId.random(), 1, 2, 100);

      // Packet length should match the probe MTU
      expect(packet.toBytes().length, 1280);
      expect(sequence, 100);
      
      // Frame inside should be an MtuProbeFrame
      final frame = packet.frames.first;
      expect(frame, isA<MtuProbeFrame>());
      
      // Frame length should be packet length minus v2 header (34 bytes)
      expect(frame.length, 1280 - 34);

      // Controller should now be in the searching state
      expect(controller.state, PmtudState.searching);
    });

    test('onProbeAcked increases currentMtu and probes higher', () {
      // Initial probe
      final (_, seq1) = controller.buildProbePacket(
          ConnectionId.random(), ConnectionId.random(), 1, 2, 100);
      expect(controller.currentMtu, 1280);

      // Acknowledge the first probe
      controller.onProbeAcked(seq1);
      
      // The current MTU should be updated to the acknowledged size
      expect(controller.currentMtu, 1280);
      
      // The controller should now be searching for a larger MTU
      expect(controller.state, PmtudState.searching);

      // Build the next probe packet
      final (packet2, _) = controller.buildProbePacket(
          ConnectionId.random(), ConnectionId.random(), 1, 2, 101);
      
      // The next probe should be halfway between the current and max MTU
      final expectedNextProbeSize = (1280 + 1500) ~/ 2; // 1390
      expect(packet2.toBytes().length, expectedNextProbeSize);
    });

    test('onProbeLost decreases the search range and probes lower', () {
      // First probe (1280), which we will assume is ACKed to set a baseline
      final (_, seq1) = controller.buildProbePacket(
          ConnectionId.random(), ConnectionId.random(), 1, 2, 100);
      controller.onProbeAcked(seq1);
      expect(controller.currentMtu, 1280);

      // Second probe (1390)
      final (_, seq2) = controller.buildProbePacket(
          ConnectionId.random(), ConnectionId.random(), 1, 2, 101);
      expect(seq2, 101);

      // Simulate the loss of the second probe
      controller.onProbeLost(101);
      
      // The state should still be searching
      expect(controller.state, PmtudState.searching);

      // The next probe should be halfway between the last good MTU (1280)
      // and the failed size minus one (1390 - 1 = 1389).
      final (packet3, _) = controller.buildProbePacket(
          ConnectionId.random(), ConnectionId.random(), 1, 2, 102);
      final expectedNextProbeSize = (1280 + 1389) ~/ 2; // 1334
      expect(packet3.toBytes().length, expectedNextProbeSize);
    });

    test('search concludes when probe size cannot be increased', () {
      // Set a narrow search range
      controller = PathMtuDiscoveryController(minMtu: 1400, maxMtu: 1402);

      // First probe (1400)
      final (_, seq1) = controller.buildProbePacket(
          ConnectionId.random(), ConnectionId.random(), 1, 2, 100);
      controller.onProbeAcked(seq1);
      expect(controller.currentMtu, 1400);

      // Next probe (1401)
      final (packet2, seq2) = controller.buildProbePacket(
          ConnectionId.random(), ConnectionId.random(), 1, 2, 101);
      expect(packet2.toBytes().length, 1401);
      controller.onProbeAcked(seq2);
      expect(controller.currentMtu, 1401);

      // Next probe (1402)
      final (packet3, seq3) = controller.buildProbePacket(
          ConnectionId.random(), ConnectionId.random(), 1, 2, 102);
      expect(packet3.toBytes().length, 1402);
      controller.onProbeAcked(seq3);
      expect(controller.currentMtu, 1402);

      // At this point, the next probe would be (1402 + 1402) / 2 = 1402.
      // Since this is not > currentMtu, the search should stop.
      expect(controller.state, PmtudState.validated);
      expect(controller.shouldSendProbe(), isFalse);
    });

    test('shouldSendProbe returns true only when searching and no probes are in flight', () {
      expect(controller.shouldSendProbe(), isFalse); // Initial state

      controller.buildProbePacket(
          ConnectionId.random(), ConnectionId.random(), 1, 2, 100);
      expect(controller.state, PmtudState.searching);
      expect(controller.shouldSendProbe(), isFalse); // Probe is in-flight

      controller.onProbeAcked(100);
      expect(controller.shouldSendProbe(), isTrue); // Ready for next probe

      // Conclude the search
      controller.onProbeAcked(101); // Fake ack to advance state
      controller.onProbeAcked(102); // Fake ack to advance state
      controller.state; // Access state to trigger update
      if(controller.state != PmtudState.validated) {
        final (p, s) = controller.buildProbePacket(
            ConnectionId.random(), ConnectionId.random(), 1, 2, 103);
        controller.onProbeAcked(s);
      }
      
      // Once validated, should not send more probes
      // This part of the test is tricky without a full simulation loop
      // but we can force the state
      final finalController = PathMtuDiscoveryController(minMtu: 1499, maxMtu: 1500);
      final (_, seq1) = finalController.buildProbePacket(
          ConnectionId.random(), ConnectionId.random(), 1, 2, 200);
      finalController.onProbeAcked(seq1);
      expect(finalController.currentMtu, 1499);
      final (_, seq2) = finalController.buildProbePacket(
          ConnectionId.random(), ConnectionId.random(), 1, 2, 201);
      finalController.onProbeAcked(seq2);
      expect(finalController.currentMtu, 1500);
      expect(finalController.state, PmtudState.validated);
      expect(finalController.shouldSendProbe(), isFalse);
    });
  });
}
