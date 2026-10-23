import 'package:dart_udx/src/packet.dart';
import 'package:dart_udx/src/recv_tracker.dart';
import 'package:test/test.dart';

/// The sequences an ACK frame acknowledges.
Set<int> acknowledged(AckFrame f) {
  final out = <int>{};
  for (var i = 0; i < f.firstAckRangeLength; i++) {
    out.add(f.largestAcked - i);
  }
  var cursor = f.largestAcked - f.firstAckRangeLength;
  for (final r in f.ackRanges) {
    final end = cursor - r.gap;
    for (var i = 0; i < r.ackRangeLength; i++) {
      out.add(end - i);
    }
    cursor = end - r.ackRangeLength;
  }
  return out;
}

void main() {
  group('RecvTracker', () {
    test('contiguous arrivals are one range and in order', () {
      final t = RecvTracker();
      expect(t.add(1), isFalse);
      expect(t.add(2), isFalse);
      expect(t.add(3), isFalse);
      final f = t.frame(0);
      expect(f.largestAcked, 3);
      expect(f.firstAckRangeLength, 3);
      expect(f.ackRanges, isEmpty);
    });

    test('a packet that leaves a hole is out of order, and the hole is a gap', () {
      final t = RecvTracker();
      t.add(1);
      t.add(2);
      expect(t.add(4), isTrue, reason: '3 has not arrived');
      expect(t.add(5), isFalse);
      final f = t.frame(0);
      expect(f.largestAcked, 5);
      expect(f.firstAckRangeLength, 2);
      expect(f.ackRanges.length, 1);
      expect(f.ackRanges[0].gap, 1);
      expect(f.ackRanges[0].ackRangeLength, 2);
      expect(acknowledged(f), {1, 2, 4, 5});
    });

    test('a late packet filling a hole is out of order, and the ACK then carries no gap', () {
      final t = RecvTracker();
      t.add(1);
      t.add(3);
      expect(t.add(2), isTrue);
      expect(t.add(2), isFalse, reason: 'a duplicate is not out of order');
      final f = t.frame(0);
      expect(f.firstAckRangeLength, 3);
      expect(f.ackRanges, isEmpty);
    });

    test('several gaps, highest first, with the history kept across frames', () {
      final t = RecvTracker();
      for (final s in [1, 3, 4, 6, 8, 9, 10]) {
        t.add(s);
      }
      final f = t.frame(0);
      expect(f.largestAcked, 10);
      expect(f.firstAckRangeLength, 3);
      expect(f.ackRanges.map((r) => (r.gap, r.ackRangeLength)).toList(), [(1, 1), (1, 2), (1, 1)]);
      expect(acknowledged(f), {1, 3, 4, 6, 8, 9, 10});
      // The next frame says the same again: a lost ACK costs nothing.
      expect(acknowledged(t.frame(0)), {1, 3, 4, 6, 8, 9, 10});
    });

    test('at most five ranges go in a frame; the older ones are left out, not misdescribed', () {
      final t = RecvTracker();
      for (var s = 2; s <= 20; s += 2) {
        t.add(s); // every other packet
      }
      final f = t.frame(0);
      expect(f.ackRanges.length, 5);
      expect(acknowledged(f), {20, 18, 16, 14, 12, 10});
    });

    test('sequences further back than the history are forgotten', () {
      final t = RecvTracker();
      t.add(0);
      t.add(ackHistory + 10);
      expect(t.has(0), isFalse);
      expect(t.add(0), isTrue, reason: 'too old to acknowledge; reported out of order');
      final f = t.frame(0);
      expect(f.largestAcked, ackHistory + 10);
      expect(f.firstAckRangeLength, 1);
      expect(f.ackRanges, isEmpty);
    });

    test('a jump of more than the history clears the reused slots', () {
      final t = RecvTracker();
      for (var s = 0; s < 100; s++) {
        t.add(s);
      }
      t.add(2 * ackHistory + 5);
      for (var s = 0; s < 100; s++) {
        expect(t.has(s), isFalse, reason: 'slot $s is reused for a sequence that has not arrived');
      }
      expect(t.frame(0).firstAckRangeLength, 1);
    });

    test('the delay goes into the frame', () {
      final t = RecvTracker();
      t.add(7);
      expect(t.frame(12).ackDelay, 12);
    });
  });
}
