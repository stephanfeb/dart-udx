import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:io'; // Added for InternetAddress

import 'cid.dart';
import 'events.dart'; // Added for UDXEvent
import 'udx.dart';
import 'socket.dart';
import 'events.dart';
import 'packet.dart';
import 'congestion.dart';

/// A reliable, ordered stream over UDP.
class UDXStream with UDXEventEmitter implements StreamSink<Uint8List> {
  /// The UDX instance that created this stream
  final UDX udx;

  /// The socket this stream is connected to
  UDPSocket? _socket;

  /// The stream ID
  final int id;

  /// The remote stream ID
  int? remoteId;

  /// The remote host
  String? remoteHost;

  /// The remote port
  int? remotePort;

  /// The remote address family
  int? remoteFamily;

  /// Whether the stream is connected
  bool get connected => _connected;
  bool _connected = false;

  /// Whether this stream was created by this endpoint.
  final bool isInitiator;

  /// The maximum transmission unit (MTU)
  int get mtu => _mtu;
  int _mtu = 1400; // Default MTU

  // Define a safe payload size, leaving room for headers (IP, UDP, UDX)
  // UDXPacket header is 12 bytes, StreamFrame header is 4 bytes
  // So we need to subtract 16 bytes from the max payload size
  // This is now calculated dynamically based on the MTU
  int get _maxPayloadSize => _mtu - 16;

  /// Maximum number of retransmission attempts before considering packet lost
  int maxRetransmissionAttempts = 10;

  /// Total timeout tolerance for packet-level operations (in seconds)
  int packetTimeoutTolerance = 30;

  /// Track retransmission attempts per packet
  final Map<int, int> _retransmissionAttempts = {};

  /// The round-trip time
  Duration get rtt => _congestionController.smoothedRtt;

  /// The congestion window
  int get cwnd => _congestionController.cwnd;

  /// The number of bytes in flight
  int get inflight => _congestionController.inflight;

  /// The local receive window size
  int get receiveWindow => _receiveWindow;
  int _receiveWindow = 65536; // Default receive window size

  /// The remote peer's receive window size
  int get remoteReceiveWindow => _remoteReceiveWindow;
  int _remoteReceiveWindow = 65536; // Default remote receive window size

  /// The congestion controller
  late final CongestionController _congestionController;

  /// The packet manager
  late final PacketManager packetManager;

  /// The stream controller for data events
  final _dataController = StreamController<Uint8List>.broadcast();

  /// A completer that resolves when the stream can send more data.
  Completer<void>? _drain;

  StreamSubscription? _remoteConnectionWindowUpdateSubscription;

  /// Whether the stream is in framed mode
  final bool framed;

  /// The initial sequence number
  final int initialSeq;

  /// The next expected sequence number from the remote peer
  late int _nextExpectedSeq;

  /// A buffer for out-of-order packets
  final Map<int, UDXPacket> _receiveBuffer = {};

  /// Tracks sequence numbers of all unique, processed packets for ACK generation.
  final Set<int> _receivedPacketSequences = {};

  /// Timestamp of when the packet that is currently the largest acknowledged arrived.
  DateTime? _largestAckedPacketArrivalTime;

  /// Timestamp of when the last ACK was sent.
  DateTime _lastAckSentTime = DateTime.now();

  /// Tracks sent packets for RTT calculation. Maps sequence number to a tuple of (send time, packet size).
  final Map<int, (DateTime, int)> _sentPackets = {};

  /// Tracks all sequence numbers ever acknowledged by the remote peer.
  final Set<int> _everAckedSequencesByRemote = {};

  /// Stores the highest sequence number N such that all packets 0...N are confirmed acknowledged by the remote.
  int _currentHighestCumulativeAckFromRemote = -1;

  /// Mirrors the CongestionController's _highestProcessedCumulativeAck. Stores the largestAcked value
  /// from the last ACK frame that advanced the CC's cumulative ACK point.
  int _ccMirrorOfHighestProcessedCumulativeAck = -1;

  /// The firewall function
  final bool Function(UDPSocket socket, int port, String host)? firewall;

  /// Creates a new UDX stream
  UDXStream(
    this.udx,
    this.id, {
    this.framed = false,
    this.initialSeq = 0,
    this.firewall,
    int? initialCwnd,
    CongestionController? congestionControllerForTest,
    PacketManager? packetManagerForTest,
    this.isInitiator = false,
  }) : _nextExpectedSeq = initialSeq {
    // With the circular dependency broken, we can initialize cleanly.
    // The order matters: PacketManager needs a CongestionController,
    // and CongestionController needs a PacketManager.
    // The new design is:
    // 1. CC constructor takes a PM.
    // 2. PM constructor takes an optional CC.
    // 3. PM has a `late` CC property.

    // This allows us to create the PM, then the CC, then link the CC back to the PM.
    packetManager = packetManagerForTest ?? PacketManager();
    _congestionController = congestionControllerForTest ??
        CongestionController(
            packetManager: packetManager, initialCwnd: initialCwnd);
    
    if (packetManagerForTest == null) {
      packetManager.congestionController = _congestionController;
    }

    _congestionController.onProbe = () {
      if (remoteId != null && _socket != null) {
        packetManager.sendProbe(_socket!.cids.remoteCid, _socket!.cids.localCid, remoteId!, id);
      }
    };
    _congestionController.onFastRetransmit = (sequence) {
      packetManager.retransmitPacket(sequence);
    };
    // Note: Removed onPacketPermanentlyLost callback that was causing stream crashes.
    // The QUIC-compliant PTO system in CongestionController now handles loss detection
    // without arbitrary retry limits that would crash streams.
  }

  void _handleRemoteConnectionWindowUpdate(UDXEvent event) {
    final eventData = event.data as Map<String, dynamic>?;
    final newMaxData = eventData?['maxData'] as int?;
    ////print('[UDXStream ${this.id}._handleRemoteConnectionWindowUpdate] Received event. New maxData from event: $newMaxData. Current socket: ${_socket?.hashCode}');
    if (_socket == null) {
      ////print('[UDXStream ${this.id}._handleRemoteConnectionWindowUpdate] Socket is null, cannot proceed.');
      return;
    }
    if (_drain != null && !_drain!.isCompleted) {
      // Use a local variable to avoid multiple null checks
      final socket = _socket;
      if (socket == null) {
        ////print('[UDXStream ${this.id}._handleRemoteConnectionWindowUpdate] Socket became null after initial check, cannot proceed.');
        return;
      }

      final connWindowAvailable = socket.getAvailableConnectionSendWindow();
      ////print('[UDXStream ${this.id}._handleRemoteConnectionWindowUpdate] Drain exists and not completed. connWin: $connWindowAvailable, remStrWin: $_remoteReceiveWindow, cwnd: $cwnd, inflight: $inflight');
      // Check all conditions again, similar to other places where _drain is completed
      if (inflight < cwnd && inflight < _remoteReceiveWindow && connWindowAvailable > 0) {
        ////print('[UDXStream ${this.id}._handleRemoteConnectionWindowUpdate] DEBUG: Unblocking by remoteConnectionWindowUpdate. connWin: $connWindowAvailable, remStrWin: $_remoteReceiveWindow, cwnd: $cwnd, inflight: $inflight');
        _drain!.complete();
      } else {
        ////print('[UDXStream ${this.id}._handleRemoteConnectionWindowUpdate] DEBUG: Conditions not met to unblock. inflight: $inflight, cwnd: $cwnd, _remoteReceiveWindow: $_remoteReceiveWindow, connWindowAvailable: $connWindowAvailable');
      }
    } else {
      ////print('[UDXStream ${this.id}._handleRemoteConnectionWindowUpdate] Drain is null or already completed. _drain: $_drain, isCompleted: ${_drain?.isCompleted}');
    }
  }

  /// Connects the stream to a remote endpoint
  Future<void> connect(
    UDPSocket socket,
    int remoteId,
    int port,
    String host,
  ) async {
    if (_connected) throw StateError('Stream is already connected');
    if (socket.closing) throw StateError('Socket is closing');

    _socket = socket;
    this.remoteId = remoteId;
    this.remoteHost = host;
    this.remotePort = port;
    this.remoteFamily = UDX.getAddressFamily(host);
    _connected = true;

    socket.registerStream(this);
    _remoteConnectionWindowUpdateSubscription?.cancel();
    _remoteConnectionWindowUpdateSubscription = _socket!.on('remoteConnectionWindowUpdate').listen(_handleRemoteConnectionWindowUpdate);
    ////print('[UDXStream ${this.id} Subscribing to remoteConnectionWindowUpdate on socket: ${_socket.hashCode}]');

    packetManager.onRetransmit = (packet) {
      //print('UDXStream ${this.id}: onRetransmit called for packet ${packet.sequence}');
      if (!_connected || _socket == null || remotePort == null || remoteHost == null) {
        //print('UDXStream ${this.id}: Cannot retransmit - not connected or missing socket/remote info');
        return;
      }
      if (_socket!.closing) {
        //print('UDXStream ${this.id}: Socket is closing, skipping packet retransmission.');
        return;
      }
      //print('UDXStream ${this.id}: Sending retransmitted packet ${packet.sequence}');
      _socket!.send(packet.toBytes());
    };

    packetManager.onSendProbe = (packet) {
      if (!_connected || _socket == null || remotePort == null || remoteHost == null) return;
      if (_socket!.closing) {
        ////print('[UDXStream ${this.id}.onSendProbe] Socket is closing, skipping probe packet send.');
        return;
      }
      _socket!.send(packet.toBytes());
    };

    emit('connect');
  }

  /// Handles an incoming socket event (datagram).
  void internalHandleSocketEvent(dynamic event) {
    final Uint8List rawData = event['data'] as Uint8List;
    final String sourceHost = event['address'] as String;
    final int sourcePort = event['port'] as int;

    // ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Received event from $sourceHost:$sourcePort. My remote: $remoteHost:$remotePort. My ID: $id, My remoteID: $remoteId');

    if (remoteHost == null || remotePort == null) {
      // ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Discarding: remoteHost or remotePort is null.');
      return;
    }
    if (sourceHost != remoteHost || sourcePort != remotePort) {
      // ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Discarding: Source $sourceHost:$sourcePort does not match expected remote $remoteHost:$remotePort.');
      return;
    }

    UDXPacket packet;
    try {
      packet = UDXPacket.fromBytes(rawData);
      // ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Parsed packet: DestID=${packet.destinationStreamId}, SrcID=${packet.sourceStreamId}, Seq=${packet.sequence}, Frames=${packet.frames.map((f) => f.type).toList()}');
    } catch (e) {
      ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Error parsing packet: $e');
      return;
    }

    if (packet.destinationStreamId != id) {
      // ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Discarding: Packet DestID ${packet.destinationStreamId} does not match my ID $id.');
      return;
    }

    if (remoteId == null) {
      // ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Discarding: My remoteId is null.');
      return;
    }
    if (packet.sourceStreamId != remoteId) {
      // ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Discarding: Packet SrcID ${packet.sourceStreamId} does not match my remoteId $remoteId.');
      return;
    }

    // ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Processing packet from $sourceHost:$sourcePort, DestID=${packet.destinationStreamId}, SrcID=${packet.sourceStreamId}, Seq=${packet.sequence}');

    bool needsAck = false;
    bool packetIsSequential = (packet.sequence == _nextExpectedSeq);
    bool containsAckElicitingFrames = packet.frames.any((f) => f is StreamFrame || f is PingFrame);

    // Process ACK and RESET frames first, as they are not sequence-dependent.
    for (final frame in packet.frames) {
      if (frame is ResetStreamFrame) {
        ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Immediate ResetStreamFrame: ErrorCode=${frame.errorCode}');
        addError(StreamResetError(frame.errorCode));
        _close(isReset: true);
        return; // Stop all further processing
      }
      if (frame is AckFrame) {
        // DIAGNOSTIC LOGGING START
        // ////print('[UDXStream $id internalHandleSocketEvent] ACK FRAME: largestAcked=${frame.largestAcked}, firstAckRangeLength=${frame.firstAckRangeLength}, ackRanges=${frame.ackRanges.map((r) => "G:${r.gap},L:${r.ackRangeLength}").toList()}');
        // ////print('[UDXStream $id internalHandleSocketEvent] PRE-ACK: _ccMirrorOfHighestProcessedCumulativeAck=$_ccMirrorOfHighestProcessedCumulativeAck');
        // DIAGNOSTIC LOGGING END

        // Let PacketManager update its internal state (_sentPackets, _retransmitTimers)
        final List<int> newlySackedSequences = packetManager.handleAckFrame(frame);

        // Update stream's own knowledge of all ever acked sequences (for _sendAck SACK generation)
        // and its true highest cumulative ack. This is independent of CC mirror logic below.
        // This is now handled by packetManager.handleAckFrame which updates _currentHighestCumulativeAckFromRemote
        // based on its internal processing of frame.largestAcked and frame.ackRanges.

        // Determine if this ACK frame advances the Congestion Controller's cumulative ACK point.
        // _currentHighestCumulativeAckFromRemote is updated by packetManager.handleAckFrame based on the frame's content.
        bool advancesCcCumulativePoint = _currentHighestCumulativeAckFromRemote > _ccMirrorOfHighestProcessedCumulativeAck;
        // DIAGNOSTIC LOGGING START
        // ////print('[UDXStream $id internalHandleSocketEvent] advancesCcCumulativePoint=$advancesCcCumulativePoint (_currentHighestCumulativeAckFromRemote=$_currentHighestCumulativeAckFromRemote > _ccMirrorOfHighestProcessedCumulativeAck=$_ccMirrorOfHighestProcessedCumulativeAck)');
        // DIAGNOSTIC LOGGING END

        // This is the largest value that the CC should consider as its new cumulative ACK point if advancesCcCumulativePoint is true.
        // If not advancing, CC should use its old _ccMirrorOfHighestProcessedCumulativeAck for context.
        // final int effectiveCumulativeAckForCC = advancesCcCumulativePoint ? _currentHighestCumulativeAckFromRemote : _ccMirrorOfHighestProcessedCumulativeAck; // Old logic
        final int largestAckedInThisFrame = frame.largestAcked; // New logic: always pass frame.largestAcked as the 5th arg to onPacketAcked

        if (newlySackedSequences.isNotEmpty) {
          for (final ackedSeq in newlySackedSequences) {
            final sentPacketInfo = _sentPackets.remove(ackedSeq);
            if (sentPacketInfo != null) {
              final (sentTime, ackedSize) = sentPacketInfo;

              // A packet contributes to a new cumulative ACK for the CC if:
              // 1. The CC's overall cumulative point is advancing in this frame (advancesCcCumulativePoint is true)
              // 2. This specific packet (ackedSeq) falls within the range of this new advancement.
              //    It must be greater than the CC's old mirror and less than or equal to the stream's new true cumulative ack.
              bool isNewCumulativeForCCArg = advancesCcCumulativePoint &&
                                          ackedSeq > _ccMirrorOfHighestProcessedCumulativeAck &&
                                          ackedSeq <= _currentHighestCumulativeAckFromRemote;
              // DIAGNOSTIC LOGGING START
              // ////print('[UDXStream $id internalHandleSocketEvent] CALLING _congestionController.onPacketAcked: ackedSeq=$ackedSeq, ackedSize=$ackedSize, sentTime=$sentTime, ackDelayMs=${frame.ackDelay}, isNewCumulativeForCC=$isNewCumulativeForCCArg, currentFrameLargestAckedValueToPass=${largestAckedInThisFrame}');
              // DIAGNOSTIC LOGGING END
              _congestionController.onPacketAcked(
                ackedSize,
                sentTime,
                Duration(milliseconds: frame.ackDelay),
                isNewCumulativeForCCArg,
                largestAckedInThisFrame // Pass frame.largestAcked as the 5th argument
              );

              // Update connection-level window accounting
              if (_socket != null) {
                _socket!.decrementConnectionBytesSent(ackedSize);
              }

              // Clean up retransmission attempt tracking for acknowledged packets
              _retransmissionAttempts.remove(ackedSeq);

              emit('ack', ackedSeq);

              if (_drain != null && !_drain!.isCompleted) {
                final connWindowAvailable = _socket?.getAvailableConnectionSendWindow() ?? 0;
                if (inflight < cwnd && inflight < _remoteReceiveWindow && connWindowAvailable > 0) {
                  _drain!.complete();
                }
              }
            }
          }
        }

        if (advancesCcCumulativePoint) {
          _ccMirrorOfHighestProcessedCumulativeAck = _currentHighestCumulativeAckFromRemote;
        } else {
          // If the CC's cumulative point did not advance with this frame (advancesCcCumulativePoint is false),
          // then this ACK frame, from the CC's perspective of its *own* cumulative progress,
          // acts as a duplicate ACK for the sequence number it was expecting next (_ccMirrorOfHighestProcessedCumulativeAck + 1).
          // We pass _ccMirrorOfHighestProcessedCumulativeAck to processDuplicateAck because that's the
          // highest cumulative point the CC has processed so far.
          // DIAGNOSTIC LOGGING START
          // ////print('[UDXStream $id internalHandleSocketEvent] CALLING _congestionController.processDuplicateAck: _ccMirrorOfHighestProcessedCumulativeAck=$_ccMirrorOfHighestProcessedCumulativeAck (because CC cumulative point did not advance)');
          // DIAGNOSTIC LOGGING END
          _congestionController.processDuplicateAck(_ccMirrorOfHighestProcessedCumulativeAck);
        }
        // DIAGNOSTIC LOGGING START
        // ////print('[UDXStream $id internalHandleSocketEvent] POST-ACK: _ccMirrorOfHighestProcessedCumulativeAck=$_ccMirrorOfHighestProcessedCumulativeAck');
        // DIAGNOSTIC LOGGING END
        // TODO: Handle ECN counts from ACK frame if ECN is implemented.
      }
    }

    if (packetIsSequential) {
      // This packet is the next expected one. Process its frames.
      ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Processing sequential packet: Seq=${packet.sequence}');
      _receivedPacketSequences.add(packet.sequence); // Track for ACK generation
      _largestAckedPacketArrivalTime = DateTime.now(); // Update arrival time for potential largest_acked

      for (final frame in packet.frames) {
        if (frame is StreamFrame) {
          ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Sequential StreamFrame: DataLen=${frame.data.length}, IsFin=${frame.isFin}');
          needsAck = true;
          if (frame.data.isNotEmpty) {
            ////print('[DEBUG] UDXStream ${this.id} adding data to _dataController: ${frame.data.length} bytes');
            _dataController.add(frame.data);
            if (_socket != null && remoteHost != null && remotePort != null) {
              _socket!.onStreamDataProcessed(frame.data.length);
            }
          }
          if (frame.isFin) {
            ////print('[DEBUG] UDXStream ${this.id} closing _dataController due to FIN flag');
            _dataController.close();
          }
        } else if (frame is PingFrame) {
          ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Sequential PingFrame.');
          needsAck = true;
        } else if (frame is WindowUpdateFrame) {
          ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Sequential WindowUpdateFrame: Size=${frame.windowSize}');
          _remoteReceiveWindow = frame.windowSize;
          if (_drain != null && !_drain!.isCompleted) {
            final connWindowAvailable = _socket?.getAvailableConnectionSendWindow() ?? 0;
            if (inflight < cwnd && inflight < _remoteReceiveWindow && connWindowAvailable > 0) {
              _drain!.complete();
            }
          }
          emit('drain');
        } else if (frame is MaxDataFrame) {
            ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Sequential MaxDataFrame (unusual in stream context but handling): Size=${frame.maxData}');
             if (_drain != null && !_drain!.isCompleted) {
               final connWindowAvailable = _socket?.getAvailableConnectionSendWindow() ?? 0;
                if (inflight < cwnd && inflight < _remoteReceiveWindow && connWindowAvailable > 0) {
                  _drain!.complete();
                }
            }
        }
        // AckFrames and ResetStreamFrames are handled above and don't affect sequential processing here.
      }
      _nextExpectedSeq++; // Advance expected sequence *after* processing all frames in this sequential packet
      _processReceiveBuffer(sourceHost, sourcePort);
    } else if (packet.sequence > _nextExpectedSeq) {
      // Packet is for the future. Buffer if it contains stream data.
      bool hasStreamDataContent = packet.frames.any((f) => f is StreamFrame && (f.data.isNotEmpty || f.isFin));
      if (hasStreamDataContent) {
        ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Buffering out-of-order packet with StreamFrame(s): Seq=${packet.sequence}, ExpectedSeq=$_nextExpectedSeq.');
        _receiveBuffer[packet.sequence] = packet; // Buffer the whole packet
      } else {
        ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Received out-of-order packet without StreamFrames (e.g. just ACK or future PING): Seq=${packet.sequence}. Processing relevant frames.');
      }
      // Always ACK out-of-order packets that might contain data or PINGs to help sender with loss detection/recovery.
      // AckFrames themselves don't need this type of ACK.
      if (containsAckElicitingFrames) {
        _receivedPacketSequences.add(packet.sequence); // Add to sequences for SACKing
        // _largestAckedPacketArrivalTime will be updated in _sendAck based on the full _receivedPacketSequences
        needsAck = true;
      }
    } else { // packet.sequence < _nextExpectedSeq
      // Packet is older than expected, likely a duplicate.
      ////print('[UDXStream ${this.id}.internalHandleSocketEvent] Discarding old/duplicate packet: Seq=${packet.sequence}, ExpectedSeq=$_nextExpectedSeq.');
      // Still ACK if it contained frames that would normally be ACKed (Stream, Ping)
      // This ensures SACKs are sent even for duplicates, helping sender confirm receipt.
      if (containsAckElicitingFrames) {
        _receivedPacketSequences.add(packet.sequence); // Add to sequences for SACKing
        needsAck = true;
      }
    }

    if (needsAck) {
      _sendAck();
    }
  }

  void _processReceiveBuffer(String sourceHost, int sourcePort) {
    while (_receiveBuffer.containsKey(_nextExpectedSeq)) {
      final bufferedPacket = _receiveBuffer.remove(_nextExpectedSeq)!;
      _receivedPacketSequences.add(bufferedPacket.sequence); // Track for ACK generation
      _largestAckedPacketArrivalTime = DateTime.now(); // Update arrival time

      for (final frame in bufferedPacket.frames) {
        if (frame is StreamFrame) {
          if (frame.data.isNotEmpty) {
            ////print('[DEBUG] UDXStream ${this.id} _processReceiveBuffer adding data to _dataController: ${frame.data.length} bytes');
            _dataController.add(frame.data);
            if (_socket != null) {
              _socket!.onStreamDataProcessed(frame.data.length);
            }
          }
          if (frame.isFin) {
            ////print('[DEBUG] UDXStream ${this.id} _processReceiveBuffer closing _dataController due to FIN flag');
            _dataController.close();
          }
        }
      }
      _nextExpectedSeq++;
    }
  }

  void _sendAck() {
    if (!_connected || remotePort == null || remoteHost == null || remoteId == null) {
      return;
    }

    // Use a local variable to avoid multiple null checks
    final socket = _socket;
    if (socket == null) {
      ////print('[UDXStream ${this.id}._sendAck] Socket is null, cannot send ACK.');
      return;
    }

    if (socket.closing) {
      ////print('[UDXStream ${this.id}._sendAck] Socket is closing, skipping ACK send.');
      return;
    }

    if (_receivedPacketSequences.isEmpty) {
      return;
    }

    final sortedSequences = _receivedPacketSequences.toList()..sort();
    if (sortedSequences.isEmpty) return;

    final int largestAcked = sortedSequences.last;
    int ackDelayMs = 0;
    if (_largestAckedPacketArrivalTime != null) {
      ackDelayMs = DateTime.now().difference(_largestAckedPacketArrivalTime!).inMilliseconds;
      ackDelayMs = ackDelayMs.clamp(0, 65535); // Clamp to Uint16 range
    }

    List<AckRange> ackRanges = [];
    int firstAckRangeLength = 0;

    // Generate ranges based on QUIC ACK frame logic
    // Convert sorted sequence numbers into {start, end} blocks
    List<Map<String, int>> blocks = [];
    if (sortedSequences.isNotEmpty) {
      int blockStart = sortedSequences[0];
      for (int i = 0; i < sortedSequences.length; i++) {
        if (i + 1 < sortedSequences.length && sortedSequences[i + 1] == sortedSequences[i] + 1) {
          // Continue current block
        } else {
          // End of a block
          blocks.add({'start': blockStart, 'end': sortedSequences[i]});
          if (i + 1 < sortedSequences.length) {
            blockStart = sortedSequences[i + 1];
          }
        }
      }
    }

    // Blocks are now [{start: S1, end: E1}, {start: S2, end: E2}, ...] sorted by sequence number
    // The last block in `blocks` corresponds to the "Largest Acknowledged" range.
    if (blocks.isNotEmpty) {
      final lastBlock = blocks.removeLast(); // This is the block containing largestAcked
      firstAckRangeLength = lastBlock['end']! - lastBlock['start']! + 1;
      // largestAcked is already set to sortedSequences.last, which is lastBlock['end']

      // Remaining blocks in `blocks` (if any) become the additional ACK ranges.
      // These need to be ordered from highest sequence to lowest for the AckFrame.
      // The `blocks` list is already sorted by increasing sequence, so iterate backwards.
      int prevBlockStartSeq = lastBlock['start']!; // Start of the range just processed (firstAckRange)

      for (int i = blocks.length - 1; i >= 0; i--) {
        final currentBlock = blocks[i];
        final currentBlockStart = currentBlock['start']!;
        final currentBlockEnd = currentBlock['end']!;

        // Gap = (start of previous higher-sequence block) - (end of current block) - 1
        final int gap = prevBlockStartSeq - currentBlockEnd - 1;
        final int rangeLength = currentBlockEnd - currentBlockStart + 1;

        ackRanges.add(AckRange(gap: gap, ackRangeLength: rangeLength));
        prevBlockStartSeq = currentBlockStart;
      }
    } else {
      // Should not happen if sortedSequences was not empty, but as a fallback:
      firstAckRangeLength = 0; // Or 1 if we consider largestAcked itself as a range of 1
    }

    // Ensure firstAckRangeLength is at least 1 if largestAcked is valid
     if (firstAckRangeLength == 0 && sortedSequences.isNotEmpty) {
        firstAckRangeLength = 1; // Smallest possible range for the largest_acked
    }


    final ackFrame = AckFrame(
      largestAcked: largestAcked,
      ackDelay: ackDelayMs,
      firstAckRangeLength: firstAckRangeLength,
      ackRanges: ackRanges,
    );

    final ackPacket = UDXPacket(
      destinationCid: _socket!.cids.remoteCid,
      sourceCid: _socket!.cids.localCid,
      destinationStreamId: remoteId!,
      sourceStreamId: id,
      sequence: packetManager.nextSequence, // ACKs should have their own sequence numbers
      frames: [ackFrame],
    );

    socket.send(ackPacket.toBytes());
    // ////print('[UDXStream ${this.id} SENT_ACK] LargestAcked: $largestAcked, Delay: $ackDelayMs, FirstRangeLen: $firstAckRangeLength, Ranges: ${ackRanges.map((r) => "G:${r.gap},L:${r.ackRangeLength}").toList()}');

    _receivedPacketSequences.clear();
    _lastAckSentTime = DateTime.now();
    _largestAckedPacketArrivalTime = null; // Reset as the info is now sent
  }

  @override
  Future<void> add(Uint8List data) async {
    if (!_connected) throw StateError('UDXStream ($id): Stream is not connected');
    if (_socket == null) throw StateError('UDXStream ($id): Stream is not connected to a socket');

    // DEBUG: Log window states at the beginning of add
    if (_socket != null) {
      // Use a local variable to avoid multiple null checks
      final socket = _socket;
      if (socket == null) {
        ////print('[UDXStream ${this.id}.add] Socket became null after initial check, cannot proceed.');
        throw StateError('UDXStream ($id): Socket became null during operation');
      }
      ////print('[UDXStream ${this.id} (${this.remoteHost}:${this.remotePort} rID:${this.remoteId}).add ENTRY] DEBUG: Initial available conn window: ${socket.getAvailableConnectionSendWindow()}, remoteStreamWindow: $_remoteReceiveWindow, cwnd: $cwnd, inflight: $inflight, data.length: ${data.length}');
    }
    if (remoteId == null || remoteHost == null || remotePort == null) {
      throw StateError('UDXStream ($id): Remote peer details not set');
    }
    if (data.isEmpty) {
      return;
    }

    // Fragment the data according to MTU size if needed
    final fragments = _fragmentData(data);

    for (final fragment in fragments) {
      await _sendFragment(fragment);
    }

    emit('send', data);
  }

  // Helper method to fragment data according to MTU size
  List<Uint8List> _fragmentData(Uint8List data) {
    final fragments = <Uint8List>[];
    int offset = 0;

    while (offset < data.length) {
      final end = min(offset + _maxPayloadSize, data.length);
      final fragment = Uint8List.sublistView(data, offset, end);
      fragments.add(fragment);
      offset = end;
    }

    return fragments;
  }

  // Helper method to send a single fragment
  Future<void> _sendFragment(Uint8List fragment) async {
    // Check if socket is null before entering the loop
    final socket = _socket;
    if (socket == null) {
      ////print('[UDXStream ${this.id}._sendFragment] Socket is null, cannot proceed.');
      throw StateError('UDXStream ($id): Socket is null during operation');
    }

    // Wait for the handshake to complete with timeout tolerance
    try {
      await socket.handshakeComplete.timeout(
        Duration(seconds: packetTimeoutTolerance),
        onTimeout: () {
          // Don't throw error, just log and continue - handshake timeouts should not kill the stream
          ////print('[UDXStream ${this.id}._sendFragment] Handshake timeout after ${packetTimeoutTolerance}s, proceeding anyway');
        },
      );
    } catch (e) {
      // Handshake timeout or error - log but don't escalate to stream failure
      ////print('[UDXStream ${this.id}._sendFragment] Handshake error: $e, proceeding with send attempt');
    }

    // Add a timeout to prevent indefinite blocking
    final completer = Completer<void>();
    Timer? timeoutTimer;

    // Non-blocking check with periodic retry
    void checkAndSend() {
      final connWindowAvailable = socket.getAvailableConnectionSendWindow();

      // Log the current state for debugging
      ////print('[UDXStream ${this.id}._sendFragment CHECK] connWin: $connWindowAvailable, remStrWin: $_remoteReceiveWindow, cwnd: $cwnd, inflight: $inflight');

      if (inflight < cwnd && 
          inflight < _remoteReceiveWindow && 
          connWindowAvailable > 0) {
        // Conditions met, proceed with sending
        if (!completer.isCompleted) {
          ////print('[UDXStream ${this.id}._sendFragment] Window conditions met, proceeding with send');
          completer.complete();
        }
      } else {
        // Conditions not met, set up drain completer if needed
        if (_drain == null || _drain!.isCompleted) {
          _drain = Completer<void>();
          ////print('[UDXStream ${this.id}._sendFragment BLOCKED] New _drain created. connWin: $connWindowAvailable, remStrWin: $_remoteReceiveWindow, cwnd: $cwnd, inflight: $inflight');
        }

        // Retry after a short delay
        Timer(Duration(milliseconds: 50), checkAndSend);
      }
    }

    // Start the timeout timer - use packet timeout tolerance instead of hard failure
    timeoutTimer = Timer(Duration(seconds: packetTimeoutTolerance), () {
      if (!completer.isCompleted) {
        ////print('[UDXStream ${this.id}._sendFragment] Timed out waiting for send window after ${packetTimeoutTolerance}s. Proceeding with send attempt.');
        completer.complete();
      }
    });

    // Start the check process
    checkAndSend();

    try {
      await completer.future;
    } finally {
      timeoutTimer?.cancel();
    }

    // After window checks pass, wait for the pacer with timeout
    try {
      await _congestionController.pacingController.waitUntilReady().timeout(
        Duration(seconds: 5),
        onTimeout: () {
          // Pacing timeout - log but don't fail the stream
          ////print('[UDXStream ${this.id}._sendFragment] Pacing timeout, proceeding without pacing');
        },
      );
    } catch (e) {
      // Pacing error - log but continue
      ////print('[UDXStream ${this.id}._sendFragment] Pacing error: $e, proceeding without pacing');
    }

    // Check if socket is still valid before proceeding
    final currentSocket = _socket;
    if (currentSocket == null) {
      ////print('[UDXStream ${this.id}._sendFragment] Socket became null after waiting, cannot proceed.');
      throw StateError('UDXStream ($id): Socket became null during operation');
    }

    // DEBUG: Log when proceeding with send
    ////print('[UDXStream ${this.id}._sendFragment SENDING] connWin: ${currentSocket.getAvailableConnectionSendWindow()}, remStrWin: $_remoteReceiveWindow, cwnd: $cwnd, inflight: $inflight');

    // Create and send the packet
    // //print( '[STRM $id] Sending fragment. Using remoteCid: ${_socket?.cids.remoteCid}, localCid: ${_socket?.cids.localCid}');
    final packet = UDXPacket(
      destinationCid: _socket!.cids.remoteCid,
      sourceCid: _socket!.cids.localCid,
      destinationStreamId: remoteId!,
      sourceStreamId: id,
      sequence: packetManager.nextSequence,
      frames: [StreamFrame(data: fragment)],
    );

    // Log the data packet being sent
    //print('[UDXStream ${this.id} SENDING_PACKET] Seq=${packet.sequence}, FragmentLen=${fragment.length}, DestID=${packet.destinationStreamId}, SrcID=${packet.sourceStreamId}, HasSocket=${_socket != null}');

    _sentPackets[packet.sequence] = (DateTime.now(), fragment.length);
    // Initialize retransmission attempt counter for this packet
    _retransmissionAttempts[packet.sequence] = 0;
    
    //print('[UDXStream ${this.id}] About to call packetManager.sendPacket for packet ${packet.sequence}');
    packetManager.sendPacket(packet);
    //print('[UDXStream ${this.id}] Called packetManager.sendPacket for packet ${packet.sequence}');
    _congestionController.onPacketSent(fragment.length);

    if (remotePort != null && remoteHost != null) {
      // Check if socket is still valid before sending
      final sendSocket = _socket;
      if (sendSocket == null) {
        ////print('[UDXStream ${this.id}._sendFragment] Socket became null before sending packet, cannot proceed.');
        throw StateError('UDXStream ($id): Socket became null during operation');
      }

      if (sendSocket.closing) {
        ////print('[UDXStream ${this.id}._sendFragment] Socket is closing, skipping data packet send.');
        // Don't throw an error, just return and let the stream close gracefully
        return;
      }

      try {
        sendSocket.send(packet.toBytes());
        sendSocket.incrementConnectionBytesSent(fragment.length);
        // Inform the pacer that a packet was sent
        _congestionController.pacingController.onPacketSent(packet.toBytes().length);
      } catch (e) {
        // Socket send error - log but don't escalate to stream failure
        ////print('[UDXStream ${this.id}._sendFragment] Socket send error: $e, packet will be retransmitted by PTO system');
        // The PTO system will handle retransmission, so we don't need to throw here
      }
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    emit('error', error);
    if (!_dataController.isClosed) {
      _dataController.addError(error, stackTrace);
    }
  }

  @override
  Future<void> addStream(Stream<Uint8List> stream) async {
    await for (final data in stream) {
      await add(data);
    }
  }

  @override
  Future<void> get done => _dataController.done;

  void setWindow(int newSize) {
    _receiveWindow = newSize;
    if (_connected && remoteId != null && remoteHost != null && remotePort != null) {
      // Use a local variable to avoid multiple null checks
      final socket = _socket;
      if (socket == null) {
        ////print('[UDXStream ${this.id}.setWindow] Socket is null, cannot send window update.');
        return;
      }

      if (socket.closing) {
        ////print('[UDXStream ${this.id}.setWindow] Socket is closing, skipping window update send.');
        return;
      }

      final windowUpdatePacket = UDXPacket(
        destinationCid: _socket!.cids.remoteCid,
        sourceCid: _socket!.cids.localCid,
        destinationStreamId: remoteId!,
        sourceStreamId: id,
        sequence: packetManager.nextSequence,
        frames: [WindowUpdateFrame(windowSize: _receiveWindow)],
      );
      socket.send(windowUpdatePacket.toBytes());
    }
  }

  /// Abruptly terminates the stream by sending a RESET_STREAM frame.
  Future<void> reset(int errorCode) async {
    if (!_connected) return;

    if (remoteId != null && remoteHost != null && remotePort != null) {
      // Use a local variable to avoid multiple null checks
      final socket = _socket;
      if (socket == null) {
        ////print('[UDXStream ${this.id}.reset] Socket is null, cannot send reset frame.');
        // Continue with local close even if we can't send the reset frame
      } else {
        final resetPacket = UDXPacket(
          destinationCid: _socket!.cids.remoteCid,
          sourceCid: _socket!.cids.localCid,
          destinationStreamId: remoteId!,
          sourceStreamId: id,
          sequence: packetManager.nextSequence,
          frames: [ResetStreamFrame(errorCode: errorCode)],
        );
        try {
          // This is a "fire-and-forget" send. We don't wait for an ACK.
          socket.send(resetPacket.toBytes());
        } catch (e) {
          // Ignore errors during reset, as the stream is being torn down.
        }
      }
    }

    // Immediately transition to a closed state locally.
    await _close(isReset: true);
  }

  @override
  Future<void> close() async {
    await _close();
  }

  /// Internal close logic, handling both graceful (FIN) and abrupt (reset) closures.
  Future<void> _close({bool isReset = false}) async {
    if (!_connected) return;

    if (!isReset && remoteId != null && remoteHost != null && remotePort != null) {
      // Use a local variable to avoid multiple null checks
      final socket = _socket;
      if (socket == null) {
        ////print('[UDXStream ${this.id}._close] Socket is null, cannot send FIN packet.');
        // Continue with local close even if we can't send the FIN packet
      } else {
        final finPacket = UDXPacket(
          destinationCid: _socket!.cids.remoteCid,
          sourceCid: _socket!.cids.localCid,
          destinationStreamId: remoteId!,
          sourceStreamId: id,
          sequence: packetManager.nextSequence,
          frames: [StreamFrame(data: Uint8List(0), isFin: true)],
        );
        try {
          ////print('[UDXStream ${this.id}._close] Sending FIN packet: Seq=${finPacket.sequence}');
          _sentPackets[finPacket.sequence] = (DateTime.now(), 0); // FIN packet has 0 data size

          // Check if socket is closing before attempting to send
          if (!socket.closing) {
            socket.send(finPacket.toBytes());
            packetManager.sendPacket(finPacket);
            // Add a small delay to ensure the FIN packet is sent before closing the stream
            await Future.delayed(Duration(milliseconds: 50));
          } else {
            ////print('[UDXStream ${this.id}._close] Socket is closing, skipping FIN packet send.');
          }
        } catch (e) {
          ////print('[UDXStream ${this.id}._close] Error sending FIN packet: $e');
          // Ignore errors
        }
      }
    }

    _connected = false;

    try {
      if (!_dataController.isClosed) {
        _dataController.close();
      }
      _socket?.unregisterStream(id);

      ////print('[UDXStream ${this.id} close] Attempting to cancel _remoteConnectionWindowUpdateSubscription: ${_remoteConnectionWindowUpdateSubscription?.hashCode}');
      await _remoteConnectionWindowUpdateSubscription?.cancel();
      ////print('[UDXStream ${this.id} close] Called cancel on _remoteConnectionWindowUpdateSubscription: ${_remoteConnectionWindowUpdateSubscription?.hashCode}');
      _remoteConnectionWindowUpdateSubscription = null;

      packetManager.destroy();
      _congestionController.destroy();
      _sentPackets.clear();

      emit('close');
    } catch (e) {
      emit('error', e);
      rethrow;
    } finally {
      super.close();
    }
  }

  Stream<Uint8List> get data => _dataController.stream;
  Stream<void> get end => on('end').map((_) => null);
  Stream<void> get drain => on('drain').map((_) => null);
  Stream<int> get ack => on('ack').map((event) => event.data as int);
  Stream<Uint8List> get send => on('send').map((event) => event.data as Uint8List);
  Stream<Uint8List> get message => on('message').map((event) => event.data as Uint8List);
  Stream<void> get closeEvents => on('close').map((_) => null);

  static Future<UDXStream> createOutgoing(
    UDX udx,
    UDPSocket socket,
    int localId,
    int remoteId,
    String host,
    int port, {
    bool framed = false,
    int initialSeq = 0,
    int? initialCwnd,
    bool Function(UDPSocket socket, int port, String host)? firewall,
  }) async {
    if (socket.closing) {
      throw StateError('UDXStream.createOutgoing: Socket is closing');
    }

    if (!socket.canCreateNewStream()) {
      throw StreamLimitExceededError('Cannot create new stream: remote peer stream limit reached.');
    }
    socket.incrementOutgoingStreams();


    final stream = UDXStream(
      udx,
      localId,
      isInitiator: true,
      initialCwnd: initialCwnd,
      framed: framed,
      initialSeq: initialSeq,
      firewall: firewall,
    );
    stream._socket = socket;
    stream.remoteId = remoteId;
    stream.remoteHost = host;
    stream.remotePort = port;
    stream.remoteFamily = UDX.getAddressFamily(host);
    socket.registerStream(stream);
    stream._remoteConnectionWindowUpdateSubscription?.cancel();
    stream._remoteConnectionWindowUpdateSubscription = stream._socket!.on('remoteConnectionWindowUpdate').listen(stream._handleRemoteConnectionWindowUpdate);
    ////print('[UDXStream ${stream.id} Subscribing to remoteConnectionWindowUpdate on socket: ${stream._socket.hashCode}]');
    stream._connected = true;

    stream.packetManager.onRetransmit = (packet) {
      if (!stream.connected || stream._socket == null || stream.remotePort == null || stream.remoteHost == null) return;
      if (stream._socket!.closing) {
        ////print('[UDXStream ${stream.id}.onRetransmit] Socket is closing, skipping packet retransmission.');
        return;
      }
      stream._socket!.send(packet.toBytes());
    };
    stream.packetManager.onSendProbe = (packet) {
      if (!stream.connected || stream._socket == null || stream.remotePort == null || stream.remoteHost == null) return;
      if (stream._socket!.closing) {
        ////print('[UDXStream ${stream.id}.onSendProbe] Socket is closing, skipping probe packet send.');
        return;
      }
      stream._socket!.send(packet.toBytes());
    };

    // //print( '[STRM $localId] Creating outgoing SYN packet. Using remoteCid: ${socket.cids.remoteCid}, localCid: ${socket.cids.localCid}');
    final initialPacket = UDXPacket(
      destinationCid: socket.cids.remoteCid,
      sourceCid: socket.cids.localCid,
      destinationStreamId: remoteId,
      sourceStreamId: localId,
      sequence: stream.packetManager.nextSequence,
      frames: [StreamFrame(data: Uint8List(0), isSyn: true)],
    );

    // Log the initial packet being sent
    ////print('[UDXStream ${stream.id} CREATE_OUTGOING_SENDING_INITIAL_PACKET] Seq=${initialPacket.sequence}, DestID=${initialPacket.destinationStreamId}, SrcID=${initialPacket.sourceStreamId}');

    try {
      stream._sentPackets[initialPacket.sequence] = (DateTime.now(), 0); // SYN packet has 0 data size
      if (stream._socket != null && stream.remotePort != null && stream.remoteHost != null) {
        if (!stream._socket!.closing) {
          stream._socket!.send(initialPacket.toBytes());
        } else {
          ////print('[UDXStream ${stream.id}.createOutgoing] Socket is closing, skipping initial packet send.');
        }
      }
      stream.packetManager.sendPacket(initialPacket);
      stream._congestionController.onPacketSent(0);

      if (stream._socket != null && stream.remoteHost != null && stream.remotePort != null) {
        if (!stream._socket!.closing) {
          await stream._socket!.sendMaxDataFrame(
            UDPSocket.defaultInitialConnectionWindow
          );
          await stream._socket!.sendMaxStreamsFrame();
          ////print('[UDXStream.createOutgoing] DEBUG: Attempted to send MaxDataFrame for stream ${stream.id} to ${stream.remoteHost}:${stream.remotePort}');
        } else {
          ////print('[UDXStream ${stream.id}.createOutgoing] Socket is closing, skipping MaxDataFrame send.');
        }
      }
    } catch (e) {
      await stream.close(); 
      rethrow;
    }

    stream.emit('connect');
    return stream;
  }

  static UDXStream createIncoming(
    UDX udx,
    UDPSocket socket,
    int localId,
    int remoteId,
    String host,
    int port, {
    required ConnectionId destinationCid,
    required ConnectionId sourceCid,
    bool framed = false,
    int initialSeq = 0,
    int? initialCwnd,
    bool Function(UDPSocket socket, int port, String host)? firewall,
  }) {
    if (socket.closing) {
      throw StateError('UDXStream.createIncoming: Socket is closing');
    }
    final stream = UDXStream(
      udx,
      localId,
      isInitiator: false,
      initialCwnd: initialCwnd,
      framed: framed,
      initialSeq: initialSeq,
      firewall: firewall,
    );
    stream._socket = socket;
    stream.remoteId = remoteId;
    stream.remoteHost = host;
    stream.remotePort = port;
    stream.remoteFamily = UDX.getAddressFamily(host);
    socket.registerStream(stream);
    stream._remoteConnectionWindowUpdateSubscription?.cancel();
    stream._remoteConnectionWindowUpdateSubscription = stream._socket!.on('remoteConnectionWindowUpdate').listen(stream._handleRemoteConnectionWindowUpdate);
    ////print('[UDXStream ${stream.id} Subscribing to remoteConnectionWindowUpdate on socket: ${stream._socket.hashCode}]');
    stream._connected = true;

    // Manually process the initial SYN packet to send a SYN-ACK
    final initialPacketBytes = socket.popInitialPacket(localId);
    if (initialPacketBytes != null) {
      try {
        final synPacket = UDXPacket.fromBytes(initialPacketBytes);
        // We received a SYN, so we must ACK it.
        // The next expected sequence from the peer is their sequence + 1.
        stream._nextExpectedSeq = synPacket.sequence + 1;
        stream._receivedPacketSequences.add(synPacket.sequence);
        stream._largestAckedPacketArrivalTime = DateTime.now();

        // Construct and send the SYN-ACK packet immediately.
        final synAckPacket = UDXPacket(
          destinationCid: sourceCid, // The incoming packet's source is our destination
          sourceCid: destinationCid, // Our source is the incoming packet's destination
          destinationStreamId: remoteId,
          sourceStreamId: localId,
          sequence: stream.packetManager.nextSequence,
          frames: [
            // The SYN part of the SYN-ACK
            StreamFrame(data: Uint8List(0), isSyn: true),
            // The ACK part of the SYN-ACK
            AckFrame(
              largestAcked: synPacket.sequence,
              ackDelay: 0,
              firstAckRangeLength: 1,
              ackRanges: [],
            ),
          ],
        );

        // Send the packet and register it for potential retransmission
        stream._sentPackets[synAckPacket.sequence] = (DateTime.now(), 0); // SYN-ACK has 0 data size
        socket.send(synAckPacket.toBytes());
        stream.packetManager.sendPacket(synAckPacket);
        stream._congestionController.onPacketSent(0);

      } catch (e) {
        // If parsing fails, close the stream with an error.
        stream.addError(StateError('Failed to parse initial SYN packet: $e'));
        stream.close();
      }
    }

    stream.packetManager.onRetransmit = (packet) {
      if (!stream.connected || stream._socket == null || stream.remotePort == null || stream.remoteHost == null) return;
      if (stream._socket!.closing) {
        ////print('[UDXStream ${stream.id}.onRetransmit] Socket is closing, skipping packet retransmission.');
        return;
      }
      stream._socket!.send(packet.toBytes());
    };
    stream.packetManager.onSendProbe = (packet) {
      if (!stream.connected || stream._socket == null || stream.remotePort == null || stream.remoteHost == null) return;
      if (stream._socket!.closing) {
        ////print('[UDXStream ${stream.id}.onSendProbe] Socket is closing, skipping probe packet send.');
        return;
      }
      stream._socket!.send(packet.toBytes());
    };

    if (stream._socket != null && stream.remoteHost != null && stream.remotePort != null) {
      if (!stream._socket!.closing) {
        stream._socket!.sendMaxDataFrame(
          UDPSocket.defaultInitialConnectionWindow
        );
        ////print('[UDXStream.createIncoming] DEBUG: Attempted to send MaxDataFrame for stream ${stream.id} to ${stream.remoteHost}:${stream.remotePort}');
      } else {
        ////print('[UDXStream ${stream.id}.createIncoming] Socket is closing, skipping MaxDataFrame send.');
      }
    }

    stream.emit('accepted');
    return stream;
  }

  // --- Test Hooks ---
  Map<int, (DateTime, int)> getSentPacketsTestHook() => _sentPackets;
  // Calculate max payload size based on default MTU (1400) minus headers (16)
  static int getMaxPayloadSizeTestHook() => 1400 - 16;

  /// Sets the internal socket. For testing purposes only.
  void setSocketForTest(UDPSocket? socket) {
    _socket = socket;
  }
}
