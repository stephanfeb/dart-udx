/// Loss is declared from acknowledgements (RFC 9002 section 6.1), never from
/// a per-packet timer: a packet below the largest acknowledged is lost once
/// it is three sequences behind it or older than 9/8 of the RTT, and the
/// loss timer catches the latter without another ACK.
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
      frames: [StreamFrame(data: Uint8List(100), offset: sequence * 100)],
    );

List<int> _seqs(List<UDXPacket> packets) => packets.map((p) => p.sequence).toList();

void main() {
  late FakeClock clock;
  late PacketManager pm;
  late CongestionController cc;
  late List<UDXPacket> lost;

  setUp(() {
    clock = FakeClock();
    pm = PacketManager(clock: clock);
    cc = CongestionController(packetManager: pm, clock: clock);
    pm.congestionController = cc;
    cc.setSmoothedRtt(const Duration(milliseconds: 50));
    lost = [];
    pm.onPacketsLost = lost.addAll;
  });

  tearDown(() {
    cc.destroy();
    pm.destroy();
  });

  void sendN(int n) {
    for (var i = 0; i < n; i++) {
      pm.sendPacket(_dataPacket(pm.nextSequence));
    }
  }

  test('packets three or more behind the largest acknowledged are lost; one or two behind wait', () {
    sendN(10);
    // 9 and 8 acknowledged; 7 and below in a gap.
    pm.handleAckFrame(AckFrame(
      largestAcked: 9,
      ackDelay: 0,
      firstAckRangeLength: 2,
      ackRanges: [AckRange(gap: 4, ackRangeLength: 1)], // 3 as well
    ));
    pm.detectLostPackets();

    expect(_seqs(lost), [0, 1, 2, 4, 5, 6], reason: 'in sequence order; 3 was acknowledged');
    expect(pm.getPacket(7), isNotNull, reason: 'two behind and just sent: reordering still explains it');
    expect(pm.lossTimerArmed, isTrue, reason: '7 waits on the time threshold');
  });

  test('a receiver that acknowledges one packet at a time still yields loss: by the time threshold', () {
    // No gaps in such ACKs; the old code only looked at the gaps.
    sendN(5);
    pm.handleAckFrame(AckFrame(largestAcked: 4, ackDelay: 0, firstAckRangeLength: 1));
    pm.detectLostPackets();
    expect(_seqs(lost), [0, 1], reason: 'three or more behind');
    expect(pm.lossTimerArmed, isTrue);

    lost.clear();
    clock.advance(pm.lossDelay - const Duration(milliseconds: 1));
    expect(lost, isEmpty);
    clock.advance(const Duration(milliseconds: 1));
    expect(_seqs(lost), [2, 3], reason: 'older than 9/8 RTT: the loss timer declared them lost');
    expect(pm.lossTimerArmed, isFalse);
  });

  test('the loss delay is 9/8 of the larger of the smoothed and latest RTT, floored at 1 ms', () {
    expect(pm.lossDelay, const Duration(microseconds: 56250)); // 9/8 of 50 ms
    // One much slower sample: latest jumps, smoothed barely moves.
    cc.onPacketSent(100);
    cc.onPacketAcked(100, clock.now() - const Duration(milliseconds: 400), Duration.zero, true, 0);
    expect(cc.latestRttForTest, const Duration(milliseconds: 400));
    expect(pm.lossDelay, const Duration(milliseconds: 450));

    cc.setSmoothedRtt(Duration.zero);
    cc.onPacketSent(100);
    cc.onPacketAcked(100, clock.now(), Duration.zero, true, 1);
    expect(pm.lossDelay, PacketManager.lossTimerGranularity);
  });

  test('a re-sent packet is tracked above the largest acknowledged and is not lost again by the same ACK', () {
    sendN(5);
    pm.handleAckFrame(AckFrame(largestAcked: 4, ackDelay: 0, firstAckRangeLength: 1));
    pm.detectLostPackets();
    expect(_seqs(lost), [0, 1]);
    final packet = lost.first;
    expect(pm.resend(packet), 5);

    lost.clear();
    pm.handleAckFrame(AckFrame(largestAcked: 4, ackDelay: 0, firstAckRangeLength: 1));
    pm.detectLostPackets();
    expect(lost, isEmpty);
    expect(pm.getPacket(5), same(packet));
  });

  test('a gap the peer keeps reporting for a sequence no longer tracked costs nothing', () {
    // A resend has a fresh sequence, so the dropped sequence stays a gap in
    // every later ACK's ranges; only tracked packets can be declared lost.
    sendN(4);
    pm.handleAckFrame(AckFrame(largestAcked: 3, ackDelay: 0, firstAckRangeLength: 1));
    pm.detectLostPackets();
    expect(_seqs(lost), [0]);
    lost.clear();
    pm.resend(pm.oldestUnacked(1).first); // 1 -> 4, as a probe would
    pm.handleAckFrame(AckFrame(
      largestAcked: 4,
      ackDelay: 0,
      firstAckRangeLength: 1,
      ackRanges: [AckRange(gap: 1, ackRangeLength: 2)], // 3 and 2 acknowledged
    ));
    pm.detectLostPackets();
    expect(lost, isEmpty);
    expect(pm.getSentPacketsTestHook(), isEmpty);
  });
}
