import 'package:dart_udx/src/congestion.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:test/test.dart';

void main() {
  group('Duplicate ACK Test', () {
    late CongestionController congestion;
    late PacketManager packetManager;
    int? retransmittedPacket;

    setUp(() {
      packetManager = PacketManager();
      congestion = CongestionController(packetManager: packetManager);
      packetManager.congestionController = congestion;
      congestion.onFastRetransmit = (sequence) {
        retransmittedPacket = sequence;
      };
      retransmittedPacket = null;
    });

    test('Retransmission should be triggered after 3 duplicate ACKs', () {
      // Simulate 3 duplicate ACKs for sequence 10
      congestion.processDuplicateAck(10);
      congestion.processDuplicateAck(10);
      congestion.processDuplicateAck(10);

      // Verify that retransmission is triggered for sequence 11
      expect(retransmittedPacket, 11, reason: 'Retransmission should be triggered for sequence number 11');
    });
  });
}
