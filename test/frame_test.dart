import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/packet.dart';

void main() {
  group('UDX Frame Serialization/Deserialization', () {
    test('serializes and deserializes a PADDING frame', () {
      final frame = PaddingFrame();
      final bytes = frame.toBytes();
      expect(bytes, equals(Uint8List.fromList([FrameType.padding.index])));

      final view = ByteData.view(bytes.buffer);
      final deserialized = Frame.fromBytes(view, 0);
      expect(deserialized, isA<PaddingFrame>());
      expect(deserialized.length, 1);
    });

    test('serializes and deserializes a PING frame', () {
      final frame = PingFrame();
      final bytes = frame.toBytes();
      expect(bytes, equals(Uint8List.fromList([FrameType.ping.index])));

      final view = ByteData.view(bytes.buffer);
      final deserialized = Frame.fromBytes(view, 0);
      expect(deserialized, isA<PingFrame>());
      expect(deserialized.length, 1);
    });

    group('AckFrame (Ranged)', () {
      test('serializes and deserializes an ACK frame with only first range', () {
        final frame = AckFrame(
          largestAcked: 100,
          ackDelay: 10, // 10 ms
          firstAckRangeLength: 5, // Acks 96, 97, 98, 99, 100
          ackRanges: [],
        );
        final bytes = frame.toBytes();
        final view = ByteData.view(bytes.buffer);
        final deserialized = Frame.fromBytes(view, 0) as AckFrame;

        expect(deserialized, isA<AckFrame>());
        expect(deserialized.largestAcked, equals(100));
        expect(deserialized.ackDelay, equals(10));
        expect(deserialized.firstAckRangeLength, equals(5));
        expect(deserialized.ackRanges, isEmpty);
        // Type (1) + LargestAcked (4) + AckDelay (2) + RangeCount (1) + FirstRangeLen (4)
        expect(deserialized.length, 1 + 4 + 2 + 1 + 4); 
        expect(bytes.length, deserialized.length);
      });

      test('serializes and deserializes an ACK frame with one additional range', () {
        final frame = AckFrame(
          largestAcked: 100,
          ackDelay: 15,
          firstAckRangeLength: 3, // Acks 98, 99, 100
          ackRanges: [
            AckRange(gap: 2, ackRangeLength: 2), // Acks 93, 94 (Gap of 97, 96, then 95 is acked by prev block, so gap is 2: 97, 96)
                                                 // Corrected: gap is from start of previous range (98).
                                                 // So, 98 - (gap=2) - 1 = 95. Range is 95, 94.
          ],
        );
        final bytes = frame.toBytes();
        final view = ByteData.view(bytes.buffer);
        final deserialized = Frame.fromBytes(view, 0) as AckFrame;

        expect(deserialized, isA<AckFrame>());
        expect(deserialized.largestAcked, equals(100));
        expect(deserialized.ackDelay, equals(15));
        expect(deserialized.firstAckRangeLength, equals(3));
        expect(deserialized.ackRanges.length, 1);
        expect(deserialized.ackRanges[0].gap, equals(2));
        expect(deserialized.ackRanges[0].ackRangeLength, equals(2));
        // Base (12) + 1 range * (Gap(1) + Len(4) = 5)
        expect(deserialized.length, 1 + 4 + 2 + 1 + 4 + 5);
        expect(bytes.length, deserialized.length);
      });

      test('serializes and deserializes an ACK frame with multiple additional ranges', () {
        final frame = AckFrame(
          largestAcked: 200,
          ackDelay: 20,
          firstAckRangeLength: 2, // Acks 199, 200
          ackRanges: [
            AckRange(gap: 1, ackRangeLength: 3), // Range before: 199. Gap 1 means 198 is not acked. Range starts 197. Acks 197, 196, 195.
            AckRange(gap: 4, ackRangeLength: 5), // Range before: 195. Gap 4 means 194,193,192,191 not acked. Range starts 190. Acks 190..186
          ],
        );
        final bytes = frame.toBytes();
        final view = ByteData.view(bytes.buffer);
        final deserialized = Frame.fromBytes(view, 0) as AckFrame;

        expect(deserialized, isA<AckFrame>());
        expect(deserialized.largestAcked, equals(200));
        expect(deserialized.ackDelay, equals(20));
        expect(deserialized.firstAckRangeLength, equals(2));
        expect(deserialized.ackRanges.length, 2);
        expect(deserialized.ackRanges[0].gap, equals(1));
        expect(deserialized.ackRanges[0].ackRangeLength, equals(3));
        expect(deserialized.ackRanges[1].gap, equals(4));
        expect(deserialized.ackRanges[1].ackRangeLength, equals(5));
        // Base (12) + 2 ranges * 5 bytes/range
        expect(deserialized.length, 1 + 4 + 2 + 1 + 4 + (2 * 5));
        expect(bytes.length, deserialized.length);
      });
    });

    test('serializes and deserializes a STREAM frame with FIN flag', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final frame = StreamFrame(data: data, isFin: true, isSyn: false);
      final bytes = frame.toBytes();
      final view = ByteData.view(bytes.buffer);
      final deserialized = Frame.fromBytes(view, 0) as StreamFrame;

      expect(deserialized, isA<StreamFrame>());
      expect(deserialized.data, equals(data));
      expect(deserialized.isFin, isTrue);
      expect(deserialized.isSyn, isFalse);
      expect(deserialized.length, 1 + 1 + 2 + data.length);
    });

    test('serializes and deserializes a STREAM frame with SYN flag', () {
      final data = Uint8List.fromList([6, 7, 8]);
      final frame = StreamFrame(data: data, isFin: false, isSyn: true);
      final bytes = frame.toBytes();
      final view = ByteData.view(bytes.buffer);
      final deserialized = Frame.fromBytes(view, 0) as StreamFrame;

      expect(deserialized, isA<StreamFrame>());
      expect(deserialized.data, equals(data));
      expect(deserialized.isFin, isFalse);
      expect(deserialized.isSyn, isTrue);
    });

    test('serializes and deserializes a STREAM frame with both SYN and FIN flags', () {
      final data = Uint8List.fromList([]);
      final frame = StreamFrame(data: data, isFin: true, isSyn: true);
      final bytes = frame.toBytes();
      final view = ByteData.view(bytes.buffer);
      final deserialized = Frame.fromBytes(view, 0) as StreamFrame;

      expect(deserialized, isA<StreamFrame>());
      expect(deserialized.data, isEmpty);
      expect(deserialized.isFin, isTrue);
      expect(deserialized.isSyn, isTrue);
    });

    test('correctly deserializes a sequence of frames from a UDXPacket', () {
      final destCid = ConnectionId.random();
      final srcCid = ConnectionId.random();
      final packet = UDXPacket(
        destinationCid: destCid,
        sourceCid: srcCid,
        destinationStreamId: 1,
        sourceStreamId: 2,
        sequence: 3,
        frames: [
          PingFrame(),
          StreamFrame(data: Uint8List.fromList([10, 20])),
          AckFrame(largestAcked: 1, ackDelay: 0, firstAckRangeLength: 1) // Minimal valid ranged AckFrame
        ],
      );

      final bytes = packet.toBytes();
      final deserializedPacket = UDXPacket.fromBytes(bytes);

      expect(deserializedPacket.destinationCid, equals(destCid));
      expect(deserializedPacket.sourceCid, equals(srcCid));
      expect(deserializedPacket.frames.length, 3);
      expect(deserializedPacket.frames[0], isA<PingFrame>());
      expect(deserializedPacket.frames[1], isA<StreamFrame>());
      expect(deserializedPacket.frames[2], isA<AckFrame>());

      final streamFrame = deserializedPacket.frames[1] as StreamFrame;
      expect(streamFrame.data, equals(Uint8List.fromList([10, 20])));

      final ackFrame = deserializedPacket.frames[2] as AckFrame;
      expect(ackFrame.largestAcked, equals(1));
      expect(ackFrame.firstAckRangeLength, equals(1));
      expect(ackFrame.ackRanges, isEmpty);
    });

    test('serializes and deserializes a MAX_STREAMS frame', () {
      final frame = MaxStreamsFrame(maxStreamCount: 50);
      final bytes = frame.toBytes();
      final view = ByteData.view(bytes.buffer);
      final deserialized = Frame.fromBytes(view, 0) as MaxStreamsFrame;

      expect(deserialized, isA<MaxStreamsFrame>());
      expect(deserialized.maxStreamCount, equals(50));
      expect(deserialized.length, 1 + 4);
      expect(bytes.length, deserialized.length);
    });
  });
}
