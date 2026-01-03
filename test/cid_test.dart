import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:dart_udx/src/cid.dart';

void main() {
  group('ConnectionId', () {
    test('should create a ConnectionId from a list of bytes', () {
      final bytes = [0, 1, 2, 3, 4, 5, 6, 7];
      final cid = ConnectionId(bytes);
      expect(cid.bytes, equals(Uint8List.fromList(bytes)));
    });

    test('should throw an error if byte list has incorrect length', () {
      // CIDs must be between 0-20 bytes
      final tooLongBytes = List.generate(21, (i) => i);
      expect(() => ConnectionId(tooLongBytes), throwsArgumentError);
    });

    test('should accept variable-length CIDs within valid range', () {
      // Test 0-byte CID
      final cid0 = ConnectionId([]);
      expect(cid0.length, equals(0));
      
      // Test 8-byte CID (default)
      final cid8 = ConnectionId([0, 1, 2, 3, 4, 5, 6, 7]);
      expect(cid8.length, equals(8));
      
      // Test 20-byte CID (max)
      final cid20 = ConnectionId(List.generate(20, (i) => i));
      expect(cid20.length, equals(20));
    });

    test('should generate a random ConnectionId with correct length', () {
      final cid = ConnectionId.random();
      expect(cid.bytes.length, equals(ConnectionId.defaultCidLength));
    });

    test('should generate two different random ConnectionIds', () {
      final cid1 = ConnectionId.random();
      final cid2 = ConnectionId.random();
      expect(cid1, isNot(equals(cid2)));
    });

    test('should correctly compare two ConnectionIds for equality', () {
      final bytes1 = [0, 1, 2, 3, 4, 5, 6, 7];
      final bytes2 = [0, 1, 2, 3, 4, 5, 6, 7];
      final bytes3 = [7, 6, 5, 4, 3, 2, 1, 0];

      final cid1 = ConnectionId(bytes1);
      final cid2 = ConnectionId(bytes2);
      final cid3 = ConnectionId(bytes3);

      expect(cid1, equals(cid2));
      expect(cid1, isNot(equals(cid3)));
    });

    test('should have the same hashCode for equal ConnectionIds', () {
      final bytes1 = [0, 1, 2, 3, 4, 5, 6, 7];
      final bytes2 = [0, 1, 2, 3, 4, 5, 6, 7];
      final bytes3 = [7, 6, 5, 4, 3, 2, 1, 0];

      final cid1 = ConnectionId(bytes1);
      final cid2 = ConnectionId(bytes2);
      final cid3 = ConnectionId(bytes3);

      expect(cid1.hashCode, equals(cid2.hashCode));
      expect(cid1.hashCode, isNot(equals(cid3.hashCode)));
    });

    test('should work correctly as a key in a Map', () {
      final cid1 = ConnectionId([1, 2, 3, 4, 5, 6, 7, 8]);
      final cid2 = ConnectionId([1, 2, 3, 4, 5, 6, 7, 8]);
      final cid3 = ConnectionId.random();

      final map = <ConnectionId, String>{};
      map[cid1] = 'value1';

      expect(map.containsKey(cid1), isTrue);
      expect(map.containsKey(cid2), isTrue);
      expect(map[cid2], equals('value1'));
      expect(map.containsKey(cid3), isFalse);
    });
  });
}
