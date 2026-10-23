import 'clock.dart';
import 'constants.dart';

/// Finds how large a datagram the path carries, in the packetization layer
/// (DPLPMTUD, RFC 8899; RFC 9000 section 14), and watches for the path
/// shrinking underneath a validated size. go-udx's MTUDiscovery.
///
/// Streams send datagrams of [safeDatagramSize], 1200 bytes, which any path
/// carries. The search probes up from there towards [maxDatagramSize] with
/// packets padded to the size under test: one is acknowledged, that size is
/// validated and streams use it; one is lost [mtuProbeTries] times, that
/// size is ruled out. The next size is halfway between the largest
/// validated and the smallest ruled out, and the search ends when the two
/// are within [mtuSearchStep]. A probe is numbered and tracked like data, so
/// the ACK ranges and loss detection report on it, but it is never re-sent,
/// is not booked in flight, and its loss is no congestion signal (section
/// 14.4).
///
/// A black hole is a path that stopped carrying the validated size: a
/// carrier's tunnel on the far side of a handover, where every full-size
/// packet vanishes and only the small ones get through. [blackholePackets]
/// consecutive full-size data packets lost with none acknowledged in
/// between, or [blackholePtos] probe timeouts in a row (nothing at all is
/// being acknowledged), take the size back to [safeDatagramSize] at once;
/// re-sends are re-chunked to fit (PacketManager.fitToPath), and the search
/// starts over after [blackholeRetry].
///
/// This was a controller that nothing drove: the socket asked it whether to
/// probe in a state where the answer was always no, and every stream sent
/// 1200-byte datagrams for the life of the connection.
class MtuDiscovery {
  MtuDiscovery({Clock? clock}) : clock = clock ?? const SystemClock() {
    _restart();
  }

  final Clock clock;

  int _current = safeDatagramSize;
  int _probe = 0;
  int _lowFailed = 0;
  int _tries = 0;
  bool _inFlight = false;
  bool _done = false;

  /// When the search restarts after a black hole; null when there was none.
  Duration? _retryAt;

  /// Consecutive lost data packets larger than the base with none
  /// acknowledged since.
  int _largeLost = 0;

  void _restart() {
    _probe = maxDatagramSize;
    _lowFailed = maxDatagramSize + 1;
    _tries = 0;
    _inFlight = false;
    _done = false;
    _retryAt = null;
    _largeLost = 0;
  }

  /// The validated datagram size: what streams send now.
  int get current => _current;

  /// Whether the search has ended (also after a black hole, until the
  /// retry).
  bool get done => _done;

  /// The size to probe now, marked in flight, or 0 when nothing is to be
  /// sent: the search is over, a probe is already in flight, or the wait
  /// after a black hole has not passed.
  int nextProbe() {
    final retry = _retryAt;
    if (retry != null) {
      if (clock.now() < retry) return 0;
      _restart();
    }
    if (_done || _inFlight) return 0;
    _inFlight = true;
    return _probe;
  }

  /// Validates [size] and moves the search up.
  void onProbeAcked(int size) {
    _inFlight = false;
    if (_retryAt != null) return; // stale: the path has shrunk since
    if (size > _current) _current = size;
    _tries = 0;
    _next();
  }

  /// Counts a loss of [size]; the [mtuProbeTries]-th rules it out and moves
  /// the search down.
  void onProbeLost(int size) {
    _inFlight = false;
    if (_retryAt != null) return;
    _tries++;
    if (_tries < mtuProbeTries) return; // the same size again
    _tries = 0;
    if (size < _lowFailed) _lowFailed = size;
    _next();
  }

  void _next() {
    if (_lowFailed - _current <= mtuSearchStep) {
      _done = true;
      _probe = 0;
      return;
    }
    _probe = (_current + _lowFailed) ~/ 2;
  }

  /// Told of every acknowledged data packet: a full-size one getting
  /// through clears the black-hole count.
  void onDataAcked(int size) {
    if (size > safeDatagramSize) _largeLost = 0;
  }

  /// Told of every lost data packet: [blackholePackets] full-size ones in a
  /// row, with none acknowledged between, mean the path no longer carries
  /// the validated size.
  void onDataLost(int size) {
    if (_current <= safeDatagramSize || size <= safeDatagramSize) return;
    _largeLost++;
    if (_largeLost >= blackholePackets) _blackhole();
  }

  /// Takes the size back to the base at once, as the socket does after
  /// [blackholePtos] probe timeouts in a row; the search restarts after
  /// [blackholeRetry].
  void blackhole() => _blackhole();

  void _blackhole() {
    if (_current <= safeDatagramSize) return;
    _current = safeDatagramSize;
    _probe = 0;
    _done = true;
    _inFlight = false;
    _largeLost = 0;
    _retryAt = clock.now() + blackholeRetry;
  }

  /// Starts over from the base, for a connection that moved to a new path
  /// (RFC 9000 section 9.4).
  void reset() {
    _current = safeDatagramSize;
    _restart();
  }
}
