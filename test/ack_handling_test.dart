@Skip('Per-stream PM/CC moved to socket level - needs rewrite for per-connection sequencing')
library;

import 'dart:async';
import 'dart:math'; // Added for 'max'
import 'dart:typed_data';

import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/congestion.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:dart_udx/src/udx.dart';
import 'package:dart_udx/src/socket.dart'; // UDPSocket needed for UDXStream
import 'package:test/test.dart';
import 'package:mockito/annotations.dart'; // For @GenerateMocks
import 'package:mockito/mockito.dart'; // For Mock, when, verify etc.

import 'ack_handling_test.mocks.dart'; // Generated mocks

// Helper to access private _sendAck method via a public wrapper for testing
// This class now needs to manage its own state for _receivedPacketSequences
// and _largestAckedPacketArrivalTime as it overrides _sendAck.
class TestableUDXStream extends UDXStream {
  final MockCongestionController mockCongestionController;
  final MockPacketManager mockPacketManager; // Added to hold the mock PM

  // Fields to hold state for the overridden _sendAck logic
  final Set<int> _receivedPacketSequences = {};
  DateTime? _largestAckedPacketArrivalTime;

  TestableUDXStream(UDX udx, int id, {UDPSocket? socket, MockCongestionController? congestionController, MockPacketManager? packetManager})
      : mockCongestionController = congestionController ?? MockCongestionController(),
        mockPacketManager = packetManager ?? MockPacketManager(), // Initialize our mock PM
        super(
            udx, 
            id, 
            congestionControllerForTest: congestionController ?? MockCongestionController(),
            packetManagerForTest: packetManager ?? MockPacketManager() // Pass it to super
        ) {
    this.remoteId = 1; // Dummy remoteId
    this.remoteHost = '127.0.0.1';
    this.remotePort = 12345;
    // Use the new method to set the socket
    setSocketForTest(socket ?? MockUDPSocket());
    // The line "super.packetManager = MockPacketManager();" is now removed.
  }

  AckFrame? capturedAckFrame;

  // Override _sendAck to capture the AckFrame.
  // This logic is copied from UDXStream and uses this class's
  // _receivedPacketSequences and _largestAckedPacketArrivalTime.
  @override
  void _sendAck() {
    if (_receivedPacketSequences.isEmpty) {
      capturedAckFrame = null;
      return;
    }

    final sortedSequences = _receivedPacketSequences.toList()..sort();
    if (sortedSequences.isEmpty) {
       capturedAckFrame = null;
       return;
    }

    final int largestAcked = sortedSequences.last;
    int ackDelayMs = 0;
    if (_largestAckedPacketArrivalTime != null) {
      ackDelayMs = DateTime.now().difference(_largestAckedPacketArrivalTime!).inMilliseconds;
      ackDelayMs = ackDelayMs.clamp(0, 65535);
    }

    List<AckRange> ackRanges = [];
    int firstAckRangeLength = 0;
    List<Map<String, int>> blocks = [];

    if (sortedSequences.isNotEmpty) {
      int blockStart = sortedSequences[0];
      for (int i = 0; i < sortedSequences.length; i++) {
        if (i + 1 < sortedSequences.length && sortedSequences[i + 1] == sortedSequences[i] + 1) {
        } else {
          blocks.add({'start': blockStart, 'end': sortedSequences[i]});
          if (i + 1 < sortedSequences.length) {
            blockStart = sortedSequences[i + 1];
          }
        }
      }
    }

    if (blocks.isNotEmpty) {
      final lastBlock = blocks.removeLast();
      firstAckRangeLength = lastBlock['end']! - lastBlock['start']! + 1;
      int prevBlockStartSeq = lastBlock['start']!;
      for (int i = blocks.length - 1; i >= 0; i--) {
        final currentBlock = blocks[i];
        final gap = prevBlockStartSeq - currentBlock['end']! - 1;
        final rangeLength = currentBlock['end']! - currentBlock['start']! + 1;
        ackRanges.add(AckRange(gap: gap, ackRangeLength: rangeLength));
        prevBlockStartSeq = currentBlock['start']!;
      }
    } else if (sortedSequences.isNotEmpty) {
        firstAckRangeLength = 1;
    }

    if (firstAckRangeLength == 0 && sortedSequences.isNotEmpty) {
        firstAckRangeLength = 1;
    }

    capturedAckFrame = AckFrame(
      largestAcked: largestAcked,
      ackDelay: ackDelayMs,
      firstAckRangeLength: firstAckRangeLength,
      ackRanges: ackRanges,
    );

    _receivedPacketSequences.clear();
    _largestAckedPacketArrivalTime = null;
  }

  AckFrame? triggerAndGetAckFrame() {
    _sendAck(); // Calls the overridden _sendAck in this class
    return capturedAckFrame;
  }

  void addReceivedSeq(int seq) {
    _receivedPacketSequences.add(seq);
    if (_largestAckedPacketArrivalTime == null || seq > (_receivedPacketSequences.isNotEmpty ? _receivedPacketSequences.reduce(max) : -1)) {
       _largestAckedPacketArrivalTime = DateTime.now();
    }
  }

  void setLargestAckedArrivalTime(DateTime time) {
    _largestAckedPacketArrivalTime = time;
  }

  Set<int> get testHookReceivedPacketSequences => _receivedPacketSequences;
}

@GenerateMocks([UDX, UDPSocket, CongestionController, PacketManager, Timer])
void main() {
  group('UDX Advanced ACK Handling', () {
    late TestableUDXStream stream;
    late MockUDX mockUdx;
    late MockUDPSocket mockSocket; // This will be an instance of the generated MockUDPSocket

    setUp(() {
      mockUdx = MockUDX();
      mockSocket = MockUDPSocket();
      // Stubbing default behavior for mockSocket if needed by TestableUDXStream constructor or its methods
      when(mockSocket.getAvailableConnectionSendWindow()).thenReturn(150000); // Default large enough

      stream = TestableUDXStream(mockUdx, 0, socket: mockSocket);
    });

    group('UDXStream._sendAck() - ACK Frame Generation', () {
      test('generates correct ACK for contiguous received packets', () {
        stream.addReceivedSeq(1);
        stream.addReceivedSeq(2);
        stream.addReceivedSeq(3);

        final ackFrame = stream.triggerAndGetAckFrame();

        expect(ackFrame, isNotNull);
        expect(ackFrame!.largestAcked, 3);
        expect(ackFrame.firstAckRangeLength, 3); // Covers 1, 2, 3
        expect(ackFrame.ackRanges, isEmpty);
      });

      test('generates correct ACK for packets with a single gap', () {
        // Simulating received packets 1, 2, 4, 5 (3 is missing)
        stream.addReceivedSeq(1);
        stream.addReceivedSeq(2);
        stream.addReceivedSeq(4);
        stream.addReceivedSeq(5);

        final ackFrame = stream.triggerAndGetAckFrame();

        expect(ackFrame, isNotNull);
        expect(ackFrame!.largestAcked, 5);
        expect(ackFrame.firstAckRangeLength, 2); // Covers 4, 5
        expect(ackFrame.ackRanges.length, 1);
        // Gap: (start of first range = 4) - (end of this range = 2) - 1 = 1
        expect(ackFrame.ackRanges[0].gap, 1); 
        expect(ackFrame.ackRanges[0].ackRangeLength, 2); // Covers 1, 2
      });

      test('generates correct ACK for packets with multiple gaps', () {
        // Simulating received 1, 3, 4, 6, 8, 9, 10
        // Gaps: 2, 5, 7
        stream.addReceivedSeq(1);
        stream.addReceivedSeq(3);
        stream.addReceivedSeq(4);
        stream.addReceivedSeq(6);
        stream.addReceivedSeq(8);
        stream.addReceivedSeq(9);
        stream.addReceivedSeq(10);

        final ackFrame = stream.triggerAndGetAckFrame();
        expect(ackFrame, isNotNull);
        expect(ackFrame!.largestAcked, 10);
        expect(ackFrame.firstAckRangeLength, 3); // Covers 8, 9, 10

        expect(ackFrame.ackRanges.length, 3); 

        // Ranges are ordered from highest sequence to lowest in the AckFrame.ackRanges list
        // Expected blocks (lowest to highest seq): [1], [3,4], [6], [8,9,10]
        // AckFrame ranges (derived from blocks, highest to lowest after first block):
        // 1. Range for 6: Gap from start of [8,9,10] (which is 8) to end of [6] (which is 6)
        //    Gap = 8 - 6 - 1 = 1. Length = 1.
        expect(ackFrame.ackRanges[0].gap, 1); // Gap for packet 7
        expect(ackFrame.ackRanges[0].ackRangeLength, 1); // Packet 6

        // 2. Range for 3,4: Gap from start of [6] (which is 6) to end of [3,4] (which is 4)
        //    Gap = 6 - 4 - 1 = 1. Length = 2.
        expect(ackFrame.ackRanges[1].gap, 1); // Gap for packet 5
        expect(ackFrame.ackRanges[1].ackRangeLength, 2); // Packets 3,4

        // 3. Range for 1: Gap from start of [3,4] (which is 3) to end of [1] (which is 1)
        //    Gap = 3 - 1 - 1 = 1. Length = 1.
        expect(ackFrame.ackRanges[2].gap, 1); // Gap for packet 2
        expect(ackFrame.ackRanges[2].ackRangeLength, 1); // Packet 1
      });

      test('generates ACK with only largest_acked if only one packet received', () {
        stream.addReceivedSeq(5);
        final ackFrame = stream.triggerAndGetAckFrame();

        expect(ackFrame, isNotNull);
        expect(ackFrame!.largestAcked, 5);
        expect(ackFrame.firstAckRangeLength, 1);
        expect(ackFrame.ackRanges, isEmpty);
      });

      test('ackDelay is calculated correctly', () async {
        final startTime = DateTime.now().subtract(Duration(milliseconds: 50));
        stream.addReceivedSeq(1);
        stream.setLargestAckedArrivalTime(startTime); // Manually set for consistent test

        final ackFrame = stream.triggerAndGetAckFrame();
        expect(ackFrame, isNotNull);
        expect(ackFrame!.ackDelay, greaterThanOrEqualTo(49)); // Allow for slight test execution delay
        expect(ackFrame.ackDelay, lessThan(100)); // Sanity check upper bound
      });
    });

    group('PacketManager.handleAckFrame() - ACK Frame Processing', () {
      late PacketManager packetManager;
      late MockCongestionController mockCongestionController;

      // Helper to populate sent packets and timers
      void setupSentPackets(List<int> sequences) {
      // Access private fields for testing - this is not ideal but common in unit tests for internal state.
      // In a real scenario, you might have methods to inspect this or design for testability.
      final sentPacketsInternal = packetManager.getSentPacketsTestHook(); 
      final retransmitTimersInternal = packetManager.getRetransmitTimersTestHook(); 

      for (final seq in sequences) {
        sentPacketsInternal[seq] = UDXPacket(
            destinationCid: ConnectionId.random(),
            sourceCid: ConnectionId.random(),
            destinationStreamId: 1,
            sourceStreamId: 0,
            sequence: seq,
            frames: [PingFrame()]); // Dummy packet
        retransmitTimersInternal[seq] = MockTimer(); // Use generated MockTimer
      }
    }

      setUp(() {
        mockCongestionController = MockCongestionController();
        packetManager = PacketManager(congestionController: mockCongestionController);
      });

      test('processes ACK for a single contiguous range (firstAckRangeLength only)', () {
        setupSentPackets([1, 2, 3, 4, 5]);
        final ackFrame = AckFrame(
            largestAcked: 3, ackDelay: 10, firstAckRangeLength: 3); // Acks 1, 2, 3

        final newlyAcked = packetManager.handleAckFrame(ackFrame);

        expect(newlyAcked, unorderedEquals([1, 2, 3]));
        expect(packetManager.getSentPacketsTestHook().containsKey(1), isFalse);
        expect(packetManager.getSentPacketsTestHook().containsKey(2), isFalse);
        expect(packetManager.getSentPacketsTestHook().containsKey(3), isFalse);
        expect(packetManager.getSentPacketsTestHook().containsKey(4), isTrue); // Not acked
        expect(packetManager.getSentPacketsTestHook().containsKey(5), isTrue); // Not acked

        expect(packetManager.getRetransmitTimersTestHook().containsKey(1), isFalse);
        expect(packetManager.getRetransmitTimersTestHook().containsKey(2), isFalse);
        expect(packetManager.getRetransmitTimersTestHook().containsKey(3), isFalse);
      });

      test('processes ACK with first range and one additional range', () {
        setupSentPackets([10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]);
        // Largest acked: 20. First range length: 2 (acks 19, 20)
        // Additional range: gap 1 (skip 18), length 3 (acks 15, 16, 17)
        // So, packets 15,16,17,19,20 should be acked.
        final ackFrame = AckFrame(
          largestAcked: 20,
          ackDelay: 10,
          firstAckRangeLength: 2, // Acks 20, 19
          ackRanges: [
            AckRange(gap: 1, ackRangeLength: 3) // Skips 18. Acks 17, 16, 15
          ],
        );

        final newlyAcked = packetManager.handleAckFrame(ackFrame);
        expect(newlyAcked, unorderedEquals([15, 16, 17, 19, 20]));

        expect(packetManager.getSentPacketsTestHook().containsKey(15), isFalse);
        expect(packetManager.getSentPacketsTestHook().containsKey(16), isFalse);
        expect(packetManager.getSentPacketsTestHook().containsKey(17), isFalse);
        expect(packetManager.getSentPacketsTestHook().containsKey(18), isTrue); // Gap
        expect(packetManager.getSentPacketsTestHook().containsKey(19), isFalse);
        expect(packetManager.getSentPacketsTestHook().containsKey(20), isFalse);

        expect(packetManager.getSentPacketsTestHook().containsKey(10), isTrue); // Not in any range
      });

      test('processes ACK with multiple additional ranges', () {
        setupSentPackets(List.generate(15, (i) => i + 1)); // Packets 1 to 15
        // Largest acked: 15. First range: 2 (acks 14, 15)
        // Range 1: gap 1 (skip 13), length 3 (acks 10, 11, 12)
        // Range 2: gap 2 (skip 9, 8), length 2 (acks 6, 7)
        // Acked: 6,7,10,11,12,14,15
        final ackFrame = AckFrame(
          largestAcked: 15,
          ackDelay: 10,
          firstAckRangeLength: 2, // 15, 14
          ackRanges: [
            AckRange(gap: 1, ackRangeLength: 3), // Skips 13. Acks 12, 11, 10
            AckRange(gap: 2, ackRangeLength: 2), // Skips 9, 8. Acks 7, 6
          ],
        );
        final newlyAcked = packetManager.handleAckFrame(ackFrame);
        expect(newlyAcked, unorderedEquals([6, 7, 10, 11, 12, 14, 15]));

        for (int i = 1; i <= 15; i++) {
          if ([6, 7, 10, 11, 12, 14, 15].contains(i)) {
            expect(packetManager.getSentPacketsTestHook().containsKey(i), isFalse, reason: "Packet $i should be acked");
          } else {
            expect(packetManager.getSentPacketsTestHook().containsKey(i), isTrue, reason: "Packet $i should not be acked");
          }
        }
      });

      test('handles ACK for packets not in sent list (no error, no change)', () {
        setupSentPackets([1, 2, 3]);
        final ackFrame = AckFrame(
            largestAcked: 10, ackDelay: 0, firstAckRangeLength: 1); // Acks 10

        final newlyAcked = packetManager.handleAckFrame(ackFrame);
        expect(newlyAcked, isEmpty);
        expect(packetManager.getSentPacketsTestHook().length, 3); // No change
      });

      test('handles empty ackRanges list correctly', () {
        setupSentPackets([1,2,3,4,5]);
         final ackFrame = AckFrame(
            largestAcked: 3, ackDelay: 0, firstAckRangeLength: 2, ackRanges: []); // Acks 3,2
        final newlyAcked = packetManager.handleAckFrame(ackFrame);
        expect(newlyAcked, unorderedEquals([2,3]));
        expect(packetManager.getSentPacketsTestHook().containsKey(1), isTrue);
        expect(packetManager.getSentPacketsTestHook().containsKey(2), isFalse);
        expect(packetManager.getSentPacketsTestHook().containsKey(3), isFalse);
      });
    });

    group('UDXStream.internalHandleSocketEvent() - ACK Frame Processing', () {
    late TestableUDXStream stream;
    late MockUDX mockUdx;
    late MockUDPSocket mockSocket; // Generated
    late MockCongestionController mockCc; // Generated
    late MockPacketManager mockPm; // This will be THE MockPacketManager instance

    setUp(() {
      mockUdx = MockUDX();
      mockSocket = MockUDPSocket();
      mockCc = MockCongestionController();
      mockPm = MockPacketManager(); // Instantiate THE mock PacketManager here

      // Stub methods for mockSocket that might be called by UDXStream
      when(mockSocket.getAvailableConnectionSendWindow()).thenReturn(150000);
      // Add stub for decrementConnectionBytesSent which is called when processing ACKs
      // Use thenAnswer for void methods instead of thenReturn
      when(mockSocket.decrementConnectionBytesSent(any)).thenAnswer((_) {});
      // MockUDPSocket.send is a no-op by default with generated mocks, which is fine.

      // Pass the single mockPm instance to TestableUDXStream
      stream = TestableUDXStream(
          mockUdx, 
          0, 
          socket: mockSocket, 
          congestionController: mockCc,
          packetManager: mockPm // Ensure the same mock is used by superclass and subclass field
      );
      // Now stream.packetManager (in UDXStream, used by internalHandleSocketEvent) 
      // and stream.mockPacketManager (in TestableUDXStream)
      // will both refer to the 'mockPm' instance created above.

      // Stub methods for mockPm that will be called by UDXStream.internalHandleSocketEvent
      // The stream's actual packetManager is a MockPacketManager.
      // It needs its nextSequence stubbed if the real _sendAck (not the overridden one) were called by internalHandleSocketEvent
      // However, internalHandleSocketEvent calls the stream's _sendAck, which in TestableUDXStream is overridden and doesn't use packetManager.nextSequence.
      // The mockPm.handleAckFrame is the one we are interested in verifying.
    });

    // Helper to set up stream._sentPackets (which is UDXStream's actual field)
    void setupStreamSentPackets(Map<int, (DateTime, int)> packets) {
      // UDXStream.getSentPacketsTestHook() provides access to the real _sentPackets map
      stream.getSentPacketsTestHook().clear();
      stream.getSentPacketsTestHook().addAll(packets);
    }

      test('processes a simple AckFrame and updates CC and PacketManager', () {
        final sendTime0 = DateTime.now().subtract(Duration(milliseconds: 110)); // Handshake packet
        final sendTime1 = DateTime.now().subtract(Duration(milliseconds: 100));
        final sendTime2 = DateTime.now().subtract(Duration(milliseconds: 90));
        setupStreamSentPackets({
          0: (sendTime0, 0),    // Handshake packet (no data, just establishes connection)
          1: (sendTime1, 1000),
          2: (sendTime2, 1000)
        });

        // Simulate that packetManager.handleAckFrame will report these as newly acked
        // (including packet 0 from the handshake)
        when(mockPm.handleAckFrame(any)).thenReturn([0, 1, 2]);

        final ackFrame = AckFrame(largestAcked: 2, ackDelay: 5, firstAckRangeLength: 3); // Acks 0, 1, 2
        final incomingPacket = UDXPacket(
            destinationCid: ConnectionId.random(),
            sourceCid: ConnectionId.random(),
            destinationStreamId: 0, // Stream's ID
            sourceStreamId: 1,    // Stream's remoteId
            sequence: 100,        // Sequence of the packet carrying the ACK
            frames: [ackFrame]);

        final event = {
          'data': incomingPacket.toBytes(),
          'address': '127.0.0.1',
          'port': 12345,
        };
        stream.internalHandleSocketEvent(event);

        // Verify PacketManager was called
        verify(mockPm.handleAckFrame(argThat(isA<AckFrame>()
          .having((f) => f.largestAcked, 'largestAcked', ackFrame.largestAcked)
          .having((f) => f.ackDelay, 'ackDelay', ackFrame.ackDelay)
          .having((f) => f.firstAckRangeLength, 'firstAckRangeLength', ackFrame.firstAckRangeLength)
          .having((f) => f.ackRanges, 'ackRanges', isEmpty) // ackFrame.ackRanges is empty in this test case
        ))).called(1);

        // Verify CongestionController was updated for each acked packet
        // Note: ackedSize is now correctly retrieved from the map.
        // ackFrame.largestAcked is 2 in this test.
        // Since this is the first ACK and largestAcked=2 advances past the initial state,
        // isNewCumulativeForCC will be true for all packets (0, 1, 2).
        verify(mockCc.onPacketAcked(0, sendTime0, Duration(milliseconds: 5), true, 2)).called(1); // Handshake packet
        verify(mockCc.onPacketAcked(1000, sendTime1, Duration(milliseconds: 5), true, 2)).called(1);
        verify(mockCc.onPacketAcked(1000, sendTime2, Duration(milliseconds: 5), true, 2)).called(1);

        // Verify processDuplicateAck is NOT called because this is a new cumulative ACK.
        verifyNever(mockCc.processDuplicateAck(any));

        // Verify stream's own _sentPackets map is updated
        expect(stream.getSentPacketsTestHook().containsKey(0), isFalse);
        expect(stream.getSentPacketsTestHook().containsKey(1), isFalse);
        expect(stream.getSentPacketsTestHook().containsKey(2), isFalse);

        // Verify 'ack' event emitted (optional, requires listener setup)
        // stream.on('ack').listen(expectAsync1((ackedSeq) { ... }, count: 2));
      });


      test('processes AckFrame with gaps, updates CC and PacketManager for relevant packets', () {
        final sendTime0 = DateTime.now().subtract(Duration(milliseconds: 110)); // Handshake packet
        final sendTime1 = DateTime.now().subtract(Duration(milliseconds: 100));
        final sendTime3 = DateTime.now().subtract(Duration(milliseconds: 80));
        final sendTime2 = DateTime.now().subtract(Duration(milliseconds: 90));
        setupStreamSentPackets({
          0: (sendTime0, 0),    // Handshake packet
          1: (sendTime1, 1200),
          2: (sendTime2, 1200), // Packet 2 will not be acked by this frame (lost/delayed)
          3: (sendTime3, 1200)
        });

        // Simulate packetManager.handleAckFrame reports 0, 1 and 3 as newly acked (gap at 2)
        when(mockPm.handleAckFrame(any)).thenReturn([0, 1, 3]);

        // ACK frame acknowledges: 0, 1, and 3 (with gap at 2)
        // First range: largestAcked=3, firstAckRangeLength=1 → acks only 3
        // Second range: gap=1 (skips 2), ackRangeLength=2 → acks 0 and 1
        final ackFrameWithGap = AckFrame(
          largestAcked: 3, 
          ackDelay: 8, 
          firstAckRangeLength: 1, // Acks 3
          ackRanges: [AckRange(gap: 1, ackRangeLength: 2)] // Skips 2, Acks 0 and 1
        );
        final incomingPacketWithGap = UDXPacket(
            destinationCid: ConnectionId.random(),
            sourceCid: ConnectionId.random(),
            destinationStreamId: 0, sourceStreamId: 1, sequence: 101, frames: [ackFrameWithGap]);

        final event = {
          'data': incomingPacketWithGap.toBytes(),
          'address': '127.0.0.1',
          'port': 12345,
        };
        stream.internalHandleSocketEvent(event);

        verify(mockPm.handleAckFrame(argThat(isA<AckFrame>()
          .having((f) => f.largestAcked, 'largestAcked', ackFrameWithGap.largestAcked)
          .having((f) => f.ackDelay, 'ackDelay', ackFrameWithGap.ackDelay)
          .having((f) => f.firstAckRangeLength, 'firstAckRangeLength', ackFrameWithGap.firstAckRangeLength)
          .having((f) => f.ackRanges, 'ackRanges', (ranges) {
            if (ranges is! List<AckRange> || ranges.length != ackFrameWithGap.ackRanges.length) return false;
            if (ranges.isEmpty) return true; // Both empty, matches
            // For this specific test, ackFrameWithGap.ackRanges has one element.
            // Compare its properties.
            final r1 = ranges.first;
            final r2 = ackFrameWithGap.ackRanges.first;
            return r1.gap == r2.gap && r1.ackRangeLength == r2.ackRangeLength;
          })
        ))).called(1);

        // With true cumulative ACK logic:
        // - Packets 0 and 1 are contiguously acknowledged, so cumulative ack advances to 1
        // - Packet 3 is acknowledged via SACK but beyond cumulative (gap at 2)
        // - Packet 0: isNewCumulativeForCC=true (within cumulative range 0..1)
        // - Packet 1: isNewCumulativeForCC=true (within cumulative range 0..1)
        // - Packet 3: isNewCumulativeForCC=false (3 > cumulative ack of 1)
        verify(mockCc.onPacketAcked(0, sendTime0, Duration(milliseconds: 8), true, 3)).called(1);
        verify(mockCc.onPacketAcked(1200, sendTime1, Duration(milliseconds: 8), true, 3)).called(1);
        verify(mockCc.onPacketAcked(1200, sendTime3, Duration(milliseconds: 8), false, 3)).called(1); // Beyond cumulative
        verifyNever(mockCc.onPacketAcked(any, argThat(equals(sendTime2)), any, any, any)); // Packet 2 not acked

        // processDuplicateAck is NOT called because the cumulative ACK did advance (from -1 to 1)
        verifyNever(mockCc.processDuplicateAck(any));

        expect(stream.getSentPacketsTestHook().containsKey(0), isFalse);
        expect(stream.getSentPacketsTestHook().containsKey(1), isFalse);
        expect(stream.getSentPacketsTestHook().containsKey(3), isFalse);
        expect(stream.getSentPacketsTestHook().containsKey(2), isTrue); // Packet 2 remains (lost/delayed)
      });
    });
  });
}
