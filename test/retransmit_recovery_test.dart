/// Tests for loss recovery after retransmission stopped abandoning data.
///
/// A packet is now re-sent under a FRESH sequence number for as long as it is
/// tracked (PacketManager.retransmit), never the original, and there is no
/// per-packet retry cap — what ends a genuinely dead path is the socket's idle
/// timeout closing the whole connection, not one packet's bytes being dropped
/// (the old `maxRetries` give-up, which stranded the stream with a hole).
library;

import 'dart:typed_data';

import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/congestion.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:test/test.dart';

UDXPacket _dataPacket(int sequence) => UDXPacket(
      destinationCid: ConnectionId.random(),
      sourceCid: ConnectionId.random(),
      destinationStreamId: 1,
      sourceStreamId: 2,
      sequence: sequence,
      frames: [StreamFrame(data: Uint8List(100))],
    );

PacketManager _manager() {
  final pm = PacketManager();
  pm.congestionController = CongestionController(packetManager: pm);
  return pm;
}

void main() {
  group('Fresh-sequence retransmission', () {
    test('retransmit re-keys the packet under a fresh sequence', () {
      final pm = _manager();
      final seq = pm.nextSequence;
      final packet = _dataPacket(seq);
      pm.sendPacket(packet);

      final newSeq = pm.retransmit(packet);

      expect(newSeq, isNotNull);
      expect(newSeq, isNot(equals(seq)),
          reason: 'a retransmission must never reuse the original sequence');
      expect(packet.sequence, equals(newSeq));

      final tracked = pm.getSentPacketsTestHook();
      expect(tracked.containsKey(seq), isFalse,
          reason: 'the original sequence must be retired');
      expect(tracked[newSeq], same(packet),
          reason: 'the packet is tracked under its fresh sequence');
      expect(packet.retransmitCount, equals(1));

      pm.destroy();
    });

    test('retransmit preserves the original sentTime', () {
      // sentTime is the original send time; persistent-congestion detection
      // measures undelivered duration from it, so a resend must not restart it.
      final pm = _manager();
      final packet = _dataPacket(pm.nextSequence);
      pm.sendPacket(packet);
      final original = packet.sentTime;

      pm.retransmit(packet);

      expect(packet.sentTime, equals(original));
      expect(packet.lastRetransmit, isNotNull,
          reason: 'per-retransmission timing lives in lastRetransmit instead');
      pm.destroy();
    });

    test('a second retransmit within the RTO is collapsed', () {
      final pm = _manager();
      final packet = _dataPacket(pm.nextSequence);
      pm.sendPacket(packet);

      expect(pm.retransmit(packet), isNotNull, reason: 'the first proceeds');
      expect(pm.retransmit(packet), isNull,
          reason: 'a second attempt inside the RTO is collapsed into the first');
      pm.destroy();
    });

    test('retransmit of an acknowledged packet is a no-op with no timer leak', () {
      final pm = _manager();
      final seq = pm.nextSequence;
      final packet = _dataPacket(seq);
      pm.sendPacket(packet);

      pm.handleAckFrame(AckFrame(largestAcked: seq, ackDelay: 0, firstAckRangeLength: 1));

      expect(pm.retransmit(packet), isNull);
      expect(pm.getRetransmitTimersTestHook(), isEmpty,
          reason: 'no retransmit timer should linger for an acked packet');
      pm.destroy();
    });

    test('there is no give-up cap — the packet stays tracked across many resends', () {
      final pm = _manager();
      final packet = _dataPacket(pm.nextSequence);
      pm.sendPacket(packet);

      // Far past the old maxRetries=10 give-up point. Bypass the per-RTO
      // throttle by backdating each attempt.
      for (var i = 0; i < 25; i++) {
        packet.lastRetransmit = DateTime.now().subtract(const Duration(seconds: 10));
        final newSeq = pm.retransmit(packet);
        expect(newSeq, isNotNull, reason: 'attempt $i must still retransmit');
        expect(pm.getSentPacketsTestHook()[packet.sequence], same(packet),
            reason: 'the packet is never abandoned');
      }
      expect(packet.retransmitCount, equals(25));
      pm.destroy();
    });
  });
}
