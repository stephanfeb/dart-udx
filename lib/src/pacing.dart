import 'dart:async';
import 'dart:math';
import 'package:meta/meta.dart';

/// A controller to manage packet pacing.
///
/// Packet pacing smooths out the sending of packets to prevent bursts,
/// which can cause network congestion and packet loss. It works by calculating
/// a pacing rate based on the congestion window (cwnd) and the minimum
/// round-trip time (minRtt).
class PacingController {
  PacingController({
    this.pacingGain = 2.88, // Standard pacing gain from QUIC
  }) {
    _pacingRateBytesPerSec = double.infinity;
    _nextSendTime = DateTime.now();
  }

  /// The gain factor used to calculate the pacing rate.
  final double pacingGain;

  /// The target sending rate in bytes per second.
  late double _pacingRateBytesPerSec;

  /// The earliest time the next packet can be sent.
  late DateTime _nextSendTime;

  /// A timer to handle delayed sends.
  Timer? _timer;

  /// Updates the pacing rate based on the current network conditions.
  ///
  /// This should be called whenever the congestion window or minRtt changes.
  void updateRate(int cwnd, Duration minRtt) {
    if (minRtt == Duration.zero) {
      _pacingRateBytesPerSec = double.infinity;
      return;
    }
    final minRttInSeconds = minRtt.inMicroseconds / Duration.microsecondsPerSecond;
    _pacingRateBytesPerSec = (pacingGain * cwnd) / minRttInSeconds;
  }

  /// Waits until it is time to send the next packet.
  ///
  /// Returns a `Future` that completes when the pacer determines it's
  /// acceptable to send the next packet.
  Future<void> waitUntilReady() async {
    final now = DateTime.now();
    if (now.isBefore(_nextSendTime)) {
      final delay = _nextSendTime.difference(now);
      final completer = Completer<void>();
      _timer = Timer(delay, () {
        if (!completer.isCompleted) {
          completer.complete();
        }
      });
      return completer.future;
    }
  }

  /// Informs the pacer that a packet has been sent.
  ///
  /// This should be called immediately after a packet is sent to update the
  /// next send time.
  void onPacketSent(int packetSize) {
    if (_pacingRateBytesPerSec.isFinite) {
      final interval =
          Duration(microseconds: (packetSize / _pacingRateBytesPerSec * Duration.microsecondsPerSecond).round());
      final now = DateTime.now();
      _nextSendTime = (now.isAfter(_nextSendTime) ? now : _nextSendTime).add(interval);
    }
  }

  /// Cancels any pending timer.
  void dispose() {
    _timer?.cancel();
  }

  @visibleForTesting
  double get pacingRateBytesPerSec => _pacingRateBytesPerSec;

  @visibleForTesting
  DateTime get nextSendTime => _nextSendTime;
}
