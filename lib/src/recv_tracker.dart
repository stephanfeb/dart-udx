import 'packet.dart';

/// How many sequences below the largest received an ACK remembers.
///
/// An ACK can carry at most five ranges, so a receiver this far behind is
/// described to the sender by its RTO rather than by SACK; and a packet that
/// arrives this late is simply not acknowledged, which the sender resolves by
/// re-sending it under a fresh sequence.
const int ackHistory = 512;

/// Records which ack-eliciting packets have arrived, so an ACK can carry
/// ranges, and says whether each arrival is out of order. The port of
/// go-udx's recvTracker: the largest sequence explicitly and a bitmap of the
/// [ackHistory] sequences below it, indexed by sequence modulo the history.
///
/// This replaced a set of the sequences received since the last ACK, cleared
/// each time one was sent. Every ACK from this side then described one packet
/// and no history, so a lost ACK lost that packet's acknowledgement for good,
/// and the peer never saw a gap: go-udx declares loss only from the gaps in
/// an ACK (DetectLostPackets), so a go-udx sender got no loss signal at all
/// from a dart-udx receiver, never contracted its window, and recovered only
/// by RTO timers. QUIC repeats ranges until the peer has seen them (RFC 9000
/// section 13.2.4).
class RecvTracker {
  int _largest = 0;
  bool _any = false;
  final List<int> _bits = List<int>.filled(ackHistory ~/ 32, 0);

  /// Whether anything has been recorded.
  bool get any => _any;

  /// The largest sequence recorded.
  int get largest => _largest;

  bool has(int seq) {
    if (!_any || seq > _largest || _largest - seq >= ackHistory) return false;
    final i = seq % ackHistory;
    return (_bits[i ~/ 32] >> (i % 32)) & 1 != 0;
  }

  void _set(int seq) {
    final i = seq % ackHistory;
    _bits[i ~/ 32] |= 1 << (i % 32);
  }

  void _clear(int seq) {
    final i = seq % ackHistory;
    _bits[i ~/ 32] &= ~(1 << (i % 32));
  }

  /// Records [seq] and reports whether it arrived out of order: below the
  /// largest seen (a late packet or a resend filling a gap) or leaving a hole
  /// behind it (something in between has not arrived). Either is the signal
  /// to acknowledge at once, so the sender learns of the gap without waiting
  /// for the ACK timer. A duplicate is not out of order.
  bool add(int seq) {
    if (!_any) {
      _any = true;
      _largest = seq;
      _set(seq);
      return false;
    }
    if (seq > _largest) {
      final gap = seq - _largest - 1;
      // The slots between the old largest and seq are being reused for
      // sequences that have not arrived, so they must read as missing.
      if (seq - _largest >= ackHistory) {
        _bits.fillRange(0, _bits.length, 0);
      } else {
        for (var s = _largest + 1; s < seq; s++) {
          _clear(s);
        }
      }
      _largest = seq;
      _set(seq);
      return gap > 0;
    }
    if (seq == _largest) return false;
    if (_largest - seq >= ackHistory) return true;
    if (has(seq)) return false;
    _set(seq);
    return true;
  }

  /// Builds the ACK: the largest sequence with the run of received sequences
  /// directly below it, then up to [maxRanges] (gap, run) pairs walking down,
  /// the shape both peers parse. A gap wider than the frame can carry ends
  /// the walk: the older ranges are left out rather than mis-described.
  AckFrame frame(int ackDelay, {int maxRanges = 5}) {
    if (!_any) {
      return AckFrame(largestAcked: 0, ackDelay: ackDelay, firstAckRangeLength: 1);
    }
    var cursor = _largest;
    var steps = 0;

    int run() {
      var n = 0;
      while (steps < ackHistory && has(cursor)) {
        n++;
        steps++;
        if (cursor == 0) {
          steps = ackHistory;
          break;
        }
        cursor--;
      }
      return n;
    }

    int gap() {
      var n = 0;
      while (steps < ackHistory && n < AckFrame.maxGap && !has(cursor)) {
        n++;
        steps++;
        if (cursor == 0) {
          steps = ackHistory;
          break;
        }
        cursor--;
      }
      return n;
    }

    final first = run();
    final ranges = <AckRange>[];
    while (ranges.length < maxRanges && steps < ackHistory) {
      final g = gap();
      if (g == 0 || g >= AckFrame.maxGap) break;
      final n = run();
      if (n == 0) break;
      ranges.add(AckRange(gap: g, ackRangeLength: n));
    }
    return AckFrame(
      largestAcked: _largest,
      ackDelay: ackDelay,
      firstAckRangeLength: first,
      ackRanges: ranges,
    );
  }
}
