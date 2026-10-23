/// A re-send takes a FRESH sequence number (PacketManager.resend) and the
/// packet stays tracked for as long as the connection lives: there is no
/// per-packet retry cap, and no per-packet timer either. What ends a dead
/// path is the socket's idle timeout closing the whole connection.
library;

import 'dart:typed_data';

import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/clock.dart';
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

(PacketManager, FakeClock) _manager() {
  final clock = FakeClock();
  final pm = PacketManager(clock: clock);
  pm.congestionController = CongestionController(packetManager: pm, clock: clock);
  return (pm, clock);
}

void main() {
  group('Fresh-sequence re-send', () {
    test('resend re-keys the packet under a fresh sequence', () {
      final (pm, _) = _manager();
      final seq = pm.nextSequence;
      final packet = _dataPacket(seq);
      pm.sendPacket(packet);

      final newSeq = pm.resend(packet);

      expect(newSeq, isNotNull);
      expect(newSeq, isNot(equals(seq)), reason: 'a re-send must never reuse the original sequence');
      expect(packet.sequence, equals(newSeq));
      final tracked = pm.getSentPacketsTestHook();
      expect(tracked.containsKey(seq), isFalse, reason: 'the original sequence must be retired');
      expect(tracked[newSeq], same(packet), reason: 'the packet is tracked under its fresh sequence');
      expect(packet.retransmitCount, equals(1));
      pm.destroy();
    });

    test('resend keeps the first send time and moves the last', () {
      // sentTime is the first send; lastSentTime the send the RTT sample and
      // loss detection measure from (a fresh sequence makes its ACK
      // unambiguous).
      final (pm, clock) = _manager();
      final packet = _dataPacket(pm.nextSequence);
      pm.sendPacket(packet);
      final original = packet.sentTime;

      clock.advance(const Duration(milliseconds: 250));
      pm.resend(packet);

      expect(packet.sentTime, equals(original));
      expect(packet.lastSentTime, equals(clock.now()));
      expect(packet.lastRetransmit, equals(clock.now()));
      pm.destroy();
    });

    test('resend of a packet loss detection removed tracks it again', () {
      final (pm, _) = _manager();
      final lostPacket = _dataPacket(pm.nextSequence);
      pm.sendPacket(lostPacket);
      for (var i = 0; i < 3; i++) {
        pm.sendPacket(_dataPacket(pm.nextSequence));
      }
      pm.handleAckFrame(AckFrame(largestAcked: 3, ackDelay: 0, firstAckRangeLength: 1));
      expect(pm.detectLostPackets(), [same(lostPacket)]);
      expect(pm.getSentPacketsTestHook().containsKey(0), isFalse, reason: 'lost: no longer tracked');

      final newSeq = pm.resend(lostPacket);
      expect(newSeq, equals(4));
      expect(pm.getSentPacketsTestHook()[4], same(lostPacket));
      pm.destroy();
    });

    test('resend of an acknowledged packet is a no-op', () {
      final (pm, _) = _manager();
      final seq = pm.nextSequence;
      final packet = _dataPacket(seq);
      pm.sendPacket(packet);

      pm.handleAckFrame(AckFrame(largestAcked: seq, ackDelay: 0, firstAckRangeLength: 1));

      expect(pm.resend(packet), isNull);
      expect(pm.getSentPacketsTestHook(), isEmpty, reason: 'an acknowledged packet is not tracked again');
      pm.destroy();
    });

    test('there is no give-up cap: the packet stays tracked across many re-sends', () {
      final (pm, _) = _manager();
      final packet = _dataPacket(pm.nextSequence);
      pm.sendPacket(packet);

      for (var i = 0; i < 25; i++) {
        final newSeq = pm.resend(packet);
        expect(newSeq, isNotNull, reason: 'attempt $i must still re-send');
        expect(pm.getSentPacketsTestHook()[packet.sequence], same(packet), reason: 'the packet is never abandoned');
      }
      expect(packet.retransmitCount, equals(25));
      pm.destroy();
    });
  });
}
