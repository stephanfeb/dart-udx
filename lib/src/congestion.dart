import 'dart:async';
import 'dart:math';

import 'cid.dart';
import 'clock.dart';
import 'packet.dart';
import 'pacing.dart';
import 'metrics_observer.dart';

/// QUIC-style congestion control for a UDX connection, after RFC 9002, with
/// CUBIC congestion avoidance.
///
/// It is told about every send ([onPacketSent]), about every ACK frame once
/// ([onPacketAcked], with everything the frame newly acknowledged together) and
/// about detected loss ([onPacketLost]). There is no cumulative-ack point and
/// no duplicate-ACK counting: QUIC has neither. A retransmission goes out under
/// a fresh sequence number, so the original number is never acknowledged, and
/// anything that waited for it to be would wait forever. That was how this
/// controller used to work, and after the first loss on a connection it never
/// sampled the RTT or grew the window again.
class CongestionController {
  final PacketManager packetManager;

  /// The clock timing runs on; see [Clock].
  final Clock clock;

  /// Metrics observer for this controller (optional).
  UdxMetricsObserver? metricsObserver;

  /// Connection ID for metrics reporting.
  ConnectionId? connectionId;

  // Constants based on RFC 9002
  static const int maxDatagramSize = 1472;
  static const int maxAckDelay = 25; // milliseconds - per RFC 9002
  static final int initialCwnd =
      max(10 * maxDatagramSize, 14720); // 10 * max_datagram_size or 14720 bytes
  static const int minCwnd = 2 * maxDatagramSize; // 2 * max_datagram_size
  static const int kPersistentCongestionThreshold = 3;

  // CUBIC Constants
  static const double betaCubic = 0.7;
  static const double c = 0.4;

  // CUBIC State Variables
  /// The window size before the last congestion event.
  int _wMax = 0;

  /// The time period for the window to grow back to W_max.
  double _k = 0;

  /// The start of the current congestion avoidance epoch.
  Duration? _epochStart;

  /// The current congestion window size in bytes.
  int get cwnd => _cwnd;
  late int _cwnd;

  /// The slow start threshold.
  int get ssthresh => _ssthresh;
  int _ssthresh = 65535; // A high initial value

  // RTT Estimation based on RFC 9002, Section 5
  /// The smoothed round-trip time.
  Duration get smoothedRtt => _smoothedRtt;
  Duration _smoothedRtt = const Duration(milliseconds: 100); // Initial default

  /// The RTT variation.
  Duration get rttVar => _rttVar;
  Duration _rttVar = const Duration(milliseconds: 50);

  /// The minimum RTT observed so far.
  Duration get minRtt => _minRtt;
  Duration _minRtt = const Duration(seconds: 1); // Initialize high

  /// Whether an RTT sample has been taken yet. Until then the estimates above
  /// are the initial defaults, and the first sample replaces them outright
  /// (RFC 9002 section 5.3).
  bool _hasRttSample = false;

  /// The latest RTT sample.
  Duration _latestRtt = Duration.zero;

  /// The latest RTT sample, exposed for testing.
  Duration get latestRttForTest => _latestRtt;

  /// The number of bytes in flight.
  int get inflight => _inflight;
  int _inflight = 0;

  /// Whether the controller is in a recovery period.
  bool get isInRecoveryForTest => _inRecovery;
  bool _inRecovery = false;

  /// Flag to track if we've emitted the initial CWND value
  bool _initialCwndEmitted = false;

  /// The last packet sent when the current recovery period began. Recovery
  /// ends once a packet sent after it is acknowledged (RFC 9002 section
  /// 7.3.2); retransmissions take fresh sequences, so that packet exists.
  int _recoveryEndPacketNumber = -1;

  /// The Probe Timeout (PTO) duration.
  Duration get pto {
    // PTO = smoothed_rtt + max(4 * rttvar, kGranularity) + max_ack_delay
    // We'll simplify kGranularity and max_ack_delay for now.
    final ptoMillis = _smoothedRtt.inMilliseconds + (4 * _rttVar.inMilliseconds);
    return Duration(milliseconds: ptoMillis.clamp(200, 5000));
  }

  /// Timer for PTO.
  Timer? _ptoTimer;

  /// Maximum number of PTO retries before considering connection issues
  int maxPtoRetries = 10;

  /// Current count of consecutive PTO timeouts
  int _ptoRetryCount = 0;

  /// Callback for when a probe packet should be sent.
  void Function()? onProbe;

  /// The packet pacer.
  final PacingController pacingController;

  CongestionController({
    required this.packetManager,
    int? initialCwnd,
    Clock? clock,
  })  : clock = clock ?? const SystemClock(),
        pacingController = PacingController(clock: clock ?? const SystemClock()),
        _cwnd = initialCwnd ?? CongestionController.initialCwnd;

  /// Called when a packet is sent.
  void onPacketSent(int bytes) {
    _inflight += bytes;
    _armPtoTimer();
  }

  /// Called once per ACK frame with everything it newly acknowledged.
  ///
  /// [bytes] is the sum of the newly acknowledged packets' sizes: they leave
  /// flight and, outside recovery, grow the window (RFC 9002 section 7.3.1,
  /// the window grows by the bytes acked). [largestNewlyAcked] says whether
  /// the frame's largest acknowledged packet is among them; if so [sentTime],
  /// that packet's last send, and [ackDelay], what the receiver reports it
  /// waited, give the RTT sample (section 5.1). [largestAcked] is the frame's
  /// largest acknowledged sequence, which ends recovery once it is past the
  /// packet that was last sent when recovery began (section 7.3.2).
  void onPacketAcked(int bytes, Duration? sentTime, Duration ackDelay, bool largestNewlyAcked, int largestAcked) {
    // Emit initial CWND on first ack so metrics UI shows the starting value
    if (!_initialCwndEmitted && connectionId != null) {
      _initialCwndEmitted = true;
      metricsObserver?.onCongestionWindowUpdate(connectionId!, 0, _cwnd, 'initial');
    }

    _inflight -= bytes;
    if (_inflight < 0) _inflight = 0;

    if (largestNewlyAcked && sentTime != null) {
      _updateRtt(sentTime, ackDelay);
    }

    if (_inRecovery && largestAcked > _recoveryEndPacketNumber) {
      _inRecovery = false;
    }

    if (!_inRecovery && bytes > 0) {
      if (_cwnd < _ssthresh) {
        // Slow start
        final oldCwnd = _cwnd;
        _cwnd += bytes;
        if (connectionId != null) {
          metricsObserver?.onCongestionWindowUpdate(connectionId!, oldCwnd, _cwnd, 'slow_start');
        }
      } else {
        // CUBIC congestion avoidance
        _cubicUpdate(bytes);
      }
    }

    // An ACK is proof the path answers: the PTO starts over.
    _ptoTimer?.cancel();
    _ptoTimer = null;
    _ptoRetryCount = 0;
    if (_inflight > 0) {
      _armPtoTimer();
    }
  }

  /// Updates the RTT estimates from a new sample (RFC 9002 sections 5.1-5.3).
  ///
  /// The first sample replaces the initial defaults. Later samples are
  /// adjusted for the receiver's reported ACK delay (capped at max_ack_delay),
  /// but only when the sample is at least min_rtt + ack_delay: a delay that
  /// would take the sample below the minimum ever seen is not credible, and
  /// min_rtt itself is always taken from the unadjusted sample.
  void _updateRtt(Duration sentTime, Duration ackDelay) {
    final latest = clock.now() - sentTime;
    if (latest < Duration.zero) return; // not a sample

    if (!_hasRttSample) {
      _hasRttSample = true;
      _latestRtt = latest;
      _minRtt = latest;
      _smoothedRtt = latest;
      _rttVar = Duration(microseconds: latest.inMicroseconds ~/ 2);
      pacingController.updateRate(_cwnd, _minRtt);
    } else {
      if (latest < _minRtt) {
        _minRtt = latest;
        pacingController.updateRate(_cwnd, _minRtt);
      }
      final cappedAckDelay = Duration(milliseconds: min(ackDelay.inMilliseconds, maxAckDelay));
      var adjusted = latest;
      if (latest >= _minRtt + cappedAckDelay) {
        adjusted = latest - cappedAckDelay;
      }
      _latestRtt = adjusted;

      final rttVarSample = (_smoothedRtt.inMicroseconds - adjusted.inMicroseconds).abs();
      const alpha = 1 / 8; // 0.125
      const beta = 1 / 4; // 0.25
      _smoothedRtt = Duration(
          microseconds: ((1 - alpha) * _smoothedRtt.inMicroseconds + alpha * adjusted.inMicroseconds).round());
      _rttVar = Duration(microseconds: ((1 - beta) * _rttVar.inMicroseconds + beta * rttVarSample).round());
    }

    if (connectionId != null) {
      metricsObserver?.onRttSample(connectionId!, _latestRtt, _smoothedRtt, _rttVar);
    }
  }

  /// Performs the CUBIC window increase calculation.
  void _cubicUpdate(int bytes) {
    // Initialize epoch start if this is the first time entering congestion avoidance
    _epochStart ??= clock.now();
    final t = (clock.now() - _epochStart!).inMilliseconds / 1000.0; // Time in seconds

    // Calculate target CWND using the CUBIC function
    final wCubic = (c * pow(t - _k, 3) + (_wMax / maxDatagramSize)).toDouble();
    final targetCwndBytes = (wCubic * maxDatagramSize).round();

    // Estimate what the window would be with standard TCP Reno (Congestion Avoidance)
    final wTcp = _cwnd + (maxDatagramSize * bytes) ~/ _cwnd;

    // Check if we are in the TCP-friendly region
    if (targetCwndBytes < wTcp) {
      // If CUBIC is less aggressive than TCP, we use the TCP-friendly growth.
      final oldCwnd = _cwnd;
      _cwnd = wTcp;
      if (connectionId != null && oldCwnd != _cwnd) {
        metricsObserver?.onCongestionWindowUpdate(connectionId!, oldCwnd, _cwnd, 'tcp_growth');
      }
    } else {
      // Otherwise, use the CUBIC growth.
      // The increase is the difference between the target and current, scaled.
      if (_cwnd < targetCwndBytes) {
        final oldCwnd = _cwnd;
        int increase = ((targetCwndBytes - _cwnd) * maxDatagramSize / _cwnd).round();
        _cwnd += increase;
        if (connectionId != null && oldCwnd != _cwnd) {
          metricsObserver?.onCongestionWindowUpdate(connectionId!, oldCwnd, _cwnd, 'cubic_growth');
        }
      } else {
        // If we are already past the target, use standard linear growth to probe.
        final oldCwnd = _cwnd;
        _cwnd += (maxDatagramSize * bytes) ~/ _cwnd;
        if (connectionId != null && oldCwnd != _cwnd) {
          metricsObserver?.onCongestionWindowUpdate(connectionId!, oldCwnd, _cwnd, 'linear_probe');
        }
      }
    }
  }

  /// Sets the smoothed RTT for testing purposes.
  void setSmoothedRtt(Duration rtt) {
    _smoothedRtt = rtt;
  }

  /// Sets the RTT variation for testing purposes.
  void setRttVar(Duration rttVar) {
    _rttVar = rttVar;
  }

  /// Called when a packet is considered lost.
  void onPacketLost(int bytes, List<UDXPacket> lostPackets) {
    _inflight -= bytes;
    if (_inflight < 0) _inflight = 0;

    _checkPersistentCongestion(lostPackets);

    // Don't reduce CWND if we are already in a recovery period.
    if (_inRecovery) {
      return;
    }

    _epochStart = clock.now(); // Start of a new recovery epoch
    _inRecovery = true;
    _recoveryEndPacketNumber = packetManager.lastSentPacketNumber;

    // CUBIC's W_max calculation and window reduction
    _wMax = _cwnd; // Store the window size at the point of congestion.
    _ssthresh = (_wMax * betaCubic).round();
    if (_ssthresh < minCwnd) {
      _ssthresh = minCwnd;
    }

    // Pre-calculate K
    final wMaxInMss = _wMax / maxDatagramSize;
    final diff = wMaxInMss * (1 - betaCubic) / c;
    _k = pow(diff, 1 / 3).toDouble();

    final oldCwnd = _cwnd;
    _cwnd = _ssthresh; // Reduce the window
    pacingController.updateRate(_cwnd, _minRtt);

    if (connectionId != null) {
      metricsObserver?.onCongestionWindowUpdate(connectionId!, oldCwnd, _cwnd, 'loss_detected');
    }
  }

  /// Arms the PTO timer.
  void _armPtoTimer() {
    _ptoTimer?.cancel();
    _ptoTimer = clock.timer(pto, _onPtoTimeout);
  }

  /// Called when the PTO timer expires.
  void _onPtoTimeout() {
    _ptoRetryCount++;

    // Only send probe if we haven't exceeded max retries
    if (_ptoRetryCount <= maxPtoRetries) {
      onProbe?.call();

      // Double the PTO for the next probe if this one doesn't elicit an ACK.
      final nextPto = pto * 2;
      _ptoTimer = clock.timer(nextPto, _onPtoTimeout);
    } else {
      // Exceeded max retries: keep probing, less often.
      _ptoRetryCount = 0;
      final backoffPto = pto * 4; // Use 4x PTO as backoff
      _ptoTimer = clock.timer(backoffPto, _onPtoTimeout);
    }
  }

  /// Destroys the congestion controller and cancels all timers.
  void destroy() {
    _ptoTimer?.cancel();
    _ptoTimer = null;
    pacingController.dispose();
  }

  /// Checks if a persistent congestion has occurred.
  /// See RFC 9002, Section 7.6.2
  void _checkPersistentCongestion(List<UDXPacket> lostPackets) {
    // 1. Must have a valid RTT sample.
    if (_latestRtt == Duration.zero) {
      return;
    }

    // 2. Must have at least two lost packets.
    final ackElicitingLost =
        lostPackets.where((p) => p.frames.any((f) => f.type != FrameType.ack)).toList();
    if (ackElicitingLost.length < 2) {
      return;
    }

    ackElicitingLost.sort((a, b) => a.sequence.compareTo(b.sequence));
    final oldestLost = ackElicitingLost.first;
    final newestLost = ackElicitingLost.last;

    // 3. The duration between the send times of these two packets exceeds the
    //    persistent congestion duration.
    final persistentCongestionDuration = (pto * kPersistentCongestionThreshold);
    final lostPeriod = clock.now() - oldestLost.sentTime!;

    if (lostPeriod < persistentCongestionDuration) {
      return;
    }

    // 4. None of the packets sent between the send times of these two packets
    //    are acknowledged.
    final sentBetween = packetManager.sentPackets
        .where((p) => p.sequence > oldestLost.sequence && p.sequence < newestLost.sequence);

    if (sentBetween.any((p) => p.isAcked)) {
      return;
    }

    // Persistent congestion established. Collapse the window.
    _cwnd = minCwnd;
    pacingController.updateRate(_cwnd, _minRtt);
    _inRecovery = false; // Exit recovery to allow for slow start
    _recoveryEndPacketNumber = -1;
  }

  /// Processes ECN (Explicit Congestion Notification) feedback from ACK frames.
  ///
  /// ECN allows routers to signal congestion before packet loss occurs,
  /// enabling more responsive congestion control. This is a placeholder for
  /// future OS-level ECN integration.
  ///
  /// Per RFC 9000 Section 13.4:
  /// - ECT(0), ECT(1): ECN Capable Transport markings
  /// - CE: Congestion Experienced marking
  ///
  /// An increase in CE count indicates congestion, which should trigger
  /// congestion response similar to packet loss.
  void processEcnFeedback(int ect0, int ect1, int ce) {
    // TODO: Implement ECN-based congestion control once OS integration is available
    // For now, this is a no-op placeholder
    //
    // When implemented, logic should:
    // 1. Track previous CE count
    // 2. If CE count increases, treat as congestion signal
    // 3. Enter recovery and reduce cwnd similar to packet loss
    // 4. Update metrics/logging
  }
}
