import 'package:test/test.dart';
import 'package:dart_udx/src/congestion.dart';
import 'package:dart_udx/src/packet.dart';

void main() {
  group('CongestionController Cwnd', () {
    late CongestionController controller;
    late PacketManager packetManager;

    setUp(() {
      packetManager = PacketManager();
      controller = CongestionController(packetManager: packetManager);
      packetManager.congestionController = controller;
    });

    test('initializes with the correct RFC 9002 recommended window', () {
      // As per RFC 9002, initial window is the larger of 10 * max_datagram_size or 14720 bytes.
      // 10 * 1472 = 14720. So, it should be 14720.
      expect(controller.cwnd, equals(14720));
    });

    test('resets to a reduced window on packet loss', () {
      // Simulate some network activity
      controller.onPacketSent(10000);
      controller.onPacketAcked(10000, DateTime.now(), Duration.zero, true, 1);
      
      // Ensure cwnd has grown
      expect(controller.cwnd, greaterThan(CongestionController.initialCwnd));

      // Simulate packet loss
      controller.onPacketLost(1472, []);

      // Verify cwnd is set to the new ssthresh
      final expectedSsthresh = controller.ssthresh;
      expect(controller.cwnd, equals(expectedSsthresh));
    });
  });
}
