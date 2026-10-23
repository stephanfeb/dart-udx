/// Path-MTU discovery (RFC 8899): the search up from the base datagram
/// size, and the fallback when a path stops carrying a validated size.
library;

import 'dart:typed_data';

import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/clock.dart';
import 'package:dart_udx/src/congestion.dart';
import 'package:dart_udx/src/constants.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:dart_udx/src/pmtud.dart';
import 'package:test/test.dart';

void main() {
  late FakeClock clock;
  late MtuDiscovery mtu;

  setUp(() {
    clock = FakeClock();
    mtu = MtuDiscovery(clock: clock);
  });

  test('a path that carries full Ethernet frames is found in one probe', () {
    expect(mtu.current, safeDatagramSize, reason: 'starts at the base');
    expect(mtu.nextProbe(), maxDatagramSize);
    expect(mtu.nextProbe(), 0, reason: 'one probe at a time');
    mtu.onProbeAcked(maxDatagramSize);
    expect(mtu.current, maxDatagramSize);
    expect(mtu.done, isTrue);
  });

  test('on a path that carries 1322 bytes the search settles within a step under it', () {
    const path = 1350 - 28;
    var probes = 0;
    while (true) {
      final size = mtu.nextProbe();
      if (size == 0) break;
      probes++;
      if (size <= path) {
        mtu.onProbeAcked(size);
      } else {
        mtu.onProbeLost(size);
      }
      expect(probes, lessThan(40), reason: 'the search does not end');
    }
    expect(mtu.current, inInclusiveRange(path - mtuSearchStep + 1, path));
    expect(mtu.current, greaterThan(safeDatagramSize));
  });

  test('one loss does not rule a size out: it is tried mtuProbeTries times', () {
    for (var i = 1; i <= mtuProbeTries; i++) {
      expect(mtu.nextProbe(), maxDatagramSize, reason: 'try $i');
      mtu.onProbeLost(maxDatagramSize);
    }
    final next = mtu.nextProbe();
    expect(next, lessThan(maxDatagramSize));
    expect(next, greaterThan(safeDatagramSize));
  });

  test('full-size data lost in a row with none acknowledged between is a black hole, retried after a minute', () {
    mtu.nextProbe();
    mtu.onProbeAcked(maxDatagramSize);

    for (var i = 1; i < blackholePackets; i++) {
      mtu.onDataLost(maxDatagramSize);
    }
    mtu.onDataAcked(maxDatagramSize); // one got through: the count starts over
    for (var i = 1; i < blackholePackets; i++) {
      mtu.onDataLost(maxDatagramSize);
    }
    expect(mtu.current, maxDatagramSize, reason: 'an ACK in between');
    mtu.onDataLost(safeDatagramSize);
    expect(mtu.current, maxDatagramSize, reason: 'a base-size loss says nothing about the size');
    mtu.onDataLost(maxDatagramSize);
    expect(mtu.current, safeDatagramSize);
    expect(mtu.done, isTrue);
    expect(mtu.nextProbe(), 0, reason: 'not right after a black hole');
    clock.advance(blackholeRetry);
    expect(mtu.nextProbe(), maxDatagramSize, reason: 'the search restarts');
  });

  test('a black hole from probe timeouts ignores a stale probe; reset starts over', () {
    mtu.nextProbe();
    mtu.onProbeAcked(maxDatagramSize);
    mtu.blackhole();
    expect(mtu.current, safeDatagramSize);
    mtu.onProbeAcked(maxDatagramSize);
    expect(mtu.current, safeDatagramSize, reason: 'a stale probe ACK after a black hole');
    mtu.reset();
    expect(mtu.current, safeDatagramSize);
    expect(mtu.nextProbe(), maxDatagramSize);
  });

  test('a PTO probe re-chunks a packet the path no longer carries, in its place', () {
    final pm = PacketManager(clock: clock);
    final cc = CongestionController(packetManager: pm, clock: clock);
    pm.congestionController = cc;
    addTearDown(() {
      cc.destroy();
      pm.destroy();
    });
    final sent = <UDXPacket>[];
    pm.onRetransmit = (p) => sent.add(UDXPacket.fromBytes(p.toBytes()));

    final data = Uint8List.fromList(List.generate(maxDatagramSize - streamPacketOverhead, (i) => i % 251));
    final packet = UDXPacket(
      destinationCid: ConnectionId.random(length: ConnectionId.maxCidLength),
      sourceCid: ConnectionId.random(length: ConnectionId.maxCidLength),
      destinationStreamId: 1,
      sourceStreamId: 2,
      sequence: pm.nextSequence,
      frames: [StreamFrame(data: data, offset: 4000)],
    );
    packet.wireSize = packet.toBytes().length;
    expect(packet.wireSize, greaterThan(safeDatagramSize), reason: 'the test needs a full-size packet');
    pm.sendPacket(packet);
    cc.onPacketSent(data.length);

    expect(pm.sendProbe(maxDatagram: safeDatagramSize), isTrue);
    expect(sent.length, greaterThanOrEqualTo(2), reason: 're-chunked');
    var offset = 4000;
    final got = <int>[];
    for (final p in sent) {
      expect(p.toBytes().length, lessThanOrEqualTo(safeDatagramSize));
      final f = p.frames.single as StreamFrame;
      expect(f.offset, offset);
      got.addAll(f.data);
      offset += f.data.length;
    }
    expect(got, data);
    expect(pm.getSentPacketsTestHook().length, sent.length, reason: 'the pieces are tracked in place of the packet');
  });
}
