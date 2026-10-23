/// One probe timeout per connection (RFC 9002 section 6.2): it backs off
/// until an ACK, which starts it over, and it includes the peer's ACK delay.
library;

import 'package:dart_udx/src/clock.dart';
import 'package:dart_udx/src/congestion.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:test/test.dart';

void main() {
  late FakeClock clock;
  late CongestionController cc;
  late int probes;

  setUp(() {
    clock = FakeClock();
    final pm = PacketManager(clock: clock);
    cc = CongestionController(packetManager: pm, clock: clock);
    pm.congestionController = cc;
    probes = 0;
    cc.onProbe = () => probes++;
  });

  tearDown(() => cc.destroy());

  test('each PTO that fires without an ACK doubles the wait for the next; an ACK starts over', () {
    cc.onPacketSent(1200);
    final base = cc.pto;
    expect(cc.nextPto, base);

    var waited = Duration.zero;
    for (var i = 1; i <= 4; i++) {
      final wait = base * (1 << (i - 1));
      clock.advance(wait - const Duration(milliseconds: 1));
      expect(probes, i - 1, reason: 'not yet, after $waited + $wait');
      clock.advance(const Duration(milliseconds: 1));
      waited += wait;
      expect(probes, i, reason: 'PTO $i fired at $waited');
      expect(cc.ptoCount, i);
      expect(cc.nextPto, base * (1 << i));
    }

    cc.onPacketAcked(1200, clock.now() - const Duration(milliseconds: 30), Duration.zero, true, 0);
    expect(cc.ptoCount, 0);
    expect(cc.nextPto, cc.pto, reason: 'the base again (the ACK moved the base with its sample)');
  });

  test('the PTO is measured from the last send and is quiet with nothing in flight', () {
    cc.onPacketSent(1200);
    clock.advance(const Duration(milliseconds: 150));
    cc.onPacketAcked(600, clock.now() - const Duration(milliseconds: 150), Duration.zero, true, 0);
    // 600 bytes still in flight: the timer is re-armed from the last send,
    // not from the ACK, so it fires PTO after the send.
    final pto = cc.pto;
    clock.advance(pto - const Duration(milliseconds: 150) - const Duration(milliseconds: 1));
    expect(probes, 0);
    clock.advance(const Duration(milliseconds: 1));
    expect(probes, 1);

    cc.onPacketAcked(600, clock.now() - const Duration(milliseconds: 20), Duration.zero, true, 1);
    clock.advance(const Duration(minutes: 1));
    expect(probes, 1, reason: 'nothing in flight: no PTO');
  });

  test('the PTO includes max_ack_delay, so a delayed ACK alone does not fire it', () {
    cc.setSmoothedRtt(const Duration(milliseconds: 400));
    cc.setRttVar(const Duration(milliseconds: 50));
    expect(cc.pto, const Duration(milliseconds: 400 + 200 + CongestionController.maxAckDelay));
  });
}
