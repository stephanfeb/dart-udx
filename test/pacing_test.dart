import 'package:test/test.dart';
import 'package:dart_udx/src/pacing.dart';

void main() {
  group('PacingController', () {
    test('updateRate calculates pacing rate correctly', () {
      final controller = PacingController();
      final cwnd = 14720; // 10 * MSS
      final minRtt = Duration(milliseconds: 100);

      controller.updateRate(cwnd, minRtt);

      // Expected rate: (2.88 * 14720) / 0.1s = 423936 bytes/sec
      expect(controller, predicate((c) {
        final c_ = c as PacingController;
        final rate = c_.getPacingRateForTest();
        return (rate - 423936.0).abs() < 1.0;
      }));
    });

    test('waitUntilReady completes immediately if not paced', () async {
      final controller = PacingController();
      controller.updateRate(14720, Duration(milliseconds: 100));

      final stopwatch = Stopwatch()..start();
      await controller.waitUntilReady();
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(Duration(milliseconds: 5)));
    });

    test('waitUntilReady waits for the correct duration', () async {
      final controller = PacingController();
      controller.updateRate(1472, Duration(milliseconds: 100)); // Lower rate

      // Send one packet
      controller.onPacketSent(1472);

      final stopwatch = Stopwatch()..start();
      await controller.waitUntilReady();
      stopwatch.stop();

      // Expected interval: 1472 / (2.88 * 1472 / 0.1) = 0.1 / 2.88 = ~34.7ms
      expect(stopwatch.elapsed, greaterThanOrEqualTo(Duration(milliseconds: 30)));
      expect(stopwatch.elapsed, lessThan(Duration(milliseconds: 45)));
    });

    test('onPacketSent updates nextSendTime correctly', () {
      final controller = PacingController();
      controller.updateRate(14720, Duration(milliseconds: 100));

      final initialSendTime = controller.getNextSendTimeForTest();
      controller.onPacketSent(1472);
      final nextSendTime = controller.getNextSendTimeForTest();

      // Expected interval: 1472 / 423936 = ~3.47ms
      final expectedInterval = Duration(microseconds: 3472);
      final actualInterval = nextSendTime.difference(initialSendTime);

      expect(actualInterval.inMicroseconds, closeTo(expectedInterval.inMicroseconds, 50));
    });
  });
}

extension PacingControllerTest on PacingController {
  double getPacingRateForTest() => pacingRateBytesPerSec;
  DateTime getNextSendTimeForTest() => nextSendTime;
}
