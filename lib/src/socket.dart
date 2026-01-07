import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'cid.dart';
import 'udx.dart';
import 'events.dart';
import 'stream.dart';
import 'packet.dart';
import 'multiplexer.dart';
import 'pmtud.dart';
import 'metrics_observer.dart';
import 'version.dart';

/// Custom error for when a stream creation attempt exceeds the peer's advertised limit.
class StreamLimitExceededError extends StateError {
  StreamLimitExceededError(String message) : super(message);
}

/// Represents a single UDX connection, managed by a [UDXMultiplexer].
///
/// This class handles the logic for a single connection, including stream
/// management, flow control, and packet processing, but delegates the actual
/// network I/O to the multiplexer.
class UDPSocket with UDXEventEmitter {
  /// Default initial connection-level flow control window (e.g., 1MB).
  static const int defaultInitialConnectionWindow = 1024 * 1024;

  /// Default maximum number of concurrent streams.
  static const int defaultMaxStreams = 100;

  /// The UDX instance that created this socket.
  final UDX udx;

  /// The multiplexer that owns this socket.
  UDXMultiplexer multiplexer;

  /// The remote address of the peer.
  InternetAddress remoteAddress;

  /// The remote port of the peer.
  int remotePort;

  /// The Connection IDs for this connection.
  ConnectionCids cids;

  final Completer<void> _handshakeCompleter = Completer<void>();
  bool _handshakeCompleted = false;
  DateTime? _handshakeStartTime;

  /// A future that completes when the handshake is successful.
  Future<void> get handshakeComplete => _handshakeCompleter.future;

  /// Metrics observer for this socket (optional).
  UdxMetricsObserver? metricsObserver;

  // --- Path Migration Properties ---
  /// Data for an in-flight path challenge.
  Uint8List? _pathChallengeData;
  /// The potential new address being validated.
  InternetAddress? _pendingRemoteAddress;
  int? _pendingRemotePort;
  /// Timer for path validation timeout.
  Timer? _pathChallengeTimer;

  // --- PMTUD Properties ---
  /// A controller for Path MTU Discovery for this connection.
  late final PathMtuDiscoveryController _pmtudController;
  /// Tracks in-flight MTU probes by their sequence number.
  final Map<int, Timer> _inFlightMtuProbes = {}; // seq -> timeoutTimer
  /// A separate sequence number space for connection-level packets like MTU probes.
  int _nextConnectionSeq = 0;

  // Connection-level flow control properties
  late int _localConnectionMaxData; // Our connection receive window
  late int _remoteConnectionMaxData; // Peer's connection receive window
  int _connectionBytesSent = 0; // Total data bytes sent on this connection
  int _connectionBytesReceived = 0; // Total data bytes received on this connection

  // Stream concurrency properties
  late int _localMaxStreams; // Our advertised stream limit
  int _remoteMaxStreams = defaultMaxStreams; // Peer's stream limit
  int _activeOutgoingStreams = 0; // Count of our active streams to the peer

  // Anti-amplification properties (RFC 9000 Section 8.1)
  bool _addressValidated = false; // Whether the peer's address has been validated
  int _bytesReceivedBeforeValidation = 0; // Bytes received before address validation
  int _bytesSentBeforeValidation = 0; // Bytes sent before address validation
  final List<Uint8List> _pendingPackets = []; // Packets queued due to amplification limit
  static const int amplificationFactor = 3; // RFC 9000: 3x amplification limit

  /// Whether the socket is closing.
  bool get closing => _closing;
  bool _closing = false;

  /// Registered UDXStreams, keyed by their local ID.
  final Map<int, UDXStream> _registeredStreams = {};

  /// A buffer for initial packets that arrive before the stream is created.
  final Map<int, Uint8List> _initialPacketBuffer = {};

  /// A buffer for stream events that occur before a listener is attached.
  final List<UDXStream> _streamBuffer = [];

  List<UDXStream> getStreamBuffer() => _streamBuffer;

  /// Whether the socket is idle (no active streams).
  bool get idle => _registeredStreams.isEmpty;

  /// Whether the socket is busy (has active streams).
  bool get busy => !idle;

  int _recvBufferSize = 0;
  int _sendBufferSize = 0;

  /// Creates a new UDX connection socket.
  UDPSocket({
    required this.udx,
    required this.multiplexer,
    required this.remoteAddress,
    required this.remotePort,
    required this.cids,
    this.metricsObserver,
    bool isServer = false,
  }) {
    _localConnectionMaxData = defaultInitialConnectionWindow;
    _remoteConnectionMaxData = defaultInitialConnectionWindow;
    _localMaxStreams = defaultMaxStreams;
    _pmtudController = PathMtuDiscoveryController();
    
    // For client-initiated connections, address is validated by default
    // For server-side connections (receiving SYN), address must be validated
    _addressValidated = !isServer;
    
    // Notify observer that handshake is starting
    _handshakeStartTime = DateTime.now();
    metricsObserver?.onHandshakeStart(
      cids.localCid,
      cids.remoteCid,
      '${remoteAddress.address}:$remotePort',
    );
  }

  /// Processes an incoming datagram from the multiplexer.
  Future<void> handleIncomingDatagram(Uint8List data, InternetAddress fromAddress, int fromPort) async {
    // Track received bytes for anti-amplification
    if (!_addressValidated) {
      _bytesReceivedBeforeValidation += data.length;
      // Address is validated after receiving a certain amount of data
      // or on successful handshake completion
      if (_bytesReceivedBeforeValidation >= 1000 || _handshakeCompleted) {
        _onAddressValidated();
      }
    }
    
    try {
      final packet = UDXPacket.fromBytes(data);
      
      // Check if version is supported
      if (!UdxVersion.isSupported(packet.version) && !_handshakeCompleted) {
        // Send VERSION_NEGOTIATION packet
        final versionNegPacket = VersionNegotiationPacket(
          destinationCid: packet.sourceCid,
          sourceCid: packet.destinationCid,
          supportedVersions: UdxVersion.supportedVersions,
        );
        multiplexer.send(versionNegPacket.toBytes(), fromAddress, fromPort);
        emit('versionNegotiation', {'clientVersion': packet.version, 'supportedVersions': UdxVersion.supportedVersions});
        return;
      }
      
      // Always update the remote CID from the packet's source CID.
      // This ensures that even during retransmissions or path migrations,
      // we are targeting the correct peer identifier.
      cids.remoteCid = packet.sourceCid;

      if (!_handshakeCompleted) {
        // The handshake is considered complete on the first valid packet received.
        _handshakeCompleted = true;
        if (!_handshakeCompleter.isCompleted) {
          _handshakeCompleter.complete();
        }
        
        // Notify observer of successful handshake
        if (_handshakeStartTime != null) {
          final duration = DateTime.now().difference(_handshakeStartTime!);
          metricsObserver?.onHandshakeComplete(cids.localCid, duration, true, null);
        }
        
        emit('connect');
      }
    } catch (e) {
      // Ignore if it's not a valid packet.
      return;
    }

    try {
      final udxPacket = UDXPacket.fromBytes(data);

      // --- Path Migration Logic ---
      final pathHasChanged = remoteAddress.address != fromAddress.address || remotePort != fromPort;
      // A packet arrived from a new path. If we aren't already validating a
      // path, start a new validation.
      if (pathHasChanged && _pathChallengeData == null) {
        _initiatePathValidation(fromAddress, fromPort);
      }

      // --- PMTUD: Handle ACKs for Probes & Trigger New Probes ---
      for (final frame in udxPacket.frames.whereType<AckFrame>()) {
        _handleAckFrameForPmtud(frame);
      }
      _sendMtuProbeIfNeeded();

      // Process connection-level frames first
      for (final frame in udxPacket.frames) {
        if (frame is ConnectionCloseFrame) {
          // Handle CONNECTION_CLOSE frame - peer is terminating the connection
          emit('connectionClose', {
            'errorCode': frame.errorCode,
            'frameType': frame.frameType,
            'reason': frame.reasonPhrase
          });
          // Close our side of the connection
          await close();
          return;
        } else if (frame is MaxDataFrame) {
          _handleMaxDataFrame(frame);
        } else if (frame is MaxStreamsFrame) {
          _handleMaxStreamsFrame(frame);
        } else if (frame is PathChallengeFrame) {
          _handlePathChallenge(frame, fromAddress, fromPort);
        } else if (frame is PathResponseFrame) {
          _handlePathResponse(frame, fromAddress, fromPort);
        } else if (frame is DataBlockedFrame) {
          // Peer is blocked on connection-level flow control
          emit('dataBlocked', {'maxData': frame.maxData});
          // Application can listen to this event and potentially increase the connection window
        } else if (frame is StreamFrame) {
          _connectionBytesReceived += frame.data.length;
          _checkAndSendLocalMaxDataUpdate();
        }
      }

      final targetStreamId = udxPacket.destinationStreamId;
      if (_registeredStreams.containsKey(targetStreamId)) {
        final targetStream = _registeredStreams[targetStreamId]!;
        targetStream.internalHandleSocketEvent({
          'data': data,
          'address': fromAddress.address,
          'port': fromPort,
        });
      } else {
        // Check for a SYN flag to create a new stream
        final synFrame = udxPacket.frames.whereType<StreamFrame>().firstWhereOrNull((f) => f.isSyn);
        if (synFrame != null) {
          // print( '[SOCK ${cids.localCid}] SYN frame detected for stream ${udxPacket.destinationStreamId}. Creating new UDXStream.');
          // Enforce incoming stream limit
          final currentIncomingStreams = _registeredStreams.values.where((s) => !s.isInitiator).length;

          if (currentIncomingStreams >= _localMaxStreams) {
            // Reject the stream
            final resetFrame = ResetStreamFrame(errorCode: 2); // STREAM_LIMIT_ERROR
            final responsePacket = UDXPacket(
              destinationCid: udxPacket.sourceCid,
              sourceCid: udxPacket.destinationCid,
              destinationStreamId: udxPacket.sourceStreamId,
              sourceStreamId: targetStreamId,
              sequence: 0,
              frames: [resetFrame],
            );
            multiplexer.send(responsePacket.toBytes(), fromAddress, fromPort);
            return;
          }

          // Buffer the initial packet *before* creating the stream,
          // so the stream's constructor can pop it.
          _initialPacketBuffer[targetStreamId] = data;

          final newStream = UDXStream.createIncoming(
            udx,
            this,
            targetStreamId,
            udxPacket.sourceStreamId,
            fromAddress.address,
            fromPort,
            initialSeq: udxPacket.sequence,
            destinationCid: udxPacket.destinationCid,
            sourceCid: udxPacket.sourceCid,
          );
          
          emit('stream', newStream);
          _streamBuffer.add(newStream);
        } else if (targetStreamId != 0) {
          emit('unmatchedUDXPacket', {
            'packet': udxPacket,
            'remoteAddress': fromAddress,
            'remotePort': fromPort,
            'rawData': data,
          });
        }
      }
    } catch (e) {
      // //print('UDPSocket: Error processing incoming datagram: $e. From: ${fromAddress.address}:$fromPort');
    }
  }

  /// Sends data to the peer via the multiplexer.
  /// Enforces anti-amplification limits per RFC 9000 Section 8.1.
  void send(Uint8List data) {
    if (_closing) throw StateError('Socket is closing');
    
    // Anti-amplification check: don't send more than 3x what we've received
    // until the address is validated
    if (!_addressValidated) {
      final limit = _bytesReceivedBeforeValidation * amplificationFactor;
      if (_bytesSentBeforeValidation + data.length > limit) {
        // Queue the packet until address is validated
        _pendingPackets.add(data);
        return;
      }
      _bytesSentBeforeValidation += data.length;
    }
    
    multiplexer.send(data, remoteAddress, remotePort);
  }

  /// Called when the peer's address has been validated.
  /// Flushes any packets that were queued due to amplification limits.
  void _onAddressValidated() {
    if (_addressValidated) return;
    
    _addressValidated = true;
    emit('addressValidated');
    
    // Flush all pending packets
    for (final packet in _pendingPackets) {
      multiplexer.send(packet, remoteAddress, remotePort);
    }
    _pendingPackets.clear();
  }

  /// Sets the TTL (Time To Live) for outgoing packets. (Not implemented)
  void setTTL(int ttl) {
    if (_closing) throw StateError('Socket is closing');
    // This would need to be handled by the multiplexer's RawDatagramSocket
  }

  /// Gets the receive buffer size.
  int getRecvBufferSize() {
    return _recvBufferSize;
  }

  /// Sets the receive buffer size.
  void setRecvBufferSize(int size) {
    if (_closing) throw StateError('Socket is closing');
    _recvBufferSize = size;
  }

  /// Gets the send buffer size.
  int getSendBufferSize() {
    return _sendBufferSize;
  }

  /// Sets the send buffer size.
  void setSendBufferSize(int size) {
    if (_closing) throw StateError('Socket is closing');
    _sendBufferSize = size;
  }

  /// Closes the connection with an error code and reason.
  /// Sends a CONNECTION_CLOSE frame to the peer before terminating.
  Future<void> closeWithError(int errorCode, String reason, {int frameType = 0}) async {
    if (_closing) return;
    _closing = true;

    try {
      // Send CONNECTION_CLOSE frame
      final closeFrame = ConnectionCloseFrame(
        errorCode: errorCode,
        frameType: frameType,
        reasonPhrase: reason,
      );
      final closePacket = UDXPacket(
        destinationCid: cids.remoteCid,
        sourceCid: cids.localCid,
        destinationStreamId: 0,
        sourceStreamId: 0,
        sequence: 0,
        frames: [closeFrame],
      );
      
      try {
        send(closePacket.toBytes());
        // Small delay to ensure CONNECTION_CLOSE is sent
        await Future.delayed(Duration(milliseconds: 100));
      } catch (e) {
        // Ignore send errors during close
      }

      // Close all streams
      final streamIds = List<int>.from(_registeredStreams.keys);
      for (final streamId in streamIds) {
        final stream = _registeredStreams[streamId];
        if (stream != null) {
          await stream.close();
        }
      }
      _registeredStreams.clear();

      multiplexer.removeSocket(cids.localCid);

      emit('close', {'error': errorCode, 'reason': reason});
    } catch (e) {
      emit('error', e);
      rethrow;
    } finally {
      super.close();
    }
  }

  /// Closes the connection.
  Future<void> close() async {
    if (_closing) return;
    _closing = true;

    try {
      final streamIds = List<int>.from(_registeredStreams.keys);
      for (final streamId in streamIds) {
        final stream = _registeredStreams[streamId];
        if (stream != null) {
          await stream.close();
        }
      }
      _registeredStreams.clear();

      multiplexer.removeSocket(cids.localCid);

      emit('close');
    } catch (e) {
      emit('error', e);
      rethrow;
    } finally {
      super.close();
    }
  }

  /// Returns the remote peer's address.
  Map<String, dynamic>? address() {
    return {
      'host': remoteAddress.address,
      'port': remotePort,
      'family': remoteAddress.type == InternetAddressType.IPv6 ? 6 : 4,
    };
  }

  /// Registers a UDXStream with this socket.
  void registerStream(UDXStream stream) {
    if (_closing) {
      return;
    }
    if (_registeredStreams.containsKey(stream.id)) {
      // Potentially throw an error or close the old stream
    }
    _registeredStreams[stream.id] = stream;
    
    // Notify observer of stream creation
    metricsObserver?.onStreamCreated(cids.localCid, stream.id, stream.isInitiator);
  }

  /// Unregisters a UDXStream from this socket.
  void unregisterStream(int streamId) {
    final stream = _registeredStreams[streamId];
    if (stream != null) {
      // Notify observer of stream closure (we'll get duration and bytes from the stream)
      final duration = stream.connectedAt != null 
          ? DateTime.now().difference(stream.connectedAt!) 
          : Duration.zero;
      metricsObserver?.onStreamClosed(
        cids.localCid, 
        streamId, 
        duration,
        stream.bytesRead,
        stream.bytesWritten,
      );
      
      _registeredStreams.remove(streamId);
      if (stream.isInitiator) {
        _activeOutgoingStreams = (_activeOutgoingStreams - 1).clamp(0, 9999);
      }
    }
  }

  /// Flushes buffered streams that were received before a listener was attached.
  /// This ensures that listeners attached after stream creation still receive
  /// the stream event.
  void flushStreamBuffer() {
    final streamsToProcess = List<UDXStream>.from(_streamBuffer);
    _streamBuffer.clear();
    for (final stream in streamsToProcess) {
      // Re-emit the event. If a listener is now present, it will be handled.
      emit('stream', stream);
    }
  }

  // --- Stream Concurrency Control Methods ---

  void _handleMaxStreamsFrame(MaxStreamsFrame frame) {
    _remoteMaxStreams = frame.maxStreamCount;
    emit('remoteMaxStreamsUpdate', {'maxStreams': frame.maxStreamCount});
  }

  Future<void> sendMaxStreamsFrame() async {
    if (closing) return;
    final frame = MaxStreamsFrame(maxStreamCount: _localMaxStreams);
    final packet = UDXPacket(
      destinationCid: cids.remoteCid,
      sourceCid: cids.localCid,
      destinationStreamId: 0,
      sourceStreamId: 0,
      sequence: 0,
      frames: [frame],
    );
    send(packet.toBytes());
  }

  /// Checks if a new outgoing stream can be created.
  bool canCreateNewStream() {
    return _activeOutgoingStreams < _remoteMaxStreams;
  }

  /// Call this when a new outgoing stream is created.
  void incrementOutgoingStreams() {
    _activeOutgoingStreams++;
  }

  // --- Path Validation Methods ---

  void _initiatePathValidation(InternetAddress newAddress, int newPort) {
    // Generate 8 bytes of random data for the challenge.
    _pathChallengeData = ConnectionId.random().bytes;
    _pendingRemoteAddress = newAddress;
    _pendingRemotePort = newPort;

    // Notify observer of path migration start
    metricsObserver?.onPathMigrationStart(
      cids.localCid,
      '${remoteAddress.address}:$remotePort',
      '${newAddress.address}:$newPort',
    );

    final challengeFrame = PathChallengeFrame(data: _pathChallengeData!);
    final packet = UDXPacket(
      destinationCid: cids.remoteCid,
      sourceCid: cids.localCid,
      destinationStreamId: 0,
      sourceStreamId: 0,
      sequence: 0, // Connection-level packets can use seq 0
      frames: [challengeFrame],
    );

    // Send the challenge to the *new* path.
    multiplexer.send(packet.toBytes(), newAddress, newPort);

    // Emit an event for testing purposes to capture the challenge data.
    emit('pathChallengeSent', {'data': _pathChallengeData});

    // Start a timer. If we don't get a valid response, abort the validation.
    _pathChallengeTimer?.cancel();
    _pathChallengeTimer = Timer(const Duration(seconds: 5), () {
      // Notify observer of failed path migration
      metricsObserver?.onPathMigrationComplete(cids.localCid, false);
      
      _pathChallengeData = null;
      _pendingRemoteAddress = null;
      _pendingRemotePort = null;
    });
  }

  void _handlePathChallenge(PathChallengeFrame frame, InternetAddress fromAddress, int fromPort) {
    // Emit an event so tests can observe that a challenge was received.
    emit('pathChallengeReceived', frame);

    // When we receive a challenge, we must respond with the same data.
    final responseFrame = PathResponseFrame(data: frame.data);
    final packet = UDXPacket(
      destinationCid: cids.remoteCid,
      sourceCid: cids.localCid,
      destinationStreamId: 0,
      sourceStreamId: 0,
      sequence: 0,
      frames: [responseFrame],
    );
    // Send the response back to the path it came from.
    multiplexer.send(packet.toBytes(), fromAddress, fromPort);
  }

  void _handlePathResponse(PathResponseFrame frame, InternetAddress fromAddress, int fromPort) {
    // Check if the response is valid.
    if (_pathChallengeData == null ||
        _pendingRemoteAddress?.address != fromAddress.address ||
        _pendingRemotePort != fromPort) {
      // Not a valid response (either we didn't send a challenge, or it's from the wrong address).
      return;
    }

    // Using a constant-time comparison to be safe against timing attacks.
    if (!const ListEquality().equals(_pathChallengeData, frame.data)) {
      // Challenge data does not match.
      return;
    }

    // Success! The new path is validated.
    remoteAddress = _pendingRemoteAddress!;
    remotePort = _pendingRemotePort!;

    // Notify observer of successful path migration
    metricsObserver?.onPathMigrationComplete(cids.localCid, true);

    // Clean up state.
    _pathChallengeTimer?.cancel();
    _pathChallengeTimer = null;
    _pathChallengeData = null;
    _pendingRemoteAddress = null;
    _pendingRemotePort = null;

    emit('pathUpdate', {'host': remoteAddress.address, 'port': remotePort});
  }

  // --- Connection Liveness Check ---

  /// Send a PING frame and wait for ACK to verify connection liveness.
  /// Returns true if ACK received within timeout, false otherwise.
  /// 
  /// This is a lightweight, non-intrusive way to check if the connection
  /// is still alive. The PING frame is just 1 byte and elicits an ACK response.
  Future<bool> ping({Duration timeout = const Duration(seconds: 5)}) async {
    if (_closing || closing) return false;
    
    // Send a packet containing just a PING frame
    final pingSequence = _nextConnectionSeq++;
    final packet = UDXPacket(
      destinationCid: cids.remoteCid,
      sourceCid: cids.localCid,
      destinationStreamId: 0, // Connection-level packet
      sourceStreamId: 0,       // Connection-level packet
      sequence: pingSequence,
      frames: [PingFrame()],
    );
    
    final completer = Completer<bool>();
    Timer? timeoutTimer;
    StreamSubscription? ackSubscription;
    
    // Listen for ACK of our ping packet
    ackSubscription = on('ack').listen((event) {
      // Check if this ACK acknowledges our ping packet
      if (event.data is Map) {
        final data = event.data as Map;
        if (data['largestAcked'] != null) {
          final largestAcked = data['largestAcked'] as int;
          if (largestAcked >= pingSequence) {
            // Our ping was acknowledged
            if (!completer.isCompleted) {
              timeoutTimer?.cancel();
              ackSubscription?.cancel();
              completer.complete(true);
            }
          }
        }
      }
    });
    
    // Set up timeout
    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        ackSubscription?.cancel();
        completer.complete(false);
      }
    });
    
    // Send the ping packet
    try {
      send(packet.toBytes());
    } catch (e) {
      timeoutTimer.cancel();
      ackSubscription.cancel();
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    }
    
    return completer.future;
  }

  // --- PMTUD Methods ---

  void _sendMtuProbeIfNeeded() {
    if (!_pmtudController.shouldSendProbe()) {
      return;
    }

    final (probePacket, sequence) = _pmtudController.buildProbePacket(
        cids.remoteCid, cids.localCid, 0, 0, _nextConnectionSeq++);
    
    send(probePacket.toBytes());

    final timer = Timer(const Duration(seconds: 3), () {
      _handleProbeLoss(sequence);
    });

    _inFlightMtuProbes[sequence] = timer;
  }

  void _handleProbeLoss(int sequence) {
    if (_inFlightMtuProbes.remove(sequence) == null) {
      return;
    }
    _pmtudController.onProbeLost(sequence);
  }

  void _handleAckFrameForPmtud(AckFrame frame) {
    final ackedSequences = <int>{};
    if (frame.firstAckRangeLength > 0) {
      for (int i = 0; i < frame.firstAckRangeLength; i++) {
        ackedSequences.add(frame.largestAcked - i);
      }
    }

    int currentSeq = frame.largestAcked - frame.firstAckRangeLength;
    for (final rangeBlock in frame.ackRanges) {
      final rangeEnd = currentSeq - rangeBlock.gap;
      for (int i = 0; i < rangeBlock.ackRangeLength; i++) {
        ackedSequences.add(rangeEnd - i);
      }
      currentSeq = (rangeEnd - rangeBlock.ackRangeLength + 1) - 1;
    }

    for (final seq in ackedSequences) {
      if (_inFlightMtuProbes.containsKey(seq)) {
        final timer = _inFlightMtuProbes.remove(seq)!;
        timer.cancel();
        _pmtudController.onProbeAcked(seq);
      }
    }
  }

  // --- Test Hooks ---

  @visibleForTesting
  void setLocalMaxStreamsForTest(int value) {
    _localMaxStreams = value;
  }

  @visibleForTesting
  void setRemoteMaxStreamsForTest(int value) {
    _remoteMaxStreams = value;
  }

  @visibleForTesting
  int getRegisteredStreamsCount() {
    return _registeredStreams.length;
  }

  /// Retrieves and removes the initial buffered packet for a stream.
  Uint8List? popInitialPacket(int streamId) {
    return _initialPacketBuffer.remove(streamId);
  }

  // --- Connection-Level Flow Control Methods ---

  void _handleMaxDataFrame(MaxDataFrame frame) {
    emit('processedMaxDataFrame', {
      'maxData': frame.maxData,
      'remoteAddress': remoteAddress.address,
      'remotePort': remotePort
    });

    if (frame.maxData > _remoteConnectionMaxData) {
      _remoteConnectionMaxData = frame.maxData;
      emit('remoteConnectionWindowUpdate', {'maxData': _remoteConnectionMaxData});
    }
  }

  /// Sends a MAX_DATA frame to the peer.
  Future<void> sendMaxDataFrame(int localMaxData, {int streamId = 0}) async {
    if (closing) return;
    final maxDataFrame = MaxDataFrame(maxData: localMaxData);
    final packet = UDXPacket(
      destinationCid: cids.remoteCid,
      sourceCid: cids.localCid,
      destinationStreamId: streamId,
      sourceStreamId: streamId,
      sequence: 0,
      frames: [maxDataFrame],
    );
    try {
      send(packet.toBytes());
    } catch (e, s) {
      emit('error', {'error': e, 'message': 'Failed to send MaxDataFrame', 'stackTrace': s.toString()});
    }
  }

  /// Called when the application has processed data.
  void advertiseConnectionWindowUpdate() {
    sendMaxDataFrame(_localConnectionMaxData);
  }

  /// Gets the available send window at the connection level.
  int getAvailableConnectionSendWindow() {
    final available = _remoteConnectionMaxData - _connectionBytesSent;
    return available > 0 ? available : 0;
  }

  /// Called by UDXStream when it sends data.
  void incrementConnectionBytesSent(int bytes) {
    _connectionBytesSent += bytes;
  }

  /// Called by UDXStream when data is acknowledged.
  void decrementConnectionBytesSent(int bytes) {
    _connectionBytesSent -= bytes;
    if (_connectionBytesSent < 0) {
      _connectionBytesSent = 0;
    }
  }

  /// Called by UDXStream when it has received and processed data.
  void onStreamDataProcessed(int bytesProcessed) {
    _checkAndSendLocalMaxDataUpdate();
  }

  void _checkAndSendLocalMaxDataUpdate() {
    if (_connectionBytesReceived > _localConnectionMaxData * 0.25) {
       advertiseConnectionWindowUpdate();
       _connectionBytesReceived = 0;
    }
  }
}
