import 'dart:async';
import 'dart:math';

import 'cid.dart';
import 'clock.dart';
import 'constants.dart';
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

  /// The slow start threshold. Slow start runs until the first loss (RFC
  /// 9002 section 7.3.1). This was 65535, so slow start ended at 64 KB, 44
  /// packets, and the window crawled up from there at CUBIC's pace.
  int get ssthresh => _ssthresh;
  int _ssthresh = noSsthresh;
  static const int noSsthresh = 1 << 62;

  // RTT Estimation based on RFC 9002, Section 5
  /// The smoothed round-trip time; [initialRtt] before the first sample.
  Duration get smoothedRtt => _smoothedRtt;
  Duration _smoothedRtt = initialRtt;

  /// The RTT variation; [initialRttVar] before the first sample.
  Duration get rttVar => _rttVar;
  Duration _rttVar = initialRttVar;

  /// The minimum RTT observed so far; null before the first sample.
  Duration? get minRtt => _minRtt;
  Duration? _minRtt;

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

  /// The base probe timeout (RFC 9002 section 6.2.1): smoothed_rtt +
  /// max(4 * rttvar, kGranularity) + max_ack_delay. The peer delays its ACKs
  /// by up to max_ack_delay, so a PTO without that term fires on a delayed
  /// ACK alone. There is no floor beyond the granularity and no cap: on a
  /// 30 ms path a loss costs about 60 ms, not the 200 ms floor that used to
  /// stand in for the missing max_ack_delay term, and a slow path's PTO is
  /// bounded by the backoff and the idle timeout, not by a constant. Before
  /// the first sample it is about a second ([initialRtt]).
  Duration get pto {
    var v = _rttVar * 4;
    if (v < PacketManager.lossTimerGranularity) v = PacketManager.lossTimerGranularity;
    return _smoothedRtt + v + const Duration(milliseconds: maxAckDelay);
  }

  /// One PTO timer per connection (RFC 9002 section 6.2), armed from the
  /// last ack-eliciting send and backing off by [ptoCount] until an ACK
  /// arrives. There is no retry cap: a path that never answers is ended by
  /// the connection's idle timeout, not by the probing stopping.
  Timer? _ptoTimer;
  int get ptoCount => _ptoCount;
  int _ptoCount = 0;
  Duration? _lastSendTime;

  /// The wait for the next probe: the base PTO backed off by the number of
  /// PTOs that have fired without an ACK.
  Duration get nextPto {
    final shift = _ptoCount > 20 ? 20 : _ptoCount;
    return pto * (1 << shift);
  }

  /// Called when the PTO fires: the socket sends a probe or two (the oldest
  /// outstanding data under fresh sequences), without touching the window.
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
    _lastSendTime = clock.now();
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

    // An ACK is proof the path answers: the PTO backoff starts over
    // (RFC 9002 section 6.2.1), measured from the last send.
    _ptoTimer?.cancel();
    _ptoTimer = null;
    _ptoCount = 0;
    if (_inflight > 0) {
      _armPtoTimer();
    }
    _updatePacingRate();
  }

  /// Tells the pacer the window and RTT it paces by, once an RTT sample
  /// exists; before one the pacer is unlimited and the initial window is the
  /// burst. Called after every change to either.
  void _updatePacingRate() {
    if (!_hasRttSample) return;
    pacingController.updateRate(_cwnd, _smoothedRtt, slowStart: _cwnd < _ssthresh);
  }

  /// Whether any RTT sample has been taken; persistent congestion is only
  /// declared once one has (RFC 9002 section 7.6.2).
  bool get hasRttSample => _hasRttSample;

  /// How long a span of loss must cover before it counts as persistent
  /// congestion (RFC 9002 section 7.6.1): three PTOs, the PTO already
  /// including the max_ack_delay term.
  Duration get persistentCongestionDuration => pto * kPersistentCongestionThreshold;

  /// The RFC 9002 section 7.6 reaction: the window collapses to the minimum
  /// and recovery ends, so sending restarts in slow start, as after an
  /// outage long enough that everything sent in three PTOs was lost. Called
  /// after [onPacketLost] for the same loss event.
  void onPersistentCongestion() {
    final oldCwnd = _cwnd;
    _cwnd = minCwnd;
    _inRecovery = false;
    _recoveryEndPacketNumber = -1;
    _epochStart = null;
    _updatePacingRate();
    if (connectionId != null) {
      metricsObserver?.onCongestionWindowUpdate(connectionId!, oldCwnd, _cwnd, 'persistent_congestion');
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
    } else {
      if (latest < _minRtt!) {
        _minRtt = latest;
      }
      final cappedAckDelay = Duration(milliseconds: min(ackDelay.inMilliseconds, maxAckDelay));
      var adjusted = latest;
      if (latest >= _minRtt! + cappedAckDelay) {
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

  /// Called when packets are declared lost: their bytes leave flight
  /// (RFC 9002 section 7.3) and the window contracts, once per recovery
  /// epoch. When the data is re-sent it is booked again by [onPacketSent], as
  /// the new packet it is. Persistent congestion is the socket's call
  /// (PacketManager.persistentCongestion, then [onPersistentCongestion]).
  void onPacketLost(int bytes, List<UDXPacket> lostPackets) {
    _inflight -= bytes;
    if (_inflight < 0) _inflight = 0;

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
    _updatePacingRate();

    if (connectionId != null) {
      metricsObserver?.onCongestionWindowUpdate(connectionId!, oldCwnd, _cwnd, 'loss_detected');
    }
  }

  /// Sets the PTO timer to fire [nextPto] after the last ack-eliciting send
  /// (RFC 9002 section 6.2.1).
  void _armPtoTimer() {
    _ptoTimer?.cancel();
    var wait = nextPto;
    final last = _lastSendTime;
    if (last != null) {
      final remaining = last + wait - clock.now();
      if (remaining < wait) wait = remaining;
    }
    if (wait < PacketManager.lossTimerGranularity) wait = PacketManager.lossTimerGranularity;
    _ptoTimer = clock.timer(wait, _onPtoTimeout);
  }

  /// Fires when nothing has been acknowledged for a PTO: the socket sends a
  /// probe ([onProbe]), and the next PTO waits twice as long. The window is
  /// untouched; loss is declared only once an ACK proves it.
  void _onPtoTimeout() {
    _ptoCount++;
    _ptoTimer = null;
    onProbe?.call();
    if (_inflight > 0 && _ptoTimer == null) {
      // Measured from now: the probe just sent is the last send.
      _lastSendTime = clock.now();
      _ptoTimer = clock.timer(nextPto, _onPtoTimeout);
    }
  }

  /// Destroys the congestion controller and cancels all timers.
  void destroy() {
    _ptoTimer?.cancel();
    _ptoTimer = null;
    pacingController.dispose();
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
