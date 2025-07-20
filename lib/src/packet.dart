import 'dart:async';
import 'dart:typed_data';

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
      case FrameType.maxData: // Handle new MaxDataFrame
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
      default:
        throw ArgumentError('Unknown frame type: $type');
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
class AckFrame extends Frame {
  final int largestAcked;
  final int ackDelay; // In milliseconds
  final int firstAckRangeLength; // Number of contiguous packets ending at largestAcked
  final List<AckRange> ackRanges; // Additional non-contiguous ranges

  AckFrame({
    required this.largestAcked,
    required this.ackDelay,
    required this.firstAckRangeLength,
    this.ackRanges = const [],
  }) : super(FrameType.ack);

  @override
  int get length {
    // Type (1)
    // Largest Acked (4)
    // ACK Delay (2)
    // ACK Range Count (1)
    // First ACK Range Length (4)
    // Each additional ACK Range: Gap (1) + ACK Range Length (4) = 5 bytes
    return 1 + 4 + 2 + 1 + 4 + (ackRanges.length * (1 + 4));
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


/// A UDX packet with stream information and a list of frames.
class UDXPacket {
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

  /// Creates a new UDX packet
  UDXPacket({
    required this.destinationCid,
    required this.sourceCid,
    required this.destinationStreamId,
    required this.sourceStreamId,
    required this.sequence,
    required this.frames,
    this.sentTime,
  });

  /// Creates a UDX packet from raw bytes. Header is 28 bytes.
  /// 0-7: destinationConnectionId
  /// 8-15: sourceConnectionId
  /// 16-19: sequence
  /// 20-23: destinationStreamId
  /// 24-27: sourceStreamId
  factory UDXPacket.fromBytes(Uint8List bytes) {
    const headerLength = 28;
    if (bytes.length < headerLength) {
      throw ArgumentError(
          'Byte array too short for UDXPacket. Minimum $headerLength bytes required, got ${bytes.length}');
    }
    final view =
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);

    final destCid = ConnectionId.fromUint8List(
        bytes.sublist(0, ConnectionId.cidLength));
    final srcCid = ConnectionId.fromUint8List(
        bytes.sublist(ConnectionId.cidLength, ConnectionId.cidLength * 2));
    final sequence = view.getUint32(16, Endian.big);
    final destinationStreamId = view.getUint32(20, Endian.big);
    final sourceStreamId = view.getUint32(24, Endian.big);

    final frames = <Frame>[];
    int offset = headerLength;
    while (offset < bytes.length) {
      final frame = Frame.fromBytes(view, offset);
      frames.add(frame);
      offset += frame.length;
    }

    return UDXPacket(
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
    const headerLength = 28;
    final buffer = Uint8List(headerLength + framesBytes.length);
    final view = ByteData.view(buffer.buffer);

    buffer.setAll(0, destinationCid.bytes);
    buffer.setAll(ConnectionId.cidLength, sourceCid.bytes);
    view.setUint32(16, sequence, Endian.big);
    view.setUint32(20, destinationStreamId, Endian.big);
    view.setUint32(24, sourceStreamId, Endian.big);

    buffer.setAll(headerLength, framesBytes);

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

  /// Creates a new packet manager
  PacketManager({CongestionController? congestionController}) {
    if (congestionController != null) {
      this.congestionController = congestionController;
    }
  }

  /// Callback to be invoked when a packet needs to be retransmitted.
  void Function(UDXPacket packet)? onRetransmit;

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
    final probePacket = UDXPacket(
      destinationCid: destCid,
      sourceCid: srcCid,
      destinationStreamId: destId,
      sourceStreamId: srcId,
      sequence: nextSequence, // Use a new sequence number
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
        
        // Remove from sent packets to prevent further retransmission attempts
        _sentPackets.remove(packet.sequence);
        
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
