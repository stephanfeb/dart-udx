import 'dart:typed_data';

import 'package:dart_udx/src/packet.dart';
import 'package:test/test.dart';

/// The sequences an ACK frame acknowledges (go-udx's raw-count encoding).
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

AckFrame roundTrip(AckFrame f) =>
    Frame.fromBytes(ByteData.sublistView(f.toBytes()), 0) as AckFrame;

void main() {
  group('AckFrame.fromReceived', () {
    test('encodes ordinary sets exactly as before', () {
      final f = AckFrame.fromReceived([1, 2, 3, 5, 6, 9]);
      expect(f.largestAcked, 9);
      expect(f.firstAckRangeLength, 1);
      expect([for (final r in f.ackRanges) [r.gap, r.ackRangeLength]], [
        [2, 2],
        [1, 3],
      ]);
      expect(acknowledged(roundTrip(f)), {1, 2, 3, 5, 6, 9});
    });

    test('a single sequence', () {
      final f = AckFrame.fromReceived([42]);
      expect([f.largestAcked, f.firstAckRangeLength, f.ackRanges.length], [42, 1, 0]);
    });

    test('stops at a gap wider than 255 instead of truncating it', () {
      final received = {for (var s = 0; s < 10; s++) s, for (var s = 300; s < 310; s++) s};
      final f = AckFrame.fromReceived(received);
      expect(f.ackRanges, isEmpty); // 0..9 left out: the gap below 300 is 290
      final acked = acknowledged(roundTrip(f));
      expect(acked, {for (var s = 300; s < 310; s++) s});
      expect(received.containsAll(acked), isTrue);
    });

    test('keeps ranges below a gap of exactly 255', () {
      final f = AckFrame.fromReceived([0, 256]);
      expect(acknowledged(roundTrip(f)), {0, 256});
    });

    test('caps the range count at 255 and never acknowledges what did not arrive', () {
      final received = [for (var s = 0; s < 1000; s += 2) s];
      final f = AckFrame.fromReceived(received);
      expect(f.ackRanges.length, 255);
      final acked = acknowledged(roundTrip(f));
      expect(received.toSet().containsAll(acked), isTrue);
      expect(acked.contains(998), isTrue);
    });

    test('toBytes refuses a gap that does not fit one byte', () {
      final f = AckFrame(
        largestAcked: 1000,
        ackDelay: 0,
        firstAckRangeLength: 1,
        ackRanges: [AckRange(gap: 290, ackRangeLength: 1)],
      );
      expect(f.toBytes, throwsArgumentError);
    });
  });
}
