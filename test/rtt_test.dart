import 'dart:typed_data';
import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/congestion.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:test/test.dart';
import 'dart:async';

void main() {
  group('RTT Calculation', () {
    late CongestionController controller;
    late PacketManager packetManager;

    setUp(() {
      // In the real implementation, these two have a circular dependency.
      // For this test, we can manage them manually.
      packetManager = PacketManager();
      controller = CongestionController(packetManager: packetManager);
      packetManager.congestionController = controller;
    });

    test('calculates initial RTT correctly', () {
      final sentTime = DateTime.now().subtract(const Duration(milliseconds: 150));
      const ackDelay = Duration(milliseconds: 20);

      controller.onPacketAcked(1000, sentTime, ackDelay, true, 0);

      expect(controller.latestRttForTest.inMilliseconds, closeTo(130, 5)); // 150 - 20
      expect(controller.smoothedRtt.inMilliseconds, isNot(0));
      expect(controller.rttVar.inMilliseconds, isNot(0));
    });

    test('updates smoothed RTT and RTT variance over time', () {
      // First sample
      controller.onPacketAcked(1000, DateTime.now().subtract(const Duration(milliseconds: 100)), Duration.zero, true, 0);
      final initialRtt = controller.smoothedRtt;

      // Second, faster sample
      controller.onPacketAcked(1000, DateTime.now().subtract(const Duration(milliseconds: 50)), Duration.zero, true, 1);
      final secondRtt = controller.smoothedRtt;

      expect(secondRtt.inMicroseconds, lessThan(initialRtt.inMicroseconds));

      // Third, slower sample
      controller.onPacketAcked(1000, DateTime.now().subtract(const Duration(milliseconds: 200)), Duration.zero, true, 2);
      final thirdRtt = controller.smoothedRtt;

      expect(thirdRtt.inMicroseconds, greaterThan(secondRtt.inMicroseconds));
    });

    test('does not update RTT for non-cumulative ACKs (SACKs)', () {
      // Establish an initial RTT
      final sentTimeInitial = DateTime.now().subtract(const Duration(milliseconds: 200));
      controller.onPacketAcked(1000, sentTimeInitial, Duration.zero, true, 0);
      final initialRtt = controller.smoothedRtt;

      // Simulate a SACK for a packet that doesn't advance the cumulative ACK point
      final sentTimeSack = DateTime.now().subtract(const Duration(milliseconds: 50));
      controller.onPacketAcked(1000, sentTimeSack, Duration.zero, false, 0); // isNewCumulativeAck is false
      final rttAfterSack = controller.smoothedRtt;

      // The RTT should NOT have changed
      expect(rttAfterSack, equals(initialRtt));
    });

    test('bases RTT on retransmission time, not original send time', () async {
      final originalSentTime = DateTime.now().subtract(const Duration(seconds: 2));
      final packet = UDXPacket(
        destinationCid: ConnectionId.random(),
        sourceCid: ConnectionId.random(),
        destinationStreamId: 1,
        sourceStreamId: 1,
        sequence: 0,
        frames: [StreamFrame(data: Uint8List(100))],
        sentTime: originalSentTime,
      );

      // Mock the onRetransmit callback
      UDXPacket? retransmittedPacket;
      packetManager.onRetransmit = (p) {
        retransmittedPacket = p;
        // Simulate the retransmission happening after a delay
        // In the bug, the sentTime is NOT updated here.
        // A correct implementation WOULD update it: p.sentTime = DateTime.now();
      };

      // Manually trigger the retransmission logic from _scheduleRetransmission
      final retransmitCompleter = Completer<void>();
      Timer(const Duration(milliseconds: 10), () {
        // This simulates the retransmit timer firing.
        // We directly call the logic that would be inside the timer's callback.
        if (packetManager.getSentPacketsTestHook().containsKey(0)) {
           packetManager.onRetransmit?.call(packet);
        }
        retransmitCompleter.complete();
      });

      packetManager.sendPacket(packet);
      await retransmitCompleter.future;

      // Now, simulate an ACK arriving for this retransmitted packet
      // This ACK arrives very shortly after the retransmission.
      await Future.delayed(const Duration(milliseconds: 50));
      
      // In the buggy version, the RTT will be calculated based on the originalSentTime (2 seconds ago).
      // In the correct version, it should be based on the retransmission time (50ms ago).
      controller.onPacketAcked(100, retransmittedPacket!.sentTime!, Duration.zero, true, 0);

      // The RTT should be around 50ms, not 2050ms.
      // We give a generous delta to account for test execution variance.
      expect(controller.latestRttForTest.inMilliseconds, lessThan(200));
      expect(controller.latestRttForTest.inMilliseconds, greaterThan(10));
    }, timeout: const Timeout(Duration(seconds: 1)));
  });
}
