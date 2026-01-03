import 'dart:typed_data';

import 'cid.dart';

/// UDX protocol version constants
class UdxVersion {
  /// Version 1 - Original implementation with fixed 8-byte CIDs
  static const int v1 = 0x00000001;

  /// Version 2 - Variable-length CIDs, enhanced QUIC compliance
  static const int v2 = 0x00000002;

  /// The current version used by this implementation
  static const int current = v2;

  /// List of all supported versions (in preference order)
  static const List<int> supportedVersions = [v2, v1];

  /// Checks if a version is supported
  static bool isSupported(int version) {
    return supportedVersions.contains(version);
  }

  /// Finds the highest common version between client and server
  static int? negotiateVersion(List<int> clientVersions) {
    for (final version in supportedVersions) {
      if (clientVersions.contains(version)) {
        return version;
      }
    }
    return null;
  }
}

/// A VERSION_NEGOTIATION packet sent by the server when client
/// requests an unsupported version.
class VersionNegotiationPacket {
  /// The destination Connection ID (from the client's initial packet)
  final ConnectionId destinationCid;

  /// The source Connection ID (from the client's initial packet)
  final ConnectionId sourceCid;

  /// List of supported versions offered by the server
  final List<int> supportedVersions;

  VersionNegotiationPacket({
    required this.destinationCid,
    required this.sourceCid,
    required this.supportedVersions,
  });

  /// Creates a VERSION_NEGOTIATION packet from raw bytes
  factory VersionNegotiationPacket.fromBytes(Uint8List bytes) {
    const minLength = 18; // version(4) + dcidLen(1) + scidLen(1) + seq(4) + destId(4) + srcId(4)
    if (bytes.length < minLength) {
      throw ArgumentError(
          'Byte array too short for VersionNegotiationPacket');
    }

    final view =
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);
    int offset = 0;

    // Read version (should be 0 for VERSION_NEGOTIATION)
    final version = view.getUint32(offset, Endian.big);
    if (version != 0) {
      throw ArgumentError('Invalid VERSION_NEGOTIATION packet (version != 0)');
    }
    offset += 4;

    // Read destination CID
    final destCidLength = view.getUint8(offset);
    offset += 1;
    final destCid = ConnectionId.fromUint8List(
        bytes.sublist(offset, offset + destCidLength));
    offset += destCidLength;

    // Read source CID
    final srcCidLength = view.getUint8(offset);
    offset += 1;
    final srcCid = ConnectionId.fromUint8List(
        bytes.sublist(offset, offset + srcCidLength));
    offset += srcCidLength;

    // Read supported versions (rest of packet is list of 4-byte version numbers)
    final versions = <int>[];
    while (offset + 4 <= bytes.length) {
      versions.add(view.getUint32(offset, Endian.big));
      offset += 4;
    }

    return VersionNegotiationPacket(
      destinationCid: destCid,
      sourceCid: srcCid,
      supportedVersions: versions,
    );
  }

  /// Converts the VERSION_NEGOTIATION packet to raw bytes
  Uint8List toBytes() {
    // version(4) + dcidLen(1) + dcid + scidLen(1) + scid + versions
    final headerLength =
        4 + 1 + destinationCid.length + 1 + sourceCid.length;
    final buffer = Uint8List(headerLength + (supportedVersions.length * 4));
    final view = ByteData.view(buffer.buffer);

    int offset = 0;

    // Write version (0 for VERSION_NEGOTIATION)
    view.setUint32(offset, 0, Endian.big);
    offset += 4;

    // Write destination CID
    view.setUint8(offset, destinationCid.length);
    offset += 1;
    buffer.setAll(offset, destinationCid.bytes);
    offset += destinationCid.length;

    // Write source CID
    view.setUint8(offset, sourceCid.length);
    offset += 1;
    buffer.setAll(offset, sourceCid.bytes);
    offset += sourceCid.length;

    // Write supported versions
    for (final version in supportedVersions) {
      view.setUint32(offset, version, Endian.big);
      offset += 4;
    }

    return buffer;
  }

  /// Checks if this VERSION_NEGOTIATION packet is valid
  bool isValid() {
    return supportedVersions.isNotEmpty &&
        destinationCid.length >= ConnectionId.minCidLength &&
        destinationCid.length <= ConnectionId.maxCidLength &&
        sourceCid.length >= ConnectionId.minCidLength &&
        sourceCid.length <= ConnectionId.maxCidLength;
  }
}

