import 'dart:math';
import 'dart:typed_data';
import 'package:collection/collection.dart';

/// Represents a UDX Connection Identifier (CID).
///
/// CIDs are used to identify a UDX connection independently of the
/// underlying network path (IP address and port).
///
/// Per QUIC specification, CIDs can be 0-20 bytes in length.
class ConnectionId {
  /// The byte representation of the CID.
  final Uint8List _bytes;

  /// The minimum length of a CID in bytes.
  static const int minCidLength = 0;

  /// The maximum length of a CID in bytes.
  static const int maxCidLength = 20;

  /// The default length for generated CIDs (for backward compatibility).
  static const int defaultCidLength = 8;

  /// Creates a ConnectionId from a list of bytes.
  ///
  /// Throws an [ArgumentError] if the length of [bytes] is not
  /// within the valid range [minCidLength, maxCidLength].
  ConnectionId(List<int> bytes) : _bytes = Uint8List.fromList(bytes) {
    if (_bytes.length < minCidLength || _bytes.length > maxCidLength) {
      throw ArgumentError(
        'ConnectionId must be between $minCidLength and $maxCidLength bytes long, got ${_bytes.length}');
    }
  }

  /// Creates a ConnectionId from a [Uint8List].
  ///
  /// This is a more efficient constructor if you already have a [Uint8List].
  /// Throws an [ArgumentError] if the length of [bytes] is not
  /// within the valid range [minCidLength, maxCidLength].
  ConnectionId.fromUint8List(this._bytes) {
    if (_bytes.length < minCidLength || _bytes.length > maxCidLength) {
      throw ArgumentError(
        'ConnectionId must be between $minCidLength and $maxCidLength bytes long, got ${_bytes.length}');
    }
  }

  /// Generates a new random ConnectionId with the default length.
  factory ConnectionId.random({int length = defaultCidLength}) {
    if (length < minCidLength || length > maxCidLength) {
      throw ArgumentError(
        'ConnectionId length must be between $minCidLength and $maxCidLength, got $length');
    }
    final random = Random.secure();
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return ConnectionId.fromUint8List(bytes);
  }

  /// Returns the length of this CID in bytes.
  int get length => _bytes.length;

  /// Returns the bytes of the CID.
  Uint8List get bytes => _bytes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConnectionId &&
          const ListEquality<int>().equals(_bytes, other._bytes);

  @override
  int get hashCode => const ListEquality<int>().hash(_bytes);

  @override
  String toString() {
    return 'CID(${_bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()})';
  }
}

/// A public class to hold the local and remote CIDs for a connection.
class ConnectionCids {
  ConnectionId localCid;
  ConnectionId remoteCid;

  ConnectionCids(this.localCid, this.remoteCid);
}
