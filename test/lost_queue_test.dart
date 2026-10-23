/// Lost packets are re-sent through the congestion window and the pacer,
/// oldest first, under fresh sequences, booked as the new packets they are.
library;

import 'dart:typed_data';

import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/clock.dart';
import 'package:dart_udx/src/congestion.dart';
import 'package:dart_udx/src/lost_queue.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:test/test.dart';

UDXPacket _dataPacket(int sequence) => UDXPacket(
      destinationCid: ConnectionId.random(),
      sourceCid: ConnectionId.random(),
      destinationStreamId: 1,
      sourceStreamId: 2,
      sequence: sequence,
      frames: [StreamFrame(data: Uint8List(1000), offset: sequence * 1000)],
    );

void main() {
  late FakeClock clock;
  late PacketManager pm;
  late CongestionController cc;
  late List<UDXPacket> sent;
  late LostQueue queue;

  setUp(() {
    clock = FakeClock();
    pm = PacketManager(clock: clock);
    cc = CongestionController(packetManager: pm, clock: clock, initialCwnd: 3000);
    pm.congestionController = cc;
    sent = [];
    queue = LostQueue(
      packetManager: pm,
      congestionController: cc,
      clock: clock,
      send: (bytes) => sent.add(UDXPacket.fromBytes(bytes)),
    );
    // Unlimited pacing unless a test says otherwise.
    cc.pacingController.updateRate(cc.cwnd, Duration.zero);
  });

  tearDown(() {
    queue.dispose();
    cc.destroy();
    pm.destroy();
  });

  List<UDXPacket> lostPackets(int n) {
    final lost = <UDXPacket>[];
    for (var i = 0; i < n; i++) {
      final p = _dataPacket(pm.nextSequence);
      p.sentTime = clock.now();
      p.lastSentTime = clock.now();
      lost.add(p);
    }
    return lost;
  }

  test('re-sends what the window admits, under fresh sequences, and the rest when the window opens', () {
    final lost = lostPackets(5); // 5000 bytes against a 3000-byte window
    queue.add(lost);

    expect(sent.length, 3, reason: 'three fit the window');
    expect(sent.map((p) => p.sequence), [5, 6, 7], reason: 'fresh sequences');
    expect(cc.inflight, 3000, reason: 'booked as new packets');
    expect(queue.length, 2);
    for (final p in sent) {
      expect(pm.getPacket(p.sequence), isNotNull, reason: 'tracked under the fresh sequence');
    }

    // An ACK of a resend opens the window (1000 bytes back, and slow start
    // adds 1000 more): the socket flushes again and the rest goes out.
    pm.handleAckFrame(AckFrame(largestAcked: 5, ackDelay: 0, firstAckRangeLength: 1));
    cc.onPacketAcked(1000, clock.now(), Duration.zero, true, 5);
    queue.flush();
    expect(sent.length, 5);
    expect(queue.length, 0);
    expect(cc.inflight, lessThanOrEqualTo(cc.cwnd));
  });

  test('waits for the pacer and resumes on its timer', () {
    cc.pacingController.updateRate(10000, const Duration(seconds: 1)); // 28.8 KB/s: ~36 ms per packet
    queue.add(lostPackets(2));
    expect(sent.length, 1, reason: 'the first goes at once, the second waits for the pacer');
    expect(queue.length, 1);
    expect(clock.pendingTimers, greaterThan(0));

    clock.advance(const Duration(milliseconds: 50));
    expect(sent.length, 2);
    expect(queue.length, 0);
  });

  test('a packet acknowledged while queued is dropped from the queue', () {
    final lost = lostPackets(2);
    cc.onPacketSent(3000); // the window is full
    queue.add(lost);
    expect(sent, isEmpty);
    lost.first.isAcked = true;
    cc.onPacketAcked(3000, clock.now(), Duration.zero, true, 99);
    queue.flush();
    expect(sent.map((p) => p.sequence), [lost.last.sequence]);
  });
}
