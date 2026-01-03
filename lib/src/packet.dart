import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:collection/collection.dart';

import 'cid.dart';
import 'congestion.dart';

// --- Frame Definitions ---

/// Enum for different frame types.
enum FrameType {
  padding,
  ping,
  ack,
  stream,
  windowUpdate,
  maxData, // New frame type for connection-level flow control
  resetStream, // New frame type for abrupt stream termination
  maxStreams,
  mtuProbe, // New frame type for Path MTU Discovery
  pathChallenge,
  pathResponse,
  connectionClose, // Graceful connection termination with error details
  stopSending, // Request peer to stop sending on a stream
  dataBlocked, // Connection-level flow control blocked
  streamDataBlocked, // Stream-level flow control blocked
  newConnectionId, // Provides a new CID that the peer can use
  retireConnectionId, // Requests retirement of a previously issued CID
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
    final type = view.getUint8(offset);
    if (type >= FrameType.values.length) {
      throw ArgumentError('Unknown frame type: $type');
    }
    switch (FrameType.values[type]) {
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
    return Uint8List.fromList([FrameType.padding.index]);
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
    return Uint8List.fromList([FrameType.ping.index]);
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

    view.setUint8(offset, FrameType.ack.index);
    offset += 1;

    view.setUint32(offset, largestAcked, Endian.big);
    offset += 4;

    view.setUint16(offset, ackDelay, Endian.big);
    offset += 2;

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
  final Uint8List data;

  StreamFrame({this.isFin = false, this.isSyn = false, required this.data}) : super(FrameType.stream);

  // Type (1) + Flags (1) + Length (2) + Data (variable)
  @override
  int get length => 1 + 1 + 2 + data.length;

  @override
  Uint8List toBytes() {
    final buffer = Uint8List(length);
    final view = ByteData.view(buffer.buffer);
    view.setUint8(0, FrameType.stream.index);
    int flags = 0;
    if (isFin) flags |= 0x01;
    if (isSyn) flags |= 0x02;
    view.setUint8(1, flags);
    view.setUint16(2, data.length, Endian.big);
    buffer.setAll(4, data);
    return buffer;
  }

  static StreamFrame fromBytes(ByteData view, int offset) {
    final flags = view.getUint8(offset + 1);
    final isFin = (flags & 0x01) != 0;
    final isSyn = (flags & 0x02) != 0;
    final dataLength = view.getUint16(offset + 2, Endian.big);
    final data = Uint8List.view(view.buffer, view.offsetInBytes + offset + 4, dataLength);
    return StreamFrame(isFin: isFin, isSyn: isSyn, data: data);
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
    view.setUint8(0, FrameType.windowUpdate.index);
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
    view.setUint8(0, FrameType.maxData.index);
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
    view.setUint8(0, FrameType.resetStream.index);
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
    view.setUint8(0, FrameType.maxStreams.index);
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
    view.setUint8(0, FrameType.mtuProbe.index);
    // The rest of the frame is padding, which is implicitly zeros.
    return buffer;
  }

  static MtuProbeFrame fromBytes(ByteData view, int offset) {
    // The length of the probe is the remaining length of the packet.
    // This frame should be the only one in a probe packet besides the header.
    // The actual size is determined by the packet length, not a field here.
    // We'll give it a nominal size of 1 for the type byte.
    return MtuProbeFrame(probeSize: 1);
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
    buffer[0] = FrameType.pathChallenge.index;
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
    buffer[0] = FrameType.pathResponse.index;
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
    view.setUint8(offset, FrameType.connectionClose.index);
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
    
    view.setUint8(0, FrameType.stopSending.index);
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
    
    view.setUint8(0, FrameType.dataBlocked.index);
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
    
    view.setUint8(0, FrameType.streamDataBlocked.index);
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
    view.setUint8(offset, FrameType.newConnectionId.index);
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
    
    view.setUint8(0, FrameType.retireConnectionId.index);
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

  /// The sequence number
  final int sequence;

  /// The list of frames in the packet
  final List<Frame> frames;

  /// The time the packet was sent
  DateTime? sentTime;

  /// Whether the packet has been acknowledged
  bool isAcked = false;

  /// The current UDX protocol version
  static const int currentVersion = 0x00000002;

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
class PacketManager {
  /// The congestion control algorithm
  late CongestionController congestionController;

  /// The next sequence number to use
  int get nextSequence => _nextSequence++;
  int _nextSequence = 0;

  /// The sequence number of the last packet that was sent.
  int lastSentPacketNumber = -1;

  /// The set of sent packets waiting for acknowledgment
  final Map<int, UDXPacket> _sentPackets = {};
  List<UDXPacket> get sentPackets => _sentPackets.values.toList();

  /// The set of received packets
  final Map<int, UDXPacket> _receivedPackets = {};

  /// The maximum number of retransmissions
  static const int maxRetries = 3;

  /// The retransmission timeout in milliseconds
  int get retransmitTimeout {
    // If we don't have an RTT sample yet, use a conservative initial RTO.
    // See RFC 9002, Section 6.2.1.
    if (congestionController.smoothedRtt == Duration.zero) {
      return 1000; // 1 second initial RTO
    }
    // RTO = smoothed_rtt + 4 * rttvar
    final rto = congestionController.smoothedRtt.inMilliseconds +
        (4 * congestionController.rttVar.inMilliseconds);
    return rto.clamp(200, 5000); // Clamp to a reasonable range (increased min)
  }

  /// The retransmission timers
  final Map<int, Timer> _retransmitTimers = {};

  /// Track retransmission attempts per packet for metrics
  final Map<int, int> _retransmitAttempts = {};

  /// Creates a new packet manager
  PacketManager({CongestionController? congestionController}) {
    if (congestionController != null) {
      this.congestionController = congestionController;
    }
  }

  /// Callback to be invoked when a packet needs to be retransmitted.
  void Function(UDXPacket packet)? onRetransmit;
  
  /// Callback for metrics when a packet is retransmitted.
  /// Provides sequence number, attempt count, and current RTO.
  void Function(int sequence, int attemptCount, Duration rto)? onPacketRetransmitEvent;
  
  /// Callback for metrics when packet loss is detected.
  /// Provides sequence number and loss type ('timeout' or 'fast_retransmit').
  void Function(int sequence, String lossType)? onPacketLossEvent;

  /// Callback to be invoked when a probe packet needs to be sent.
  void Function(UDXPacket packet)? onSendProbe;

  /// Callback for when a packet is considered permanently lost after max retries.
  void Function(UDXPacket packet)? onPacketPermanentlyLost;

  /// Sends a packet
  void sendPacket(UDXPacket packet) {
    packet.sentTime = DateTime.now();
    lastSentPacketNumber = packet.sequence;
    _sentPackets[packet.sequence] = packet;
    _scheduleRetransmission(packet);
  }

  /// Processes an incoming AckFrame, marking packets as acknowledged.
  /// Returns a list of sequence numbers that were successfully acknowledged by this frame.
  List<int> handleAckFrame(AckFrame frame) {
    final newlyAckedSequences = <int>[];

    // Process the first range (ending at largestAcked)
    // largestAcked is inclusive. firstAckRangeLength is the count of packets in this range.
    // So, the smallest sequence in this range is largestAcked - firstAckRangeLength + 1.
    if (frame.firstAckRangeLength > 0) {
      for (int i = 0; i < frame.firstAckRangeLength; i++) {
        final seq = frame.largestAcked - i;
        if (_sentPackets.containsKey(seq)) {
          final packet = _sentPackets.remove(seq);
          packet?.isAcked = true;
          _retransmitTimers[seq]?.cancel();
          _retransmitTimers.remove(seq);
          newlyAckedSequences.add(seq);
        }
      }
    }


    // Process additional ACK ranges
    // Ranges are ordered from highest sequence numbers to lowest.
    // `gap` is relative to the *start* of the previously processed (higher sequence) range.
    int currentSeq = frame.largestAcked - frame.firstAckRangeLength; // Sequence just below the first range

    for (final rangeBlock in frame.ackRanges) {
      // The current range's highest packet (rangeEnd) is `rangeBlock.gap` packets below `currentSeq`.
      // `currentSeq` represents the packet number immediately preceding the lowest packet of the previously acked block.
      final rangeEnd = currentSeq - rangeBlock.gap; // CORRECTED
      
      for (int i = 0; i < rangeBlock.ackRangeLength; i++) {
        final seq = rangeEnd - i;
        if (_sentPackets.containsKey(seq)) {
          final packet = _sentPackets.remove(seq);
          packet?.isAcked = true;
          _retransmitTimers[seq]?.cancel();
          _retransmitTimers.remove(seq);
          newlyAckedSequences.add(seq);
        }
      }
      // Update currentSeq for the next iteration: it should be the packet number
      // immediately preceding the lowest packet of the range just processed.
      // Lowest packet in current range = rangeEnd - rangeBlock.ackRangeLength + 1.
      currentSeq = (rangeEnd - rangeBlock.ackRangeLength + 1) - 1; // CORRECTED
    }
    return newlyAckedSequences;
  }

  /// Handles received data
  void handleData(UDXPacket packet) {
    _receivedPackets[packet.sequence] = packet;
  }

  /// Gets the next packet to retransmit
  UDXPacket? getNextRetransmit() {
    if (_sentPackets.isEmpty) return null;
    return _sentPackets.values.first;
  }

  /// Gets a sent packet by its sequence number
  UDXPacket? getPacket(int sequence) {
    return _sentPackets[sequence];
  }

  /// Sends a probe packet to elicit an ACK.
  /// The probe packet contains a PING frame.
  void sendProbe(ConnectionId destCid, ConnectionId srcCid, int destId, int srcId) {
    // FIX: Probe packets should NOT consume new sequence numbers.
    // Like ACKs, they are not registered for retransmission, and if lost,
    // the receiver's _nextExpectedSeq gets stuck forever. Use the last
    // sent sequence number (or 0 if none sent yet) to avoid sequence gaps.
    final probeSeq = lastSentPacketNumber >= 0 ? lastSentPacketNumber : 0;
    
    final probePacket = UDXPacket(
      destinationCid: destCid,
      sourceCid: srcCid,
      destinationStreamId: destId,
      sourceStreamId: srcId,
      sequence: probeSeq,
      frames: [PingFrame()],
    );
    onSendProbe?.call(probePacket);
  }

  /// Retransmits a specific packet by its sequence number.
  void retransmitPacket(int sequence) {
    final packet = _sentPackets[sequence];
    if (packet != null) {
      onRetransmit?.call(packet);
    }
  }

  /// Schedules a retransmission for a packet
  /// Note: This provides basic timeout-based retransmission. The QUIC-compliant
  /// PTO system in CongestionController handles sophisticated loss detection.
  void _scheduleRetransmission(UDXPacket packet) {
    // print('PacketManager: Scheduling retransmission for packet ${packet.sequence}, timeout: ${retransmitTimeout}ms');

    int retryCount = 0;
    const maxRetries = 10; // Maximum retransmission attempts before giving up on this packet

    void retransmit() {
      // If the packet has been acknowledged, stop the retransmission cycle.
      if (!_sentPackets.containsKey(packet.sequence)) {
        // print('PacketManager: Packet ${packet.sequence} already acknowledged, stopping retransmission');
        _retransmitTimers[packet.sequence]?.cancel();
        _retransmitTimers.remove(packet.sequence);
        return;
      }

      retryCount++;
      
      if (retryCount <= maxRetries) {
        // print('PacketManager: Retransmitting packet ${packet.sequence} (attempt $retryCount/$maxRetries)');
        
        // Track the retransmit attempt and notify observer
        _retransmitAttempts[packet.sequence] = retryCount;
        final rto = Duration(milliseconds: retransmitTimeout);
        onPacketRetransmitEvent?.call(packet.sequence, retryCount, rto);
        
        // Invoke the callback to perform the actual retransmission
        if (onRetransmit != null) {
          onRetransmit!(packet);
          // print('PacketManager: Called onRetransmit for packet ${packet.sequence}');
        } else {
          // print('PacketManager: ERROR - onRetransmit callback is null for packet ${packet.sequence}');
        }

        // Reschedule the next retransmission with exponential backoff
        // The PTO system in CongestionController handles sophisticated loss detection
        final backoffTimeout = retransmitTimeout * (1 << (retryCount - 1)); // Exponential backoff: 1x, 2x, 4x, 8x, etc.
        _retransmitTimers[packet.sequence] = Timer(
          Duration(milliseconds: backoffTimeout.clamp(200, 30000)), // Clamp between 200ms and 30s
          retransmit,
        );
      } else {
        // Exceeded max retries - give up on this packet but don't escalate to connection failure
        // print('PacketManager: Giving up on packet ${packet.sequence} after $maxRetries attempts');
        _retransmitTimers[packet.sequence]?.cancel();
        _retransmitTimers.remove(packet.sequence);
        
        // Notify observer of packet loss
        onPacketLossEvent?.call(packet.sequence, 'timeout');
        
        // Remove from sent packets to prevent further retransmission attempts
        _sentPackets.remove(packet.sequence);
        _retransmitAttempts.remove(packet.sequence);
        
        // Note: We don't call onPacketPermanentlyLost as that was causing stream crashes
        // The QUIC-compliant PTO system will handle loss detection gracefully
      }
    }

    // Schedule the first retransmission
    _retransmitTimers[packet.sequence] = Timer(
      Duration(milliseconds: retransmitTimeout),
      retransmit,
    );
  }

  /// Destroys the packet manager and cancels all timers
  void destroy() {
    for (final timer in _retransmitTimers.values) {
      timer.cancel();
    }
    _retransmitTimers.clear();
    _sentPackets.clear();
  }

  // --- Test Hooks ---
  // Methods to allow tests to inspect internal state.
  Map<int, UDXPacket> getSentPacketsTestHook() => _sentPackets;
  Map<int, Timer> getRetransmitTimersTestHook() => _retransmitTimers;
}
