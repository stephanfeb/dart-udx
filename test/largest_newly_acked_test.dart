/// The congestion controller works from what each ACK frame newly
/// acknowledges, as QUIC does (RFC 9002 sections 5.1 and 7.3): no cumulative
/// ack point, no duplicate-ACK count. Retransmissions carry fresh sequences,
/// so a cumulative point stuck at the first retransmitted packet forever.
library;

import 'dart:typed_data';

import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/clock.dart';
import 'package:dart_udx/src/congestion.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:test/test.dart';

UDXPacket _dataPacket(int sequence, {int bytes = 1000}) => UDXPacket(
      destinationCid: ConnectionId.random(),
      sourceCid: ConnectionId.random(),
      destinationStreamId: 1,
      sourceStreamId: 2,
      sequence: sequence,
      frames: [StreamFrame(data: Uint8List(bytes))],
    );

void main() {
  late PacketManager pm;
  late CongestionController cc;

  setUp(() {
    pm = PacketManager();
    cc = CongestionController(packetManager: pm, initialCwnd: 20000);
    pm.congestionController = cc;
  });

  tearDown(() {
    cc.destroy();
    pm.destroy();
  });

  test('PacketManager.handleAckFrame returns the packets, under their current sequences', () {
    final p0 = _dataPacket(pm.nextSequence);
    final p1 = _dataPacket(pm.nextSequence);
    pm.sendPacket(p0);
    pm.sendPacket(p1);
    final resent = pm.resend(p0)!; // p0 now lives under a fresh sequence
    expect(resent, isNot(0));

    final acked = pm.handleAckFrame(AckFrame(largestAcked: resent, ackDelay: 0, firstAckRangeLength: 1));
    expect(acked, [same(p0)]);
    expect(p0.sequence, resent);
    expect(p0.dataBytes, 1000);
    expect(p0.lastSentTime! >= p0.sentTime!, isTrue,
        reason: 'the resend moved lastSentTime; sentTime is still the first send');
  });

  test('the RTT is sampled only when the largest acknowledged packet is newly acknowledged', () {
    final t = const SystemClock().now() - (const Duration(milliseconds: 80));
    cc.onPacketSent(1000);
    cc.onPacketAcked(1000, t, Duration.zero, true, 0);
    final sampled = cc.smoothedRtt;
    expect(sampled.inMilliseconds, closeTo(80, 10));

    // A frame whose largest was already acknowledged (a repeat, or ranges
    // filling in older packets) gives no sample.
    cc.onPacketSent(1000);
    cc.onPacketAcked(1000, const SystemClock().now() - (const Duration(seconds: 3)), Duration.zero, false, 0);
    expect(cc.smoothedRtt, sampled);
  });

  test('the window grows by the bytes newly acknowledged, whatever their sequences', () {
    final before = cc.cwnd;
    cc.onPacketSent(3000);
    // Three packets acknowledged together, the frame's largest being new.
    cc.onPacketAcked(3000, const SystemClock().now(), Duration.zero, true, 7);
    expect(cc.cwnd, before + 3000, reason: 'slow start adds every acknowledged byte');
    expect(cc.inflight, 0);
  });

  test('recovery ends when a packet sent after it began is acknowledged, retransmissions included', () {
    for (var i = 0; i < 5; i++) {
      pm.sendPacket(_dataPacket(pm.nextSequence));
      cc.onPacketSent(1000);
    }
    expect(pm.lastSentPacketNumber, 4);
    cc.onPacketLost(1000, []); // recovery starts; ends after sequence 4
    expect(cc.isInRecoveryForTest, isTrue);
    final reduced = cc.cwnd;

    // The lost packet is resent under sequence 5. Its ACK, the largest being
    // past 4, ends recovery, and the window may grow again on the next ACK.
    cc.onPacketAcked(1000, const SystemClock().now(), Duration.zero, true, 5);
    expect(cc.isInRecoveryForTest, isFalse);
    cc.onPacketSent(1000);
    cc.onPacketAcked(1000, const SystemClock().now(), Duration.zero, true, 6);
    expect(cc.cwnd, greaterThan(reduced));
  });

  test('an acknowledged packet whose original sequence is never acknowledged does not freeze the controller', () {
    // The shape of the old failure: sequence 1 is lost, resent as 3, and 3 is
    // acknowledged. Sequence 1 itself is never acknowledged.
    for (var i = 0; i < 3; i++) {
      pm.sendPacket(_dataPacket(pm.nextSequence));
      cc.onPacketSent(1000);
    }
    final p1 = pm.getPacket(1)!;
    final resent = pm.resend(p1)!;
    expect(resent, 3);

    cc.onPacketAcked(2000, const SystemClock().now() - (const Duration(milliseconds: 40)), Duration.zero, true, 2); // 0 and 2
    final rttAfterFirst = cc.smoothedRtt;
    final cwndAfterFirst = cc.cwnd;
    cc.onPacketAcked(1000, const SystemClock().now() - (const Duration(milliseconds: 60)), Duration.zero, true, 3); // the resend
    expect(cc.smoothedRtt, isNot(rttAfterFirst), reason: 'the resend gave an RTT sample');
    expect(cc.cwnd, cwndAfterFirst + 1000, reason: 'and grew the window');
    expect(cc.inflight, 0);
  });
}
