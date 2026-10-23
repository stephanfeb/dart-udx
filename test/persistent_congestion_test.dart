/// Persistent congestion (RFC 9002 section 7.6): when the lost packets span
/// three PTOs or more and nothing was acknowledged since the oldest went
/// out, the window collapses to the minimum and recovery ends.
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
      frames: [StreamFrame(data: Uint8List(1000))],
    );

void main() {
  late FakeClock clock;
  late PacketManager pm;
  late CongestionController cc;

  setUp(() {
    clock = FakeClock();
    pm = PacketManager(clock: clock);
    cc = CongestionController(packetManager: pm, clock: clock);
    pm.congestionController = cc;
    // An RTT sample: persistent congestion is only declared once there is one.
    cc.onPacketSent(1000);
    clock.advance(const Duration(milliseconds: 50));
    cc.onPacketAcked(1000, clock.now() - const Duration(milliseconds: 50), Duration.zero, true, -1);
  });

  tearDown(() {
    cc.destroy();
    pm.destroy();
  });

  /// Sends [n] packets one PTO apart, none acknowledged, then one more that
  /// is acknowledged after a round trip, and returns what that ACK declares
  /// lost. (Acknowledged at once it would be a zero RTT sample, which moves
  /// the PTO the span is measured against.)
  List<UDXPacket> sendAcrossPtos(int n) {
    for (var i = 0; i < n; i++) {
      pm.sendPacket(_dataPacket(pm.nextSequence));
      cc.onPacketSent(1000);
      clock.advance(cc.pto);
    }
    final last = _dataPacket(pm.nextSequence);
    pm.sendPacket(last);
    cc.onPacketSent(1000);
    clock.advance(const Duration(milliseconds: 50));
    pm.handleAckFrame(AckFrame(largestAcked: last.sequence, ackDelay: 0, firstAckRangeLength: 1));
    cc.onPacketAcked(1000, last.lastSentTime, Duration.zero, true, last.sequence);
    return pm.detectLostPackets();
  }

  test('a loss span of three PTOs with no ACK in between is persistent congestion', () {
    final lost = sendAcrossPtos(4); // sends at 0, 1, 2, 3 PTO: a span of three
    expect(lost.length, 4);
    expect(pm.persistentCongestion(lost), isTrue);

    final before = cc.cwnd;
    cc.onPacketLost(4000, lost);
    cc.onPersistentCongestion();
    expect(cc.cwnd, CongestionController.minCwnd, reason: 'was $before');
    expect(cc.isInRecoveryForTest, isFalse, reason: 'recovery ends so slow start can restart');
  });

  test('a shorter span is ordinary loss', () {
    final lost = sendAcrossPtos(2); // a span of one PTO
    expect(lost.length, 2);
    expect(pm.persistentCongestion(lost), isFalse);
  });

  test('an ACK received after the oldest lost packet went out rules it out', () {
    // Packet 0 goes out, then packet 1 (the oldest to be lost), then an ACK
    // of 0 arrives: something was acknowledged after 1 was sent, so however
    // long the loss then spans, the path was not dead the whole time.
    final first = _dataPacket(pm.nextSequence); // 0, acknowledged
    pm.sendPacket(first);
    cc.onPacketSent(1000);
    clock.advance(const Duration(milliseconds: 5));
    pm.sendPacket(_dataPacket(pm.nextSequence)); // 1, to be lost
    cc.onPacketSent(1000);
    clock.advance(const Duration(milliseconds: 5));
    pm.handleAckFrame(AckFrame(largestAcked: 0, ackDelay: 0, firstAckRangeLength: 1));
    cc.onPacketAcked(1000, first.lastSentTime, Duration.zero, true, 0);
    expect(pm.detectLostPackets(), isEmpty, reason: '1 is above the largest acknowledged');
    clock.advance(cc.pto);

    final lost = sendAcrossPtos(3); // 2, 3, 4 one PTO apart; the ACK of 5 reveals the loss
    expect(lost.map((p) => p.sequence), [1, 2, 3, 4]);
    expect(lost.last.lastSentTime! - lost.first.lastSentTime!, greaterThanOrEqualTo(cc.persistentCongestionDuration),
        reason: 'the span alone would qualify');
    expect(pm.persistentCongestion(lost), isFalse,
        reason: 'an ACK arrived after the oldest lost packet went out');
  });

  test('without an RTT sample nothing is persistent', () {
    final fresh = PacketManager(clock: clock);
    final freshCc = CongestionController(packetManager: fresh, clock: clock);
    fresh.congestionController = freshCc;
    addTearDown(freshCc.destroy);
    for (var i = 0; i < 4; i++) {
      fresh.sendPacket(_dataPacket(fresh.nextSequence));
      clock.advance(freshCc.pto);
    }
    final last = _dataPacket(fresh.nextSequence);
    fresh.sendPacket(last);
    fresh.handleAckFrame(AckFrame(largestAcked: last.sequence, ackDelay: 0, firstAckRangeLength: 1));
    final lost = fresh.detectLostPackets();
    expect(lost.length, 4);
    expect(fresh.persistentCongestion(lost), isFalse);
  });
}
