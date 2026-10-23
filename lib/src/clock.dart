import 'dart:async';

/// The clock the transport's timing runs on: a monotonic instant for RTT
/// samples, send times, ACK delay, pacing and the idle check, and the timers
/// the PTO, the loss timer, the ACK timer and the watchdog are armed on.
///
/// `DateTime.now()` is the wall clock, which a phone steps on carrier time
/// sync, when it leaves doze, and across time zones for some vendors. Used for
/// timing, as it was, a forward step of more than the idle timeout closed
/// every connection on the next watchdog tick, a step of a few seconds
/// inflated one RTT sample into a five-second PTO, and a backward step gave
/// negative samples. A [Stopwatch] never steps. go-udx reads a monotonic
/// clock the same way (its Clock in clock.go).
///
/// Instants are [Duration]s since the clock's origin; only differences
/// between them mean anything. [FakeClock] lets a test drive time by hand.
abstract class Clock {
  /// The current instant.
  Duration now();

  /// A timer that fires [callback] once [duration] has passed on this clock.
  Timer timer(Duration duration, void Function() callback);
}

/// The real monotonic clock. Every instance reads one process-wide
/// stopwatch, so instants from any of them compare.
class SystemClock implements Clock {
  const SystemClock();

  static final Stopwatch _stopwatch = Stopwatch()..start();

  @override
  Duration now() => _stopwatch.elapsed;

  @override
  Timer timer(Duration duration, void Function() callback) => Timer(duration, callback);
}

/// A clock a test moves by hand: [advance] passes time and fires the timers
/// that fall due, in due order, each seeing the clock at its own due time.
class FakeClock implements Clock {
  FakeClock([Duration start = Duration.zero]) : _now = start;

  Duration _now;
  final List<_FakeTimer> _timers = [];
  int _sequence = 0;

  @override
  Duration now() => _now;

  @override
  Timer timer(Duration duration, void Function() callback) {
    final t = _FakeTimer(this, _now + (duration < Duration.zero ? Duration.zero : duration), callback, _sequence++);
    _timers.add(t);
    return t;
  }

  /// How many timers are armed.
  int get pendingTimers => _timers.length;

  /// Moves the clock forward by [by], firing due timers as it goes.
  void advance(Duration by) {
    final target = _now + by;
    while (true) {
      _FakeTimer? next;
      for (final t in _timers) {
        if (t.due > target) continue;
        if (next == null || t.due < next.due || (t.due == next.due && t.order < next.order)) next = t;
      }
      if (next == null) break;
      _timers.remove(next);
      _now = next.due;
      next.fire();
    }
    _now = target;
  }

  void _cancel(_FakeTimer t) => _timers.remove(t);
}

class _FakeTimer implements Timer {
  _FakeTimer(this._clock, this.due, this._callback, this.order);

  final FakeClock _clock;
  final Duration due;
  final void Function() _callback;
  final int order;
  bool _active = true;

  void fire() {
    _active = false;
    _callback();
  }

  @override
  void cancel() {
    _active = false;
    _clock._cancel(this);
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;
}
