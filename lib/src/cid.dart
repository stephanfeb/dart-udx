import 'dart:math';
import 'dart:typed_data';
import 'package:collection/collection.dart';

/// Represents a UDX Connection Identifier (CID).
///
/// CIDs are used to identify a UDX connection independently of the
/// underlying network path (IP address and port).
class ConnectionId {
  /// The byte representation of the CID.
  final Uint8List _bytes;

  /// The length of the CID in bytes.
  static const int cidLength = 8;

  /// Creates a ConnectionId from a list of bytes.
  ///
  /// Throws an [ArgumentError] if the length of [bytes] is not
  /// equal to [cidLength].
  ConnectionId(List<int> bytes) : _bytes = Uint8List.fromList(bytes) {
    if (_bytes.length != cidLength) {
      throw ArgumentError('ConnectionId must be $cidLength bytes long');
    }
  }

  /// Creates a ConnectionId from a [Uint8List].
  ///
  /// This is a more efficient constructor if you already have a [Uint8List].
  /// Throws an [ArgumentError] if the length of [bytes] is not
  /// equal to [cidLength].
  ConnectionId.fromUint8List(this._bytes) {
    if (_bytes.length != cidLength) {
      throw ArgumentError('ConnectionId must be $cidLength bytes long');
    }
  }

  /// Generates a new random ConnectionId.
  factory ConnectionId.random() {
    final random = Random.secure();
    final bytes = Uint8List(cidLength);
    for (int i = 0; i < cidLength; i++) {
      bytes[i] = random.nextInt(256);
    }
    return ConnectionId.fromUint8List(bytes);
  }

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
