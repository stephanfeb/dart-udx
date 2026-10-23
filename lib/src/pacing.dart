import 'dart:async';

import 'package:meta/meta.dart';

import 'clock.dart';
import 'constants.dart';

/// Spreads a connection's sends over the round trip instead of letting a
/// window's worth go out at once (RFC 9002 section 7.7).
///
/// The rate is gain * cwnd / smoothed_rtt, the gain [pacingGainSlowStart] in
/// slow start and [pacingGain] after it, as most QUIC stacks pace. The
/// congestion controller recomputes it on every change to the window or the
/// RTT estimate ([updateRate]). It used to be computed from min_rtt, and only
/// when min_rtt fell or the window contracted.
///
/// Sends draw on a budget that refills at the rate and holds at most a burst:
/// [burstPackets] datagrams, or what [minPacingDelay] of the rate is worth,
/// whichever is more. A sender need not sleep between every two packets, and
/// a timer that can only wait whole milliseconds still reaches the rate. The
/// budget may go negative: a batch that overshoots it is paid for by the wait
/// after it. Until the controller has an RTT sample the rate is unlimited and
/// the initial window is the burst.
class PacingController {
  PacingController({Clock? clock}) : clock = clock ?? const SystemClock();

  /// The gain over cwnd / srtt in congestion avoidance (RFC 9002 section 7.7
  /// suggests about 1.25).
  static const double pacingGain = 1.25;

  /// The gain in slow start, where the window doubles each round trip, so
  /// that pacing does not hold the window's growth back.
  static const double pacingGainSlowStart = 2.0;

  /// How many datagrams may go out at once without waiting on the pacer.
  static const int burstPackets = 10;

  /// The shortest wait the pacer asks for. Dart sets timers in whole
  /// milliseconds and the event loop adds jitter, so the burst covers at
  /// least this much of the rate and a wait that overshoots by that little
  /// costs no throughput.
  static const Duration minPacingDelay = Duration(milliseconds: 2);

  /// The clock send times are measured on; see [Clock].
  final Clock clock;

  /// Bytes per second; infinite is unpaced.
  double _rate = double.infinity;

  /// What the budget held after the last send.
  double _budgetAtLastSend = 0;
  Duration? _lastSendTime;

  Timer? _timer;

  /// Sets the rate from the congestion window and the smoothed RTT: gain *
  /// cwnd / srtt, the gain depending on whether the window is in slow start.
  /// A zero srtt (loopback, or a test clock that does not move) means
  /// unpaced.
  void updateRate(int cwnd, Duration srtt, {required bool slowStart}) {
    if (srtt <= Duration.zero) {
      _rate = double.infinity;
      return;
    }
    final gain = slowStart ? pacingGainSlowStart : pacingGain;
    _rate = gain * cwnd / (srtt.inMicroseconds / Duration.microsecondsPerSecond);
  }

  /// The most the budget holds.
  double get _maxBurst {
    var burst = (burstPackets * maxDatagramSize).toDouble();
    if (_rate.isFinite) {
      final byDelay = _rate * minPacingDelay.inMicroseconds / Duration.microsecondsPerSecond;
      if (byDelay > burst) burst = byDelay;
    }
    return burst;
  }

  /// What may be sent at [now] without waiting; the rate is finite.
  double _budget(Duration now) {
    final last = _lastSendTime;
    if (last == null) return _maxBurst;
    final b = _budgetAtLastSend + _rate * (now - last).inMicroseconds / Duration.microsecondsPerSecond;
    final max = _maxBurst;
    return b > max ? max : b;
  }

  /// How long until the next packet may be sent: zero when the budget holds
  /// a full datagram, otherwise the time it takes to, and at least
  /// [minPacingDelay].
  Duration timeUntilSend() {
    if (!_rate.isFinite) return Duration.zero;
    final short = maxDatagramSize - _budget(clock.now());
    if (short <= 0) return Duration.zero;
    var wait = Duration(microseconds: (short / _rate * Duration.microsecondsPerSecond).ceil());
    if (wait < minPacingDelay) wait = minPacingDelay;
    return wait;
  }

  /// Completes when the next packet may be sent.
  Future<void> waitUntilReady() {
    final wait = timeUntilSend();
    if (wait == Duration.zero) return Future.value();
    // Dart sets timers in whole milliseconds: round up, or a timer set for
    // less than a millisecond fires at once.
    final completer = Completer<void>();
    _timer = clock.timer(Duration(milliseconds: (wait.inMicroseconds + 999) ~/ 1000), completer.complete);
    return completer.future;
  }

  /// Draws a sent packet from the budget.
  void onPacketSent(int packetSize) {
    if (!_rate.isFinite) return;
    final now = clock.now();
    _budgetAtLastSend = _budget(now) - packetSize;
    _lastSendTime = now;
  }

  /// Cancels any pending timer.
  void dispose() {
    _timer?.cancel();
  }

  /// The pacing rate in bytes per second; infinite when unpaced.
  double get pacingRateBytesPerSec => _rate;

  /// How many bytes may be sent now without waiting (negative after an
  /// overshoot), or infinite when unpaced.
  @visibleForTesting
  double get budget => _rate.isFinite ? _budget(clock.now()) : _rate;
}
