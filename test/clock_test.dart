/// Timing runs on a monotonic, injectable Clock (lib/src/clock.dart): never
/// the wall clock, which a phone steps. FakeClock lets a test move time by
/// hand and see exactly what fires.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_udx/dart_udx.dart';
import 'package:test/test.dart';

void main() {
  group('FakeClock', () {
    test('fires due timers in due order, each at its own time, and leaves the rest', () {
      final clock = FakeClock();
      final log = <String>[];
      clock.timer(const Duration(milliseconds: 30), () => log.add('c@${clock.now().inMilliseconds}'));
      clock.timer(const Duration(milliseconds: 10), () => log.add('a@${clock.now().inMilliseconds}'));
      clock.timer(const Duration(milliseconds: 10), () => log.add('b@${clock.now().inMilliseconds}'));
      final late = clock.timer(const Duration(milliseconds: 100), () => log.add('late'));

      clock.advance(const Duration(milliseconds: 35));
      expect(log, ['a@10', 'b@10', 'c@30']);
      expect(clock.now(), const Duration(milliseconds: 35));
      expect(late.isActive, isTrue);
      expect(clock.pendingTimers, 1);

      late.cancel();
      clock.advance(const Duration(seconds: 1));
      expect(log, ['a@10', 'b@10', 'c@30']);
      expect(clock.pendingTimers, 0);
    });

    test('a timer armed by a firing timer fires in the same advance when due', () {
      final clock = FakeClock();
      final log = <int>[];
      clock.timer(const Duration(milliseconds: 10), () {
        log.add(clock.now().inMilliseconds);
        clock.timer(const Duration(milliseconds: 10), () => log.add(clock.now().inMilliseconds));
      });
      clock.advance(const Duration(milliseconds: 25));
      expect(log, [10, 20]);
    });
  });

  group('timing on the clock', () {
    test('an RTT sample is exactly the clock time between send and ACK', () {
      final clock = FakeClock();
      final pm = PacketManager(clock: clock);
      final cc = CongestionController(packetManager: pm, clock: clock);
      pm.congestionController = cc;
      addTearDown(cc.destroy);

      final sentAt = clock.now();
      cc.onPacketSent(1000);
      clock.advance(const Duration(milliseconds: 137));
      cc.onPacketAcked(1000, sentAt, Duration.zero, true, 0);
      expect(cc.latestRttForTest, const Duration(milliseconds: 137));
      expect(cc.smoothedRtt, const Duration(milliseconds: 137));
    });

    test('the PTO fires on the clock, not on real time', () {
      final clock = FakeClock();
      final pm = PacketManager(clock: clock);
      final cc = CongestionController(packetManager: pm, clock: clock);
      pm.congestionController = cc;
      addTearDown(cc.destroy);
      var probes = 0;
      cc.onProbe = () => probes++;

      cc.onPacketSent(1000);
      clock.advance(cc.pto - const Duration(milliseconds: 1));
      expect(probes, 0);
      clock.advance(const Duration(milliseconds: 1));
      expect(probes, 1);
    });

    test('a silent connection idle-closes after the idle timeout on the clock', () async {
      final clock = FakeClock();
      final udx = UDX();
      final clientRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final serverRaw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final client = UDXMultiplexer(clientRaw, clock: clock);
      final server = UDXMultiplexer(serverRaw);
      addTearDown(() {
        client.close();
        server.close();
      });

      final socket = client.createSocket(udx, serverRaw.address.address, serverRaw.port);
      final closed = Completer<void>();
      socket.on('close').listen((_) {
        if (!closed.isCompleted) closed.complete();
      });

      // Nothing is ever received: the watchdog, on the fake clock, finds the
      // connection silent once the idle timeout has passed on that clock,
      // however little real time has.
      clock.advance(const Duration(seconds: 29));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(closed.isCompleted, isFalse);
      clock.advance(const Duration(seconds: 2));
      await closed.future.timeout(const Duration(seconds: 2));
      expect(socket.closing, isTrue);
    });
  });
}
