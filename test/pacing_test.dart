import 'package:dart_udx/src/clock.dart';
import 'package:dart_udx/src/congestion.dart';
import 'package:dart_udx/src/constants.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:dart_udx/src/pacing.dart';
import 'package:test/test.dart';

void main() {
  late FakeClock clock;

  setUp(() {
    clock = FakeClock();
  });

  CongestionController controller() {
    final pm = PacketManager(clock: clock);
    final cc = CongestionController(packetManager: pm, clock: clock);
    pm.congestionController = cc;
    addTearDown(() {
      cc.destroy();
      pm.destroy();
    });
    return cc;
  }

  test('until an RTT sample exists nothing is paced', () {
    final cc = controller();
    for (var i = 0; i < 50; i++) {
      cc.onPacketSent(maxDatagramSize);
      cc.pacingController.onPacketSent(maxDatagramSize);
      expect(cc.pacingController.timeUntilSend(), Duration.zero, reason: 'paced after ${i + 1} packets');
    }
  });

  test('the rate follows the window through slow start, at twice cwnd / srtt, and drops to 1.25 after a loss', () {
    final cc = controller();
    const rtt = Duration(milliseconds: 50);
    double rateFor(double gain) => gain * cc.cwnd / 0.05;

    var sent = clock.now();
    cc.onPacketSent(maxDatagramSize);
    clock.advance(rtt);
    cc.onPacketAcked(maxDatagramSize, sent, Duration.zero, true, 0);
    expect(cc.smoothedRtt, rtt);

    for (var ack = 1; ack <= 20; ack++) {
      expect(cc.pacingController.pacingRateBytesPerSec, closeTo(rateFor(PacingController.pacingGainSlowStart), 1e-6),
          reason: 'after ack $ack, cwnd ${cc.cwnd}');
      sent = clock.now();
      cc.onPacketSent(maxDatagramSize);
      clock.advance(rtt);
      cc.onPacketAcked(maxDatagramSize, sent, Duration.zero, true, ack);
    }
    final grown = cc.cwnd;
    expect(grown, greaterThan(initialCongestionWindow), reason: 'the window grew');

    cc.onPacketLost(0, const []);
    expect(cc.cwnd, lessThan(grown), reason: 'the window contracted');
    expect(cc.pacingController.pacingRateBytesPerSec, closeTo(rateFor(PacingController.pacingGain), 1e-6),
        reason: 'the congestion-avoidance gain after a loss');

    cc.onPersistentCongestion();
    expect(cc.cwnd, minCongestionWindow);
    expect(cc.pacingController.pacingRateBytesPerSec, closeTo(rateFor(PacingController.pacingGainSlowStart), 1e-6),
        reason: 'the window collapsed and is back in slow start');
  });

  test('a burst goes out without waiting; then the budget refills at the rate', () {
    final pacer = PacingController(clock: clock);
    const rate = 1 << 20; // 1.25 MB/s after the gain: a 1472-byte datagram every 1.1 ms
    pacer.updateRate(rate, const Duration(seconds: 1), slowStart: false);
    final want = PacingController.pacingGain * rate;

    for (var i = 0; i < PacingController.burstPackets; i++) {
      expect(pacer.timeUntilSend(), Duration.zero, reason: 'packet ${i + 1} of the burst had to wait');
      pacer.onPacketSent(maxDatagramSize);
    }
    final wait = pacer.timeUntilSend();
    expect(wait, greaterThanOrEqualTo(PacingController.minPacingDelay));
    clock.advance(wait);
    expect(pacer.timeUntilSend(), Duration.zero, reason: 'the budget refilled after the wait it asked for');

    // Send whenever allowed for one second.
    var sent = 0;
    final start = clock.now();
    while (clock.now() - start < const Duration(seconds: 1)) {
      final wait = pacer.timeUntilSend();
      if (wait > Duration.zero) {
        clock.advance(wait);
        continue;
      }
      pacer.onPacketSent(maxDatagramSize);
      sent += maxDatagramSize;
    }
    const burst = PacingController.burstPackets * maxDatagramSize;
    expect(sent, inInclusiveRange(want * 0.95, want * 1.05 + burst), reason: 'a second at $want B/s');
  });

  test('at a high rate the burst is what the minimum delay of it is worth', () {
    final pacer = PacingController(clock: clock);
    pacer.updateRate(40 << 20, const Duration(seconds: 1), slowStart: false); // 50 MB/s
    final byDelay = pacer.pacingRateBytesPerSec * PacingController.minPacingDelay.inMicroseconds / 1e6;
    expect(pacer.budget, greaterThanOrEqualTo(byDelay));
    expect(pacer.budget, greaterThan(PacingController.burstPackets * maxDatagramSize));
  });

  test('an overshoot is paid for by the wait after it', () {
    final pacer = PacingController(clock: clock);
    pacer.updateRate(1 << 20, const Duration(seconds: 1), slowStart: false);
    for (var i = 0; i < 2 * PacingController.burstPackets; i++) {
      pacer.onPacketSent(maxDatagramSize);
    }
    expect(pacer.budget, lessThan(0));
    const debt = PacingController.burstPackets * maxDatagramSize + maxDatagramSize;
    final want = debt / pacer.pacingRateBytesPerSec * 1e6;
    expect(pacer.timeUntilSend().inMicroseconds, closeTo(want, 1000));
  });

  test('a zero RTT is unpaced', () {
    final pacer = PacingController(clock: clock);
    pacer.updateRate(14720, Duration.zero, slowStart: true);
    for (var i = 0; i < 100; i++) {
      pacer.onPacketSent(maxDatagramSize);
    }
    expect(pacer.timeUntilSend(), Duration.zero);
  });

  test('waitUntilReady sets a whole-millisecond timer, rounded up', () async {
    final pacer = PacingController(clock: clock);
    pacer.updateRate(1 << 20, const Duration(seconds: 1), slowStart: false); // 1310720 B/s
    for (var i = 0; i < 12; i++) {
      pacer.onPacketSent(maxDatagramSize); // 2944 bytes overdrawn: 4416 short, 3.37 ms
    }
    expect(pacer.timeUntilSend(), const Duration(microseconds: 3370)); // rounded up
    var ready = false;
    final waiting = pacer.waitUntilReady().then((_) => ready = true);
    expect(clock.pendingTimers, 1);
    clock.advance(const Duration(milliseconds: 3));
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse, reason: 'set for 4 ms, not 3');
    clock.advance(const Duration(milliseconds: 1));
    await waiting;
    expect(ready, isTrue);
    expect(pacer.timeUntilSend(), Duration.zero);
  });
}
