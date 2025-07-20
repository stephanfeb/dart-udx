import 'package:dart_udx/src/congestion.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:test/test.dart';

void main() {
  group('CongestionController', () {
    late CongestionController congestion;
    late PacketManager packetManager;

    setUp(() {
      packetManager = PacketManager();
      congestion = CongestionController(packetManager: packetManager);
      packetManager.congestionController = congestion;
    });

    test('initializes with correct default values', () {
      expect(congestion.cwnd, equals(1472 * 10));
      expect(congestion.inflight, equals(0));
      expect(congestion.ssthresh, isPositive);
    });

    test('onPacketSent increases inflight bytes', () {
      congestion.onPacketSent(1000);
      expect(congestion.inflight, equals(1000));
      congestion.onPacketSent(500);
      expect(congestion.inflight, equals(1500));
    });
  });
}
