import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:collection/collection.dart';

import 'cid.dart';
import 'clock.dart';
import 'congestion.dart';
import 'version.dart';

// --- Frame Definitions ---

/// Frame types and their type bytes on the wire.
///
/// The codes are explicit and match go-udx, which leaves 0x0c unused. They
/// used to be the enum's index, which has no gap, so every type from
/// stopSending up was one lower than go-udx's: go-udx and js-udx rejected
/// this side's STOP_SENDING, and this side misread their STREAM_DATA_BLOCKED
/// (0x0f) as NEW_CONNECTION_ID and dropped the packet, losing the recovery
/// for a dropped WINDOW_UPDATE.
enum FrameType {
  padding(0x00),
  ping(0x01),
  ack(0x02),
  stream(0x03),
  windowUpdate(0x04),
  maxData(0x05), // Connection-level flow control
  resetStream(0x06), // Abrupt stream termination
  maxStreams(0x07),
  mtuProbe(0x08), // Path MTU Discovery
  pathChallenge(0x09),
  pathResponse(0x0a),
  connectionClose(0x0b), // Graceful connection termination with error details
  // 0x0c is unused.
  stopSending(0x0d), // Request peer to stop sending on a stream
  dataBlocked(0x0e), // Connection-level flow control blocked
  streamDataBlocked(0x0f), // Stream-level flow control blocked
  newConnectionId(0x10), // Provides a new CID that the peer can use
  retireConnectionId(0x11); // Requests retirement of a previously issued CID

  const FrameType(this.code);

  /// The type byte on the wire.
  final int code;

  static final Map<int, FrameType> _byCode = {for (final t in values) t.code: t};

  /// The frame type for a type byte, or null if there is none.
  static FrameType? fromCode(int code) => _byCode[code];
}

/// Base class for all UDX frames.
abstract class Frame {
  final FrameType type;

  Frame(this.type);

  /// Serialize the frame into a byte list.
  Uint8List toBytes();

  /// Calculate the length of the serialized frame.
  int get length;

  /// A factory constructor to deserialize a frame from bytes.
  static Frame fromBytes(ByteData view, int offset) {
    final code = view.getUint8(offset);
    final type = FrameType.fromCode(code);
    if (type == null) {
      throw ArgumentError('Unknown frame type: $code');
    }
    switch (type) {
      case FrameType.padding:
        return PaddingFrame.fromBytes(view, offset);
      case FrameType.ping:
        return PingFrame.fromBytes(view, offset);
      case FrameType.ack:
        return AckFrame.fromBytes(view, offset);
      case FrameType.stream:
        return StreamFrame.fromBytes(view, offset);
      case FrameType.windowUpdate:
        return WindowUpdateFrame.fromBytes(view, offset);
      case FrameType.maxData:
        return MaxDataFrame.fromBytes(view, offset);
      case FrameType.resetStream:
        return ResetStreamFrame.fromBytes(view, offset);
      case FrameType.maxStreams:
        return MaxStreamsFrame.fromBytes(view, offset);
      case FrameType.mtuProbe:
        return MtuProbeFrame.fromBytes(view, offset);
      case FrameType.pathChallenge:
        return PathChallengeFrame.fromBytes(view, offset);
      case FrameType.pathResponse:
        return PathResponseFrame.fromBytes(view, offset);
      case FrameType.connectionClose:
        return ConnectionCloseFrame.fromBytes(view, offset);
      case FrameType.stopSending:
        return StopSendingFrame.fromBytes(view, offset);
      case FrameType.dataBlocked:
        return DataBlockedFrame.fromBytes(view, offset);
      case FrameType.streamDataBlocked:
        return StreamDataBlockedFrame.fromBytes(view, offset);
      case FrameType.newConnectionId:
        return NewConnectionIdFrame.fromBytes(view, offset);
      case FrameType.retireConnectionId:
        return RetireConnectionIdFrame.fromBytes(view, offset);
    }
  }
}

/// PADDING Frame (Type 0x00)
/// Used to ensure a packet has a minimum size.
class PaddingFrame extends Frame {
  PaddingFrame() : super(FrameType.padding);

  @override
  int get length => 1;

  @override
  Uint8List toBytes() {
    return Uint8List.fromList([FrameType.padding.code]);
  }

  static PaddingFrame fromBytes(ByteData view, int offset) {
    return PaddingFrame();
  }
}

/// PING Frame (Type 0x01)
/// Used to elicit an ACK from the peer.
class PingFrame extends Frame {
  PingFrame() : super(FrameType.ping);

  @override
  int get length => 1;

  @override
  Uint8List toBytes() {
    return Uint8List.fromList([FrameType.ping.code]);
  }

  static PingFrame fromBytes(ByteData view, int offset) {
    return PingFrame();
  }
}

/// Helper class for ACK ranges in an AckFrame.
class AckRange {
  final int gap; // Number of unacknowledged packets preceding this range.
  final int ackRangeLength; // Number of acknowledged packets in this range.

  AckRange({required this.gap, required this.ackRangeLength});
}

/// ACK Frame (Type 0x02)
/// Acknowledges one or more packet ranges.
/// Based on QUIC ACK Frame (RFC 9000, Section 19.3).
/// Includes optional ECN counts for Explicit Congestion Notification.
class AckFrame extends Frame {
  final int largestAcked;
  final int ackDelay; // In milliseconds
  final int firstAckRangeLength; // Number of contiguous packets ending at largestAcked
  final List<AckRange> ackRanges; // Additional non-contiguous ranges
  
  // Optional ECN counts (RFC 9000 Section 19.3.2)
  // These are counts of packets received with ECN markings
  final int? ect0Count;  // ECT(0) - ECN Capable Transport(0)
  final int? ect1Count;  // ECT(1) - ECN Capable Transport(1)
  final int? ceCount;    // CE - Congestion Experienced

  AckFrame({
    required this.largestAcked,
    required this.ackDelay,
    required this.firstAckRangeLength,
    this.ackRanges = const [],
    this.ect0Count,
    this.ect1Count,
    this.ceCount,
  }) : super(FrameType.ack);

  /// The largest gap the one-byte gap field can carry.
  static const int maxGap = 255;

  /// The most additional ranges the one-byte range count can carry.
  static const int maxRanges = 255;

  /// Builds the ACK for a set of received sequences: the run ending at the
  /// largest, then (gap, run) pairs walking down.
  ///
  /// It stops at a gap wider than [maxGap] or after [maxRanges] ranges, leaving
  /// the older ranges out. Leaving a range out only costs the sender a
  /// retransmission; encoding it truncated (a 290-packet gap written as 34)
  /// acknowledges sequences that never arrived, so the sender stops tracking
  /// them and never re-sends them.
  factory AckFrame.fromReceived(Iterable<int> sequences, {int ackDelay = 0}) {
    final sorted = sequences.toSet().toList()..sort();
    if (sorted.isEmpty) {
      throw ArgumentError('An ACK needs at least one received sequence');
    }
    // Contiguous runs, highest first.
    final runs = <List<int>>[]; // [start, end]
    var end = sorted.last;
    var start = end;
    for (var i = sorted.length - 2; i >= 0; i--) {
      if (sorted[i] == start - 1) {
        start = sorted[i];
      } else {
        runs.add([start, end]);
        end = sorted[i];
        start = end;
      }
    }
    runs.add([start, end]);

    final ranges = <AckRange>[];
    var prevStart = runs.first[0];
    for (final run in runs.skip(1)) {
      final gap = prevStart - run[1] - 1;
      if (gap > maxGap || ranges.length == maxRanges) break;
      ranges.add(AckRange(gap: gap, ackRangeLength: run[1] - run[0] + 1));
      prevStart = run[0];
    }
    return AckFrame(
      largestAcked: sorted.last,
      ackDelay: ackDelay,
      firstAckRangeLength: runs.first[1] - runs.first[0] + 1,
      ackRanges: ranges,
    );
  }

  @override
  int get length {
    // Type (1)
    // Largest Acked (4)
    // ACK Delay (2)
    // ACK Range Count (1)
    // First ACK Range Length (4)
    // Each additional ACK Range: Gap (1) + ACK Range Length (4) = 5 bytes
    int baseLength = 1 + 4 + 2 + 1 + 4 + (ackRanges.length * (1 + 4));
    
    // Add ECN counts if present (8 bytes each)
    if (ect0Count != null || ect1Count != null || ceCount != null) {
      baseLength += 1; // ECN flag byte
      if (ect0Count != null) baseLength += 8;
      if (ect1Count != null) baseLength += 8;
      if (ceCount != null) baseLength += 8;
    }
    
    return baseLength;
  }

  @override
  Uint8List toBytes() {
    final buffer = Uint8List(length);
    final view = ByteData.view(buffer.buffer);
    int offset = 0;

    view.setUint8(offset, FrameType.ack.code);
    offset += 1;

    view.setUint32(offset, largestAcked, Endian.big);
    offset += 4;

    view.setUint16(offset, ackDelay, Endian.big);
    offset += 2;

    // One-byte fields: a value that doesn't fit would be truncated into an ACK
    // for sequences that never arrived, so refuse it (see fromReceived).
    if (ackRanges.length > maxRanges || ackRanges.any((r) => r.gap > maxGap)) {
      throw ArgumentError('ACK range count or gap does not fit its one-byte field');
    }
    view.setUint8(offset, ackRanges.length); // Count of *additional* ranges
    offset += 1;

    view.setUint32(offset, firstAckRangeLength, Endian.big);
    offset += 4;

    for (final range in ackRanges) {
      view.setUint8(offset, range.gap);
      offset += 1;
      view.setUint32(offset, range.ackRangeLength, Endian.big);
      offset += 4;
    }
    return buffer;
  }

  static AckFrame fromBytes(ByteData view, int offset) {
    int currentOffset = offset;

    // Skip type, already handled by Frame.fromBytes
    currentOffset += 1; 

    final largestAcked = view.getUint32(currentOffset, Endian.big);
    currentOffset += 4;

    final ackDelay = view.getUint16(currentOffset, Endian.big);
    currentOffset += 2;

    final ackRangeCount = view.getUint8(currentOffset);
    currentOffset += 1;

    final firstAckRangeLength = view.getUint32(currentOffset, Endian.big);
    currentOffset += 4;

    final ranges = <AckRange>[];
    for (int i = 0; i < ackRangeCount; i++) {
      final gap = view.getUint8(currentOffset);
      currentOffset += 1;
      final length = view.getUint32(currentOffset, Endian.big);
      currentOffset += 4;
      ranges.add(AckRange(gap: gap, ackRangeLength: length));
    }

    return AckFrame(
      largestAcked: largestAcked,
      ackDelay: ackDelay,
      firstAckRangeLength: firstAckRangeLength,
      ackRanges: ranges,
    );
  }
}

/// STREAM Frame (Type 0x03)
/// Carries data for a specific stream.
class StreamFrame extends Frame {
  final bool isFin;
  final bool isSyn;

  /// Position of [data] within this stream's own byte sequence.
  ///
  /// This is what the receiver reassembles on. Delivery order used to come from
  /// the packet's sequence number, which is allocated per connection, so a gap
  /// anywhere stalled every stream sharing that connection rather than only the
  /// one actually missing bytes. Addressing the bytes directly decouples them.
  ///
  /// On a FIN the offset is the stream's final size, so a FIN that overtakes
  /// data still in flight does not truncate the tail.
  final int offset;

  final Uint8List data;

  StreamFrame({
    this.isFin = false,
    this.isSyn = false,
    this.offset = 0,
    required this.data,
  }) : super(FrameType.stream);

  /// Type (1) + Flags (1) + Offset (8) + Length (2) + Data (variable)
  static const int headerLength = 12;

  @override
  int get length => headerLength + data.length;

  @override
  Uint8List toBytes() {
    final buffer = Uint8List(length);
    final view = ByteData.view(buffer.buffer);
    view.setUint8(0, FrameType.stream.code);
    int flags = 0;
    if (isFin) flags |= 0x01;
    if (isSyn) flags |= 0x02;
    view.setUint8(1, flags);
    view.setUint64(2, offset, Endian.big);
    view.setUint16(10, data.length, Endian.big);
    buffer.setAll(headerLength, data);
    return buffer;
  }

  static StreamFrame fromBytes(ByteData view, int offset) {
    final flags = view.getUint8(offset + 1);
    final isFin = (flags & 0x01) != 0;
    final isSyn = (flags & 0x02) != 0;
    final streamOffset = view.getUint64(offset + 2, Endian.big);
    final dataLength = view.getUint16(offset + 10, Endian.big);
    final data = Uint8List.view(
        view.buffer, view.offsetInBytes + offset + headerLength, dataLength);
    return StreamFrame(
        isFin: isFin, isSyn: isSyn, offset: streamOffset, data: data);
  }
}

/// WINDOW_UPDATE Frame (Type 0x04)
/// Informs the peer of a change in the sender's receive window.
class WindowUpdateFrame extends Frame {
  final int windowSize;

  WindowUpdateFrame({required this.windowSize}) : super(FrameType.windowUpdate);

  @override
  int get length => 1 + 4; // Type + Window Size

  @override
  Uint8List toBytes() {
    final buffer = Uint8List(length);
    final view = ByteData.view(buffer.buffer);
    view.setUint8(0, FrameType.windowUpdate.code);
    view.setUint32(1, windowSize, Endian.big);
    return buffer;
  }

  static WindowUpdateFrame fromBytes(ByteData view, int offset) {
    final windowSize = view.getUint32(offset + 1, Endian.big);
    return WindowUpdateFrame(windowSize: windowSize);
  }
}

/// MAX_DATA Frame (Type 0x05)
/// Informs the peer of the maximum amount of data that can be sent on the connection.
class MaxDataFrame extends Frame {
  final int maxData; // Using Dart's int, which is 64-bit.

  MaxDataFrame({required this.maxData}) : super(FrameType.maxData);

  @override
  int get length => 1 + 8; // Type (1 byte) + Max Data (8 bytes for Uint64)

  @override
  Uint8List toBytes() {
    final buffer = Uint8List(length);
    final view = ByteData.view(buffer.buffer);
    view.setUint8(0, FrameType.maxData.code);
    view.setUint64(1, maxData, Endian.big);
    return buffer;
  }

  static MaxDataFrame fromBytes(ByteData view, int offset) {
    // Ensure there's enough data for type (1) + maxData (8)
    if (view.lengthInBytes < offset + 1 + 8) {
      throw ArgumentError('Byte array too short for MaxDataFrame at offset $offset. Need ${1 + 8} bytes, got ${view.lengthInBytes - offset}');
    }
    final maxData = view.getUint64(offset + 1, Endian.big);
    return MaxDataFrame(maxData: maxData);
  }
}

/// RESET_STREAM Frame (Type 0x06)
/// Informs the peer that a stream is being abruptly terminated.
class ResetStreamFrame extends Frame {
  final int errorCode;

  ResetStreamFrame({required this.errorCode}) : super(FrameType.resetStream);

  @override
  int get length => 1 + 4; // Type (1) + Error Code (4)

  @override
  Uint8List toBytes() {
    final buffer = Uint8List(length);
    final view = ByteData.view(buffer.buffer);
    view.setUint8(0, FrameType.resetStream.code);
    view.setUint32(1, errorCode, Endian.big);
    return buffer;
  }

  static ResetStreamFrame fromBytes(ByteData view, int offset) {
    final errorCode = view.getUint32(offset + 1, Endian.big);
    return ResetStreamFrame(errorCode: errorCode);
  }
}

/// MAX_STREAMS Frame (Type 0x07)
/// Informs the peer of the maximum number of concurrent streams the sender is willing to accept.
class MaxStreamsFrame extends Frame {
  final int maxStreamCount;

  MaxStreamsFrame({required this.maxStreamCount}) : super(FrameType.maxStreams);

  @override
  int get length => 1 + 4; // Type (1) + Stream Count (4)

  @override
  Uint8List toBytes() {
    final buffer = Uint8List(length);
    final view = ByteData.view(buffer.buffer);
    view.setUint8(0, FrameType.maxStreams.code);
    view.setUint32(1, maxStreamCount, Endian.big);
    return buffer;
  }

  static MaxStreamsFrame fromBytes(ByteData view, int offset) {
    final maxStreamCount = view.getUint32(offset + 1, Endian.big);
    return MaxStreamsFrame(maxStreamCount: maxStreamCount);
  }
}

/// MTU_PROBE Frame (Type 0x08)
/// Used for DPLPMTUD (RFC 8899). This frame is used to pad a packet to a
/// specific size to probe if the path supports a larger MTU.
class MtuProbeFrame extends Frame {
  final int probeSize;

  MtuProbeFrame({required this.probeSize}) : super(FrameType.mtuProbe);

  @override
  int get length => probeSize;

  @override
  Uint8List toBytes() {
    final buffer = Uint8List(length);
    final view = ByteData.view(buffer.buffer);
    view.setUint8(0, FrameType.mtuProbe.code);
    // The rest of the frame is padding, which is implicitly zeros.
    return buffer;
  }

  /// The probe is the rest of the packet: its type byte and the padding
  /// after it. (Reading it as one byte left the padding to be parsed as a
  /// thousand PADDING frames.)
  static MtuProbeFrame fromBytes(ByteData view, int offset) {
    return MtuProbeFrame(probeSize: view.lengthInBytes - offset);
  }
}

/// PATH_CHALLENGE Frame (Type 0x09)
/// Used to validate a new network path during connection migration.
/// Contains arbitrary data that the peer must echo back.
class PathChallengeFrame extends Frame {
  final Uint8List data; // Should be 8 bytes

  PathChallengeFrame({required this.data}) : super(FrameType.pathChallenge) {
    if (data.length != 8) {
      throw ArgumentError('PathChallengeFrame data must be 8 bytes long.');
    }
  }

  @override
  int get length => 1 + 8; // Type (1) + Data (8)

  @override
  Uint8List toBytes() {
    final buffer = Uint8List(length);
    buffer[0] = FrameType.pathChallenge.code;
    buffer.setAll(1, data);
    return buffer;
  }

  static PathChallengeFrame fromBytes(ByteData view, int offset) {
    final data = Uint8List.view(view.buffer, view.offsetInBytes + offset + 1, 8);
    return PathChallengeFrame(data: data);
  }
}

/// PATH_RESPONSE Frame (Type 0x0a)
/// Used to respond to a PATH_CHALLENGE. Must contain the exact same
/// data as the challenge frame it is responding to.
class PathResponseFrame extends Frame {
  final Uint8List data; // Should be 8 bytes, echoing the challenge

  PathResponseFrame({required this.data}) : super(FrameType.pathResponse) {
    if (data.length != 8) {
      throw ArgumentError('PathResponseFrame data must be 8 bytes long.');
    }
  }

  @override
  int get length => 1 + 8; // Type (1) + Data (8)

  @override
  Uint8List toBytes() {
    final buffer = Uint8List(length);
    buffer[0] = FrameType.pathResponse.code;
    buffer.setAll(1, data);
    return buffer;
  }

  static PathResponseFrame fromBytes(ByteData view, int offset) {
    final data = Uint8List.view(view.buffer, view.offsetInBytes + offset + 1, 8);
    return PathResponseFrame(data: data);
  }
}

/// UDX error codes for CONNECTION_CLOSE and RESET_STREAM frames
class UdxErrorCode {
  /// No error (graceful close)
  static const int noError = 0x00;
  
  /// Internal error
  static const int internalError = 0x01;
  
  /// Stream limit exceeded
  static const int streamLimitError = 0x02;
  
  /// Flow control error
  static const int flowControlError = 0x03;
  
  /// Protocol violation
  static const int protocolViolation = 0x04;
  
  /// Invalid connection migration
  static const int invalidMigration = 0x05;
  
  /// Connection timeout
  static const int connectionTimeout = 0x06;
}

/// CONNECTION_CLOSE Frame (Type 0x0b)
/// Signals graceful or error termination of the connection.
/// Contains error code, frame type that caused error (if applicable),
/// and a human-readable reason phrase.
class ConnectionCloseFrame extends Frame {
  final int errorCode;        // 4 bytes
  final int frameType;        // 4 bytes - which frame type caused error (0 if N/A)
  final String reasonPhrase;  // Variable length

  ConnectionCloseFrame({
    required this.errorCode,
    this.frameType = 0,
    this.reasonPhrase = '',
  }) : super(FrameType.connectionClose);

  @override
  int get length {
    // Type (1) + Error Code (4) + Frame Type (4) + Reason Length (2) + Reason
    return 1 + 4 + 4 + 2 + reasonPhrase.length;
  }

  @override
  Uint8List toBytes() {
    final reasonBytes = reasonPhrase.codeUnits;
    final buffer = Uint8List(length);
    final view = ByteData.view(buffer.buffer);
    
    int offset = 0;
    view.setUint8(offset, FrameType.connectionClose.code);
    offset += 1;
    
    view.setUint32(offset, errorCode, Endian.big);
    offset += 4;
    
    view.setUint32(offset, frameType, Endian.big);
    offset += 4;
    
    view.setUint16(offset, reasonBytes.length, Endian.big);
    offset += 2;
    
    buffer.setAll(offset, reasonBytes);
    
    return buffer;
  }

  static ConnectionCloseFrame fromBytes(ByteData view, int offset) {
    int currentOffset = offset;
    
    // Skip type byte
    currentOffset += 1;
    
    final errorCode = view.getUint32(currentOffset, Endian.big);
    currentOffset += 4;
    
    final frameType = view.getUint32(currentOffset, Endian.big);
    currentOffset += 4;
    
    final reasonLength = view.getUint16(currentOffset, Endian.big);
    currentOffset += 2;
    
    final reasonBytes = Uint8List.view(
      view.buffer,
      view.offsetInBytes + currentOffset,
      reasonLength
    );
    final reasonPhrase = String.fromCharCodes(reasonBytes);
    
    return ConnectionCloseFrame(
      errorCode: errorCode,
      frameType: frameType,
      reasonPhrase: reasonPhrase,
    );
  }
}

/// STOP_SENDING Frame (Type 0x0d)
/// Signals that the endpoint no longer wishes to receive data on a stream.
/// The peer should close the write side of the stream in response.
class StopSendingFrame extends Frame {
  final int streamId;   // 4 bytes
  final int errorCode;  // 4 bytes
  
  StopSendingFrame({
    required this.streamId,
    required this.errorCode,
  }) : super(FrameType.stopSending);
  
  @override
  int get length => 1 + 4 + 4; // Type + Stream ID + Error Code
  
  @override
  Uint8List toBytes() {
    final buffer = Uint8List(length);
    final view = ByteData.view(buffer.buffer);
    
    view.setUint8(0, FrameType.stopSending.code);
    view.setUint32(1, streamId, Endian.big);
    view.setUint32(5, errorCode, Endian.big);
    
    return buffer;
  }
  
  static StopSendingFrame fromBytes(ByteData view, int offset) {
    final streamId = view.getUint32(offset + 1, Endian.big);
    final errorCode = view.getUint32(offset + 5, Endian.big);
    
    return StopSendingFrame(
      streamId: streamId,
      errorCode: errorCode,
    );
  }
}

/// DATA_BLOCKED Frame (Type 0x0e)
/// Indicates that the connection is blocked due to connection-level
/// flow control. Sent when the sender wants to send data but is blocked
/// by the connection-level MAX_DATA limit.
class DataBlockedFrame extends Frame {
  final int maxData; // The connection-level data limit at which blocking occurred
  
  DataBlockedFrame({
    required this.maxData,
  }) : super(FrameType.dataBlocked);
  
  @override
  int get length => 1 + 8; // Type + Max Data (8 bytes)
  
  @override
  Uint8List toBytes() {
    final buffer = Uint8List(length);
    final view = ByteData.view(buffer.buffer);
    
    view.setUint8(0, FrameType.dataBlocked.code);
    view.setUint64(1, maxData, Endian.big);
    
    return buffer;
  }
  
  static DataBlockedFrame fromBytes(ByteData view, int offset) {
    final maxData = view.getUint64(offset + 1, Endian.big);
    return DataBlockedFrame(maxData: maxData);
  }
}

/// STREAM_DATA_BLOCKED Frame (Type 0x0f)
/// Indicates that a stream is blocked due to stream-level flow control.
/// Sent when the sender wants to send data on a stream but is blocked
/// by the stream-level flow control limit.
class StreamDataBlockedFrame extends Frame {
  final int streamId;        // 4 bytes
  final int maxStreamData;   // 8 bytes - the stream-level data limit at which blocking occurred
  
  StreamDataBlockedFrame({
    required this.streamId,
    required this.maxStreamData,
  }) : super(FrameType.streamDataBlocked);
  
  @override
  int get length => 1 + 4 + 8; // Type + Stream ID + Max Stream Data
  
  @override
  Uint8List toBytes() {
    final buffer = Uint8List(length);
    final view = ByteData.view(buffer.buffer);
    
    view.setUint8(0, FrameType.streamDataBlocked.code);
    view.setUint32(1, streamId, Endian.big);
    view.setUint64(5, maxStreamData, Endian.big);
    
    return buffer;
  }
  
  static StreamDataBlockedFrame fromBytes(ByteData view, int offset) {
    final streamId = view.getUint32(offset + 1, Endian.big);
    final maxStreamData = view.getUint64(offset + 5, Endian.big);
    
    return StreamDataBlockedFrame(
      streamId: streamId,
      maxStreamData: maxStreamData,
    );
  }
}

/// NEW_CONNECTION_ID Frame (Type 0x10)
/// Provides the peer with a new Connection ID that can be used for this connection.
/// This enables connection migration and prevents linkability attacks.
class NewConnectionIdFrame extends Frame {
  final int sequenceNumber;     // Sequence number for this CID
  final int retirePriorTo;      // All CIDs with sequence < this should be retired
  final ConnectionId connectionId; // The new CID
  final StatelessResetToken resetToken; // Associated stateless reset token
  
  NewConnectionIdFrame({
    required this.sequenceNumber,
    required this.retirePriorTo,
    required this.connectionId,
    required this.resetToken,
  }) : super(FrameType.newConnectionId);
  
  @override
  int get length {
    // Type (1) + Seq (8) + RetirePriorTo (8) + CID Length (1) + CID + Reset Token (16)
    return 1 + 8 + 8 + 1 + connectionId.length + StatelessResetToken.length;
  }
  
  @override
  Uint8List toBytes() {
    final buffer = Uint8List(length);
    final view = ByteData.view(buffer.buffer);
    
    int offset = 0;
    view.setUint8(offset, FrameType.newConnectionId.code);
    offset += 1;
    
    view.setUint64(offset, sequenceNumber, Endian.big);
    offset += 8;
    
    view.setUint64(offset, retirePriorTo, Endian.big);
    offset += 8;
    
    view.setUint8(offset, connectionId.length);
    offset += 1;
    
    buffer.setAll(offset, connectionId.bytes);
    offset += connectionId.length;
    
    buffer.setAll(offset, resetToken.bytes);
    
    return buffer;
  }
  
  static NewConnectionIdFrame fromBytes(ByteData view, int offset) {
    int currentOffset = offset + 1; // Skip type
    
    final sequenceNumber = view.getUint64(currentOffset, Endian.big);
    currentOffset += 8;
    
    final retirePriorTo = view.getUint64(currentOffset, Endian.big);
    currentOffset += 8;
    
    final cidLength = view.getUint8(currentOffset);
    currentOffset += 1;
    
    final cidBytes = Uint8List.view(
      view.buffer,
      view.offsetInBytes + currentOffset,
      cidLength
    );
    final connectionId = ConnectionId.fromUint8List(cidBytes);
    currentOffset += cidLength;
    
    final resetTokenBytes = Uint8List.view(
      view.buffer,
      view.offsetInBytes + currentOffset,
      StatelessResetToken.length
    );
    final resetToken = StatelessResetToken(resetTokenBytes);
    
    return NewConnectionIdFrame(
      sequenceNumber: sequenceNumber,
      retirePriorTo: retirePriorTo,
      connectionId: connectionId,
      resetToken: resetToken,
    );
  }
}

/// RETIRE_CONNECTION_ID Frame (Type 0x11)
/// Indicates that the endpoint will no longer use a Connection ID that was
/// issued by the peer. This also serves as a request for the peer to send
/// a new Connection ID.
class RetireConnectionIdFrame extends Frame {
  final int sequenceNumber; // Sequence number of the CID to retire
  
  RetireConnectionIdFrame({
    required this.sequenceNumber,
  }) : super(FrameType.retireConnectionId);
  
  @override
  int get length => 1 + 8; // Type + Sequence Number
  
  @override
  Uint8List toBytes() {
    final buffer = Uint8List(length);
    final view = ByteData.view(buffer.buffer);
    
    view.setUint8(0, FrameType.retireConnectionId.code);
    view.setUint64(1, sequenceNumber, Endian.big);
    
    return buffer;
  }
  
  static RetireConnectionIdFrame fromBytes(ByteData view, int offset) {
    final sequenceNumber = view.getUint64(offset + 1, Endian.big);
    
    return RetireConnectionIdFrame(
      sequenceNumber: sequenceNumber,
    );
  }
}

/// Represents a stateless reset token used to validate STATELESS_RESET packets.
/// 
/// A stateless reset token is a cryptographically secure 16-byte value derived
/// from a connection ID using HMAC-SHA256. This allows servers to send a
/// stateless reset without maintaining connection state.
class StatelessResetToken {
  /// The fixed length of a stateless reset token
  static const int length = 16;
  
  /// The token bytes
  final Uint8List bytes;
  
  /// A secret key used for HMAC generation (should be kept server-side)
  static Uint8List? _serverSecret;
  
  StatelessResetToken(this.bytes) {
    if (bytes.length != length) {
      throw ArgumentError('StatelessResetToken must be exactly $length bytes');
    }
  }
  
  /// Generates a stateless reset token from a Connection ID using HMAC-SHA256.
  /// Requires a server secret to be set via setServerSecret().
  factory StatelessResetToken.generate(ConnectionId cid) {
    if (_serverSecret == null) {
      throw StateError('Server secret must be set before generating tokens');
    }
    
    // Use HMAC-SHA256 and take first 16 bytes
    final hmac = Hmac(sha256, _serverSecret!);
    final digest = hmac.convert(cid.bytes);
    final tokenBytes = Uint8List.fromList(digest.bytes.sublist(0, length));
    
    return StatelessResetToken(tokenBytes);
  }
  
  /// Sets the server secret used for token generation.
  /// This should be called once at server startup with a cryptographically
  /// secure random value.
  static void setServerSecret(Uint8List secret) {
    if (secret.length < 32) {
      throw ArgumentError('Server secret should be at least 32 bytes');
    }
    _serverSecret = secret;
  }
  
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StatelessResetToken &&
          const ListEquality().equals(bytes, other.bytes);
  
  @override
  int get hashCode => const ListEquality().hash(bytes);
}

/// A STATELESS_RESET packet that can be sent by a server that has lost
/// connection state. It looks like a regular packet but is identified by
/// the presence of a valid stateless reset token.
class StatelessResetPacket {
  /// The stateless reset token (last 16 bytes of the packet)
  final StatelessResetToken token;
  
  /// Random bytes to pad the packet to a minimum size
  final Uint8List randomBytes;
  
  /// Minimum packet size for stateless reset (to avoid amplification)
  static const int minPacketSize = 39;
  
  StatelessResetPacket({
    required this.token,
    required this.randomBytes,
  });
  
  /// Creates a stateless reset packet with random padding
  factory StatelessResetPacket.create(StatelessResetToken token) {
    // Packet size = random bytes + token (16)
    // Minimum size is 39 bytes, so random bytes = at least 23
    final randomBytesLength = minPacketSize - StatelessResetToken.length;
    final randomBytes = Uint8List(randomBytesLength);
    
    // Fill with random data
    for (int i = 0; i < randomBytes.length; i++) {
      randomBytes[i] = (DateTime.now().microsecondsSinceEpoch + i) & 0xFF;
    }
    
    return StatelessResetPacket(
      token: token,
      randomBytes: randomBytes,
    );
  }
  
  /// Converts the stateless reset packet to bytes
  Uint8List toBytes() {
    final buffer = Uint8List(randomBytes.length + StatelessResetToken.length);
    buffer.setAll(0, randomBytes);
    buffer.setAll(randomBytes.length, token.bytes);
    return buffer;
  }
  
  /// Attempts to parse a stateless reset packet from bytes.
  /// Returns null if the packet is too small or doesn't have a token at the end.
  static StatelessResetPacket? tryParse(Uint8List bytes) {
    if (bytes.length < minPacketSize) {
      return null;
    }
    
    // Extract last 16 bytes as potential token
    final tokenBytes = bytes.sublist(bytes.length - StatelessResetToken.length);
    final token = StatelessResetToken(tokenBytes);
    
    // Extract random bytes
    final randomBytes = bytes.sublist(0, bytes.length - StatelessResetToken.length);
    
    return StatelessResetPacket(
      token: token,
      randomBytes: randomBytes,
    );
  }
}


/// A UDX packet with stream information and a list of frames.
class UDXPacket {
  /// The protocol version (4 bytes)
  final int version;

  /// The destination Connection ID.
  final ConnectionId destinationCid;

  /// The source Connection ID.
  final ConnectionId sourceCid;

  /// The ID of the stream at the destination
  final int destinationStreamId;

  /// The ID of the stream at the source
  final int sourceStreamId;

  /// The sequence number.
  ///
  /// Mutable because a retransmission re-keys the packet under a FRESH sequence
  /// (PacketManager.retransmit), QUIC-style — a lost packet's bytes are re-sent
  /// under a new number rather than the old one, so loss can never exhaust a
  /// per-packet budget and strand the stream.
  int sequence;

  /// The list of frames in the packet
  final List<Frame> frames;

  /// The ORIGINAL send time, set once and not moved by a retransmission — its
  /// only reader, persistent-congestion detection, measures how long the packet
  /// has gone undelivered. Per-retransmission timing lives in [lastRetransmit].
  Duration? sentTime;

  /// When the packet last went on the wire: its first send, then each
  /// retransmission. The RTT is sampled from here (RFC 9002 section 5.1): a
  /// resend carries a fresh sequence, so its ACK names this send and no other.
  /// Instants are on the [Clock] the connection runs on.
  Duration? lastSentTime;

  /// Whether the packet has been acknowledged
  bool isAcked = false;

  /// A path-MTU probe (MtuDiscovery): numbered and tracked so its ACK or
  /// loss is reported, but never re-sent, not booked in flight, and no
  /// congestion signal when lost.
  bool isProbe = false;

  /// The datagram's length as sent, set by the sender; what the path-MTU
  /// search judges a packet by.
  int? wireSize;

  /// How many times this packet has been retransmitted, and when it last was.
  /// Used to space attempts and to collapse a near-simultaneous RTO timer and
  /// fast-retransmit into a single re-send.
  int retransmitCount = 0;
  Duration? lastRetransmit;

  /// The current UDX protocol version.
  ///
  /// Aliased to [UdxVersion.current] rather than repeated. This was a second
  /// hardcoded copy of the version number, and the two silently disagreed the
  /// moment one of them was bumped: every outgoing packet still claimed v2
  /// while the receiver required v3, so the handshake never completed.
  static const int currentVersion = UdxVersion.current;

  /// The stream data this packet carries, in bytes: what the congestion
  /// window and flow control account in. Retransmission carries the frames
  /// over, so it is the same under every sequence the packet is sent under.
  int get dataBytes {
    var n = 0;
    for (final f in frames) {
      if (f is StreamFrame) n += f.data.length;
    }
    return n;
  }

  /// Creates a new UDX packet
  UDXPacket({
    this.version = currentVersion,
    required this.destinationCid,
    required this.sourceCid,
    required this.destinationStreamId,
    required this.sourceStreamId,
    required this.sequence,
    required this.frames,
    this.sentTime,
  });

  /// Creates a UDX packet from raw bytes.
  /// New header format (variable length):
  /// 0-3: version (4 bytes)
  /// 4: destinationCidLength (1 byte)
  /// 5 to 5+destCidLen: destinationConnectionId
  /// 5+destCidLen: sourceCidLength (1 byte)
  /// 6+destCidLen to 6+destCidLen+srcCidLen: sourceConnectionId
  /// Next 4: sequence
  /// Next 4: destinationStreamId
  /// Next 4: sourceStreamId
  /// Rest: frames
  factory UDXPacket.fromBytes(Uint8List bytes) {
    const minHeaderLength = 18; // version(4) + dcidLen(1) + scidLen(1) + seq(4) + destId(4) + srcId(4)
    if (bytes.length < minHeaderLength) {
      throw ArgumentError(
          'Byte array too short for UDXPacket. Minimum $minHeaderLength bytes required, got ${bytes.length}');
    }
    final view =
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);

    int offset = 0;

    // Read version
    final version = view.getUint32(offset, Endian.big);
    offset += 4;

    // Read destination CID
    final destCidLength = view.getUint8(offset);
    offset += 1;
    if (destCidLength < ConnectionId.minCidLength || destCidLength > ConnectionId.maxCidLength) {
      throw ArgumentError('Invalid destination CID length: $destCidLength');
    }
    final destCid = ConnectionId.fromUint8List(
        bytes.sublist(offset, offset + destCidLength));
    offset += destCidLength;

    // Read source CID
    final srcCidLength = view.getUint8(offset);
    offset += 1;
    if (srcCidLength < ConnectionId.minCidLength || srcCidLength > ConnectionId.maxCidLength) {
      throw ArgumentError('Invalid source CID length: $srcCidLength');
    }
    final srcCid = ConnectionId.fromUint8List(
        bytes.sublist(offset, offset + srcCidLength));
    offset += srcCidLength;

    // Read sequence, stream IDs
    final sequence = view.getUint32(offset, Endian.big);
    offset += 4;
    final destinationStreamId = view.getUint32(offset, Endian.big);
    offset += 4;
    final sourceStreamId = view.getUint32(offset, Endian.big);
    offset += 4;

    // Parse frames
    final frames = <Frame>[];
    while (offset < bytes.length) {
      final frame = Frame.fromBytes(view, offset);
      frames.add(frame);
      offset += frame.length;
    }

    return UDXPacket(
      version: version,
      destinationCid: destCid,
      sourceCid: srcCid,
      destinationStreamId: destinationStreamId,
      sourceStreamId: sourceStreamId,
      sequence: sequence,
      frames: frames,
    );
  }

  /// Converts the UDX packet to raw bytes
  Uint8List toBytes() {
    final framesBytes =
        frames.map((f) => f.toBytes()).expand((b) => b).toList();
    
    // Calculate header length: version(4) + dcidLen(1) + dcid + scidLen(1) + scid + seq(4) + destId(4) + srcId(4)
    final headerLength = 4 + 1 + destinationCid.length + 1 + sourceCid.length + 4 + 4 + 4;
    final buffer = Uint8List(headerLength + framesBytes.length);
    final view = ByteData.view(buffer.buffer);

    int offset = 0;

    // Write version
    view.setUint32(offset, version, Endian.big);
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

    // Write sequence and stream IDs
    view.setUint32(offset, sequence, Endian.big);
    offset += 4;
    view.setUint32(offset, destinationStreamId, Endian.big);
    offset += 4;
    view.setUint32(offset, sourceStreamId, Endian.big);
    offset += 4;

    // Write frames
    buffer.setAll(offset, framesBytes);

    return buffer;
  }
}

/// Manages packet sending and receiving for a UDXStream
/// Tracks sent packets, matches ACKs to them, and declares loss the way
/// RFC 9002 section 6.1 does: from acknowledgements, never from a per-packet
/// timer. The port of go-udx's PacketManager.
///
/// A packet is lost once a later one has been acknowledged and it is either
/// [lossReorderThreshold] sequences behind the largest acknowledged or older
/// than [lossDelay] (9/8 of the RTT). Packets behind but not yet old enough
/// wait on the loss timer, which declares them lost when the delay elapses
/// without another ACK. What is lost is handed to [onPacketsLost]; the socket
/// contracts its window once per recovery epoch and re-sends the data under
/// fresh sequences through the congestion window and the pacer (LostQueue).
///
/// This replaced one retransmission timer per packet, armed at the RTO and
/// backing off to a 2 s cap. On a radio gap every timer fired together and
/// the whole window went out again at once, past the congestion window, and
/// again every 2 s into a dead path; the resends did not contract the window
/// either. QUIC's one PTO per connection (CongestionController) sends a probe
/// or two instead, backing off until the idle timeout, and loss is declared
/// only once an ACK proves it.
class PacketManager {
  /// The congestion control algorithm
  late CongestionController congestionController;

  /// The clock send times and the loss timer run on; see [Clock].
  final Clock clock;

  /// The next sequence number to use
  int get nextSequence => _nextSequence++;
  int _nextSequence = 0;

  /// The sequence number of the last packet that was sent.
  int lastSentPacketNumber = -1;

  /// The set of sent packets waiting for acknowledgment, keyed by the
  /// sequence each was LAST sent under.
  final Map<int, UDXPacket> _sentPackets = {};
  List<UDXPacket> get sentPackets => _sentPackets.values.toList();

  /// The set of received packets
  final Map<int, UDXPacket> _receivedPackets = {};

  /// The largest sequence the peer has acknowledged, -1 if none; when the
  /// last ACK that acknowledged something arrived; and the one before the
  /// ACK (or timer) that last declared loss: persistent congestion asks
  /// whether anything was acknowledged since the oldest lost packet went
  /// out, which the ACK that revealed the loss does not answer.
  int get largestAcked => _largestAcked;
  int _largestAcked = -1;
  Duration? _lastAckTime;
  Duration? _ackBeforeLoss;

  /// Fires when the oldest packet behind the largest acknowledged becomes old
  /// enough to be lost without another ACK (the time threshold).
  Timer? _lossTimer;

  /// How many sequences a packet must trail the largest acknowledged before a
  /// gap counts as loss (kPacketThreshold, RFC 9002 section 6.1.1).
  static const int lossReorderThreshold = 3;

  /// The floor on the loss delay (kGranularity).
  static const Duration lossTimerGranularity = Duration(milliseconds: 1);

  /// Creates a new packet manager
  PacketManager({CongestionController? congestionController, Clock? clock})
      : clock = clock ?? const SystemClock() {
    if (congestionController != null) {
      this.congestionController = congestionController;
    }
  }

  /// Puts a packet back on the wire. By the time it is called the packet's
  /// sequence has been advanced to a fresh number ([resend]), so this only
  /// encodes and sends.
  void Function(UDXPacket packet)? onRetransmit;

  /// Callback for metrics when a packet is retransmitted.
  /// Provides sequence number, attempt count, and the current PTO.
  void Function(int sequence, int attemptCount, Duration rto)? onPacketRetransmitEvent;

  /// Callback for metrics when packet loss is detected.
  /// Provides sequence number and loss type ('ack' or 'time').
  void Function(int sequence, String lossType)? onPacketLossEvent;

  /// Told what loss detection declared lost, oldest first. The packets are no
  /// longer tracked: the receiver re-sends them ([resend]) and books them.
  void Function(List<UDXPacket> lost)? onPacketsLost;

  /// Sends a packet
  void sendPacket(UDXPacket packet) {
    final now = clock.now();
    packet.sentTime = now;
    packet.lastSentTime = now;
    lastSentPacketNumber = packet.sequence;
    _sentPackets[packet.sequence] = packet;
  }

  /// Processes an incoming AckFrame, marking packets as acknowledged.
  ///
  /// Returns the packets the frame newly acknowledged, each under the sequence
  /// it was last sent with. The packets, not bare sequences: the caller needs
  /// their size and last send time, and the entries are removed here. The
  /// caller books them with the congestion controller and then runs
  /// [detectLostPackets], in that order (RFC 9002 appendix A.7: the
  /// acknowledged bytes grow the window before the loss contracts it).
  List<UDXPacket> handleAckFrame(AckFrame frame) {
    final newlyAcked = <UDXPacket>[];
    void take(int seq) {
      final packet = _sentPackets.remove(seq);
      if (packet != null) {
        packet.isAcked = true;
        newlyAcked.add(packet);
      }
    }

    // The first range ends at largestAcked, inclusive.
    for (int i = 0; i < frame.firstAckRangeLength; i++) {
      take(frame.largestAcked - i);
    }

    // Additional ranges, highest first. `gap` is counted from the packet just
    // below the previous range; the next range's highest is `gap` below it.
    int currentSeq = frame.largestAcked - frame.firstAckRangeLength;
    for (final rangeBlock in frame.ackRanges) {
      final rangeEnd = currentSeq - rangeBlock.gap;
      for (int i = 0; i < rangeBlock.ackRangeLength; i++) {
        take(rangeEnd - i);
      }
      currentSeq = rangeEnd - rangeBlock.ackRangeLength;
    }

    if (newlyAcked.isNotEmpty) {
      _ackBeforeLoss = _lastAckTime;
      _lastAckTime = clock.now();
      if (frame.largestAcked > _largestAcked) _largestAcked = frame.largestAcked;
    }
    return newlyAcked;
  }

  /// Handles received data
  void handleData(UDXPacket packet) {
    _receivedPackets[packet.sequence] = packet;
  }

  /// Gets a sent packet by its sequence number
  UDXPacket? getPacket(int sequence) {
    return _sentPackets[sequence];
  }

  /// How many outstanding packets a PTO re-sends, the oldest first (RFC 9002
  /// section 6.2.4 allows up to two).
  static const int ptoProbes = 2;

  /// Sends the PTO's probes: the [ptoProbes] oldest outstanding packets,
  /// re-sent under fresh sequences (RFC 9002 section 6.2.4: a probe carries
  /// data when there is data to carry). They are not declared lost (an ACK
  /// will say), their bytes stay in flight, and neither the window nor the
  /// pacer is consulted: a probe is allowed out when nothing else is (RFC
  /// 9002 section 7.7 exempts probes from pacing), though it is drawn from
  /// the pacing budget so that what follows it is paced as if it had been.
  /// [maxDatagram], when given, is what the path carries now: a larger
  /// packet is re-chunked to fit. Returns whether anything went out.
  ///
  /// This used to send a PING under [lastSentPacketNumber], the sequence of
  /// a data packet still in flight; both peers acknowledge a numbered PING,
  /// so a lost data packet could be marked acknowledged by its probe's ACK
  /// and never re-sent.
  bool sendProbe({int? maxDatagram}) {
    var sent = false;
    for (final oldest in oldestUnacked(ptoProbes)) {
      // Re-chunked if the path no longer carries it (fitToPath): after a
      // black hole, the probe is the first packet that can get through.
      final pieces = maxDatagram == null ? [oldest] : fitToPath(oldest, maxDatagram);
      for (final piece in pieces) {
        final newSeq = resend(piece);
        if (newSeq == null) continue;
        sent = true;
        onPacketRetransmitEvent?.call(newSeq, piece.retransmitCount, congestionController.pto);
        onRetransmit?.call(piece);
        // Drawn from the pacing budget, so what follows the probe is paced
        // as if it had been (section 7.7 exempts the probe itself).
        congestionController.pacingController.onPacketSent(piece.wireSize ?? piece.toBytes().length);
      }
    }
    return sent;
  }

  /// Tracks a packet the caller sends itself, so that [handleAckFrame] returns
  /// it when acknowledged, without ever retransmitting it: a PING sent to
  /// test liveness (UDPSocket.ping). The caller forgets it ([forget]) when it
  /// stops waiting, so a lost ACK leaves nothing behind.
  void trackUntilAcked(UDXPacket packet) {
    final now = clock.now();
    packet.sentTime = now;
    packet.lastSentTime = now;
    lastSentPacketNumber = packet.sequence;
    _sentPackets[packet.sequence] = packet;
  }

  /// Stops tracking [sequence], if it is still tracked.
  void forget(int sequence) {
    _sentPackets.remove(sequence);
  }

  /// How long a packet must have been outstanding before age alone marks it
  /// lost: 9/8 of the larger of the smoothed and latest RTT, floored at the
  /// timer granularity (RFC 9002 section 6.1.2). The larger of the two: after
  /// a sudden increase in delay the smoothed estimate lags, and alone it would
  /// declare a window of packets lost for being slower than they used to be.
  Duration get lossDelay {
    var rtt = congestionController.smoothedRtt;
    final latest = congestionController.latestRttForTest;
    if (latest > rtt) rtt = latest;
    var delay = rtt * 9 ~/ 8;
    if (delay < lossTimerGranularity) delay = lossTimerGranularity;
    return delay;
  }

  /// Runs loss detection over everything outstanding (RFC 9002 section 6.1)
  /// and returns what it declared lost, also handed to [onPacketsLost]. The
  /// socket calls it after each ACK that acknowledged something; the loss
  /// timer calls it when the time threshold elapses.
  List<UDXPacket> detectLostPackets() {
    final lost = _detectLost(clock.now());
    if (lost.isNotEmpty) onPacketsLost?.call(lost);
    return lost;
  }

  /// Declares lost every outstanding packet below the largest acknowledged
  /// that is [lossReorderThreshold] or more behind it, or older than
  /// [lossDelay], removes them from tracking and returns them in sequence
  /// order. Packets behind the largest acknowledged but not yet old enough
  /// arm the loss timer for when the oldest will be.
  ///
  /// Every outstanding packet below the largest acknowledged is considered,
  /// not only those in a frame's gaps: a receiver that acknowledges one
  /// packet at a time sends no gaps, and the time threshold is then what
  /// declares loss.
  List<UDXPacket> _detectLost(Duration now) {
    _lossTimer?.cancel();
    _lossTimer = null;
    if (_largestAcked < 0) return const [];
    final delay = lossDelay;
    final lost = <UDXPacket>[];
    Duration? nextLoss;
    for (final packet in _sentPackets.values) {
      final seq = packet.sequence;
      if (seq > _largestAcked) continue;
      final sentAt = packet.lastSentTime ?? packet.sentTime ?? now;
      if (_largestAcked - seq >= lossReorderThreshold) {
        lost.add(packet);
        onPacketLossEvent?.call(seq, 'ack');
      } else if (now >= sentAt + delay) {
        lost.add(packet);
        onPacketLossEvent?.call(seq, 'time');
      } else {
        final at = sentAt + delay;
        if (nextLoss == null || at < nextLoss) nextLoss = at;
      }
    }
    for (final packet in lost) {
      _sentPackets.remove(packet.sequence);
    }
    lost.sort((a, b) => a.sequence.compareTo(b.sequence));
    if (nextLoss != null) {
      var wait = nextLoss - now;
      if (wait < lossTimerGranularity) wait = lossTimerGranularity;
      _lossTimer = clock.timer(wait, _onLossTimer);
    }
    return lost;
  }

  void _onLossTimer() {
    _ackBeforeLoss = _lastAckTime;
    final lost = _detectLost(clock.now());
    if (lost.isNotEmpty) onPacketsLost?.call(lost);
  }

  /// Whether a packet is waiting on the time threshold.
  bool get lossTimerArmed => _lossTimer != null;

  /// Whether [lost], as just declared, is persistent congestion (RFC 9002
  /// section 7.6): the sender has an RTT sample, the newest lost packet went
  /// out at least three PTOs after the oldest, and nothing was acknowledged
  /// between the oldest going out and the ACK (or timer) that revealed the
  /// loss. The socket then collapses the window.
  bool persistentCongestion(List<UDXPacket> lost) {
    if (lost.length < 2 || !congestionController.hasRttSample) return false;
    final oldest = lost.first.lastSentTime;
    final newest = lost.last.lastSentTime;
    if (oldest == null || newest == null) return false;
    if (newest - oldest < congestionController.persistentCongestionDuration) return false;
    final before = _ackBeforeLoss;
    return before == null || before < oldest;
  }

  /// Gives a packet a FRESH sequence number for another transmission and
  /// tracks it under that number, returning the number, or null when the
  /// packet has been acknowledged and must not go out again.
  ///
  /// Reusing the original number is what made loss fatal: the retry budget
  /// rode on the packet, so exhausting it left a hole the stream could never
  /// fill. QUIC never reuses a packet number (RFC 9000 section 12.3); it
  /// re-frames lost data into a new packet. Both v3 stacks reassemble
  /// streams on byte offsets, so a fresh number is safe: a duplicate is
  /// discarded by its offset, and the retransmission is acknowledged
  /// unambiguously.
  ///
  /// The packet may be tracked (a PTO probe re-sends the oldest outstanding
  /// packet, which stays outstanding) or not (loss detection removed it):
  /// either way it is tracked under the new number afterwards, with
  /// [UDXPacket.lastSentTime] reset so the RTT sample and loss detection
  /// measure from this send; [UDXPacket.sentTime] stays the first send.
  /// Congestion accounting is the caller's: a probe's bytes are still in
  /// flight, a lost packet's left flight when it was declared lost and are
  /// booked again by the caller when it goes out.
  int? resend(UDXPacket packet) {
    if (packet.isAcked || packet.isProbe) return null;
    if (identical(_sentPackets[packet.sequence], packet)) {
      _sentPackets.remove(packet.sequence);
    }
    final now = clock.now();
    final newSeq = nextSequence;
    packet.sequence = newSeq;
    packet.retransmitCount++;
    packet.lastRetransmit = now;
    packet.lastSentTime = now;
    packet.sentTime ??= now;
    lastSentPacketNumber = newSeq;
    _sentPackets[newSeq] = packet;
    return newSeq;
  }

  /// Up to [n] outstanding packets, lowest sequence first: what a PTO probe
  /// re-sends. A re-send takes a fresh sequence, so the lowest numbers are
  /// the longest unsent.
  List<UDXPacket> oldestUnacked(int n) {
    if (_sentPackets.isEmpty || n <= 0) return const [];
    // A path-MTU probe is never re-sent.
    final all = _sentPackets.values.where((p) => !p.isProbe).toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    return all.length > n ? all.sublist(0, n) : all;
  }

  /// Forgets a tracked packet that is being replaced by others
  /// ([fitToPath]), neither acknowledged nor lost.
  void drop(UDXPacket packet) {
    if (identical(_sentPackets[packet.sequence], packet)) {
      _sentPackets.remove(packet.sequence);
    }
  }

  /// Re-chunks a packet larger than the path now carries (the size fell
  /// back after a black hole, MtuDiscovery) into packets that fit, in its
  /// place: the original is dropped from tracking and the pieces take fresh
  /// sequences when they are re-sent ([resend]). A packet that fits is
  /// returned as it is. Only a packet carrying one STREAM frame is split,
  /// which is every data packet a stream sends.
  List<UDXPacket> fitToPath(UDXPacket packet, int limit) {
    final size = packet.wireSize ?? packet.toBytes().length;
    if (size <= limit || packet.frames.length != 1) return [packet];
    final frame = packet.frames.single;
    if (frame is! StreamFrame) return [packet];
    UDXPacket build(StreamFrame f) => UDXPacket(
          destinationCid: packet.destinationCid,
          sourceCid: packet.sourceCid,
          destinationStreamId: packet.destinationStreamId,
          sourceStreamId: packet.sourceStreamId,
          sequence: 0,
          frames: [f],
        );
    final overhead = build(StreamFrame(data: Uint8List(0), offset: frame.offset, isSyn: frame.isSyn)).toBytes().length;
    final piece = limit - overhead;
    if (piece <= 0 || piece >= frame.data.length) return [packet];
    drop(packet);
    final pieces = <UDXPacket>[];
    var data = frame.data;
    var offset = frame.offset;
    var isSyn = frame.isSyn;
    while (data.isNotEmpty) {
      final k = piece < data.length ? piece : data.length;
      final p = build(StreamFrame(
        data: Uint8List.sublistView(data, 0, k),
        offset: offset,
        isSyn: isSyn,
        isFin: frame.isFin && k == data.length,
      ))
        ..sentTime = packet.sentTime
        ..retransmitCount = packet.retransmitCount;
      p.wireSize = p.toBytes().length;
      pieces.add(p);
      isSyn = false;
      offset += k;
      data = Uint8List.sublistView(data, k);
    }
    return pieces;
  }

  /// Stops the loss timer and forgets every packet.
  void destroy() {
    _lossTimer?.cancel();
    _lossTimer = null;
    _sentPackets.clear();
  }

  // --- Test Hooks ---
  Map<int, UDXPacket> getSentPacketsTestHook() => _sentPackets;
}
