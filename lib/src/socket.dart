import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'cid.dart';
import 'clock.dart';
import 'udx.dart';
import 'events.dart';
import 'stream.dart';
import 'packet.dart';
import 'congestion.dart';
import 'lost_queue.dart';
import 'multiplexer.dart';
import 'pmtud.dart';
import 'recv_tracker.dart';
import 'metrics_observer.dart';
import 'logging.dart';
import 'version.dart';
import 'constants.dart' show maxIdleTimeout, errorConnectionTimeout;

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
  Duration? _handshakeStartTime;

  /// The clock all of this connection's timing runs on; see [Clock].
  final Clock clock;

  /// A future that completes when the handshake is successful.
  Future<void> get handshakeComplete => _handshakeCompleter.future;

  /// Whether anything has been received from the peer yet.
  bool get isHandshakeCompleted => _handshakeCompleted;

  /// Whether this socket was created for an inbound connection.
  final bool isServer;

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
  /// Connection-level packet manager (per-connection sequencing, per QUIC RFC 9000).
  late final PacketManager _packetManager;

  /// Connection-level congestion controller.
  late final CongestionController _congestionController;

  /// Packets declared lost, re-sent as the window allows.
  late final LostQueue _lostQueue;

  /// Which ack-eliciting packets have arrived, for the ACK's ranges.
  final RecvTracker _recvd = RecvTracker();

  /// Ack-eliciting packets received since the last ACK went out, the ACK
  /// timer that flushes them, and when the largest sequence arrived (what
  /// the frame's ackDelay reports, so the sender's RTT sample is honest).
  int _ackPending = 0;
  Timer? _ackTimer;
  Duration? _largestArrival;

  /// Acknowledgement policy (RFC 9000 section 13.2), as go-udx's: at once
  /// when a packet is out of order or opens or closes a stream or carries a
  /// PING or MTU probe, otherwise after every [ackElicitingThreshold]
  /// ack-eliciting packets or when the ACK timer fires, whichever is first.
  /// The timer is a quarter of the smoothed RTT within [minAckDelay,
  /// maxAckDelay]; the sender subtracts at most maxAckDelay from its sample.
  static const int ackElicitingThreshold = 2;
  static const Duration minAckDelay = Duration(milliseconds: 1);
  static const Duration maxAckDelay = Duration(milliseconds: 25);

  /// Completes when a writer may have gained send credit: bytes acknowledged
  /// (the congestion window and the connection's send window both open),
  /// MAX_DATA or a stream's WINDOW_UPDATE from the peer, or this socket
  /// closing. Writers wait on it instead of polling, and re-check their limits
  /// when it completes; nothing is sent past a limit after a wait.
  Completer<void> _sendCredit = Completer<void>();

  /// A future that completes the next time send credit may have changed.
  Future<void> get sendCreditChanged => _sendCredit.future;

  /// Wakes writers waiting on [sendCreditChanged].
  void notifySendCredit() {
    final waiting = _sendCredit;
    if (waiting.isCompleted) return;
    _sendCredit = Completer<void>();
    waiting.complete();
  }

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

  /// Idle timeout (RFC 9000 section 10.1). [_lastActivity] is stamped on every
  /// received datagram; a self-rearming watchdog closes the connection once it
  /// has been silent longer than [_idleTimeout]. This is the backstop that ends
  /// a dead path now that retransmission never gives up on its own.
  late Duration _lastActivity;
  Timer? _idleTimer;

  /// How often the watchdog wakes to test for silence — a poll granularity, not
  /// the timeout itself.
  static const Duration _idleCheckInterval = Duration(seconds: 1);

  /// Creates a new UDX connection socket.
  UDPSocket({
    required this.udx,
    required this.multiplexer,
    required this.remoteAddress,
    required this.remotePort,
    required this.cids,
    this.metricsObserver,
    this.isServer = false,
    Clock? clock,
  }) : clock = clock ?? const SystemClock() {
    _localConnectionMaxData = defaultInitialConnectionWindow;
    _remoteConnectionMaxData = defaultInitialConnectionWindow;
    _localMaxStreams = defaultMaxStreams;
    _pmtudController = PathMtuDiscoveryController();

    // Initialize connection-level packet management
    _packetManager = PacketManager(clock: this.clock);
    _congestionController = CongestionController(packetManager: _packetManager, clock: this.clock);
    _packetManager.congestionController = _congestionController;
    _lostQueue = LostQueue(
      packetManager: _packetManager,
      congestionController: _congestionController,
      clock: this.clock,
      send: _sendQuietly,
    );

    // A PTO probe re-sends the oldest outstanding packets under fresh
    // sequences, through this; their bytes are still in flight.
    _packetManager.onRetransmit = (packet) => _sendQuietly(packet.toBytes());
    _congestionController.onProbe = _packetManager.sendProbe;
    _packetManager.onPacketsLost = _onPacketsLost;

    // For client-initiated connections, address is validated by default
    // For server-side connections (receiving SYN), address must be validated
    _addressValidated = !isServer;
    
    // Notify observer that handshake is starting
    _handshakeStartTime = this.clock.now();
    metricsObserver?.onHandshakeStart(
      cids.localCid,
      cids.remoteCid,
      '${remoteAddress.address}:$remotePort',
    );

    _lastActivity = this.clock.now();
    _armIdleCheck();
  }

  /// The silence a connection tolerates before it is closed. RFC 9000 section
  /// 10.1 requires at least three PTOs, so loss recovery always gets a chance
  /// before the path is declared dead; the PTO is capped, so the 30s floor wins
  /// in practice, and the max() keeps it correct if that cap ever rises.
  Duration get _idleTimeout {
    final threePto = _congestionController.pto * 3;
    return threePto > maxIdleTimeout ? threePto : maxIdleTimeout;
  }

  /// Sends encoded bytes, ignoring a socket that is closing under us.
  void _sendQuietly(Uint8List bytes) {
    if (_closing) return;
    try {
      send(bytes);
    } catch (_) {
      // The socket closed; nothing to send to.
    }
  }

  /// Told by loss detection what is lost, oldest first. The bytes leave
  /// flight and the window contracts once per recovery epoch; a loss span of
  /// three PTOs with no ACK since the oldest went out is persistent
  /// congestion and collapses the window to the minimum (RFC 9002 section
  /// 7.6). The packets then queue for re-sending as the window allows.
  void _onPacketsLost(List<UDXPacket> lost) {
    if (lost.isEmpty) return;
    var bytes = 0;
    for (final packet in lost) {
      bytes += packet.dataBytes;
      metricsObserver?.onPacketLoss(cids.localCid, packet.sequence, 'ack');
    }
    _congestionController.onPacketLost(bytes, lost);
    if (_packetManager.persistentCongestion(lost)) {
      _congestionController.onPersistentCongestion();
    }
    _lostQueue.add(lost);
  }

  /// How many lost packets wait for window to be re-sent.
  int get lostQueueLength => _lostQueue.length;

  void _armIdleCheck() {
    if (_closing) return;
    _idleTimer = clock.timer(_idleCheckInterval, _onIdleCheck);
  }

  void _onIdleCheck() {
    if (_closing) return;
    if (clock.now() - _lastActivity >= _idleTimeout) {
      // Silent close (RFC 9000 section 10.1): no CONNECTION_CLOSE — there may be
      // nothing left on the path to hear it. Blocked readers and writers are
      // still woken through the stream resets.
      _closeIdle();
      return;
    }
    _armIdleCheck();
  }

  Future<void> _closeIdle() async {
    if (_closing) return;
    _closing = true;
    _idleTimer?.cancel();
    _ackTimer?.cancel();
    notifySendCredit();
    UdxLogging.warn(
        'socket idle-timeout close: cid=${cids.localCid} peer=${remoteAddress.address}:$remotePort '
        'idleTimeout=${_idleTimeout.inSeconds}s lastActivity=$_lastActivity streams=${_registeredStreams.length}');

    try {
      final streamIds = List<int>.from(_registeredStreams.keys);
      for (final streamId in streamIds) {
        _registeredStreams[streamId]?.deliverReset(errorConnectionTimeout);
      }
      _registeredStreams.clear();

      multiplexer.removeSocket(cids.localCid);
      _lostQueue.dispose();
      _packetManager.destroy();
      _congestionController.destroy();

      emit('close', {'error': errorConnectionTimeout, 'reason': 'idle timeout'});
    } catch (e) {
      emit('error', e);
    } finally {
      super.close();
    }
  }

  /// Processes an incoming datagram from the multiplexer.
  Future<void> handleIncomingDatagram(Uint8List data, InternetAddress fromAddress, int fromPort) async {
    // Any datagram is proof the path is alive; restart the idle clock (RFC 9000
    // section 10.1: the timer resets on receiving and processing a packet).
    _lastActivity = clock.now();

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
          final duration = clock.now() - _handshakeStartTime!;
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

      // v3 moved the STREAM frame's data length behind an eight-byte offset, so
      // an older peer's frame parses without error into nonsense. Drop anything
      // that is not the current version: a mismatch has to look like an
      // unreachable peer, which is diagnosable, rather than corrupt data.
      if (udxPacket.version != UdxVersion.current) return;

      if (UdxLogging.info) {
        UdxLogging.infoLog('[DIAG-UDX-RECV] seq=${udxPacket.sequence} frames=${udxPacket.frames.length} from=${fromAddress.address}:$fromPort');
      }

      // --- Path Migration Logic ---
      final pathHasChanged = remoteAddress.address != fromAddress.address || remotePort != fromPort;
      if (pathHasChanged && _pathChallengeData == null) {
        _initiatePathValidation(fromAddress, fromPort);
      }

      // --- PMTUD: Handle ACKs for Probes & Trigger New Probes ---
      for (final frame in udxPacket.frames.whereType<AckFrame>()) {
        _handleAckFrameForPmtud(frame);
      }
      _sendMtuProbeIfNeeded();

      // --- Process connection-level frames (not sequence-dependent) ---
      for (final frame in udxPacket.frames) {
        if (frame is ConnectionCloseFrame) {
          emit('connectionClose', {
            'errorCode': frame.errorCode,
            'frameType': frame.frameType,
            'reason': frame.reasonPhrase
          });
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
          // The peer is out of connection-level credit, possibly because our
          // MAX_DATA was lost (it is never retransmitted): re-advertise.
          emit('dataBlocked', {'maxData': frame.maxData});
          advertiseConnectionWindowUpdate();
        }
      }

      // --- Process ACK frames at connection level ---
      for (final frame in udxPacket.frames.whereType<AckFrame>()) {
        _handleConnectionAckFrame(frame);
      }

      // --- Process RESET, STOP_SENDING, WINDOW_UPDATE, STREAM_DATA_BLOCKED immediately (not sequence-dependent) ---
      for (final frame in udxPacket.frames) {
        if (frame is ResetStreamFrame) {
          _findStream(udxPacket.destinationStreamId, udxPacket.sourceStreamId)
              ?.deliverReset(frame.errorCode);
        } else if (frame is StopSendingFrame) {
          _findStream(udxPacket.destinationStreamId, udxPacket.sourceStreamId)
              ?.deliverStopSending(frame.errorCode);
        } else if (frame is WindowUpdateFrame) {
          _findStream(udxPacket.destinationStreamId, udxPacket.sourceStreamId)
              ?.deliverWindowUpdate(frame.windowSize);
        } else if (frame is StreamDataBlockedFrame) {
          _findStream(udxPacket.destinationStreamId, udxPacket.sourceStreamId)
              ?.deliverStreamDataBlocked();
        }
      }

      // Every frame is handled on arrival. Nothing waits for an earlier packet:
      // STREAM frames carry their own byte offset, so each stream places its
      // own bytes and is held up only by its own gaps.
      //
      // This used to reorder whole packets here, on the connection's sequence
      // number, before any stream saw them. That made a gap anywhere stall
      // every stream on the connection — one lossy stream held up all its
      // siblings — and it was the only thing keeping the byte stream contiguous,
      // so it could not simply be removed. Offsets replace it.
      final ackEliciting =
          udxPacket.frames.any((f) => f is StreamFrame || f is PingFrame || f is MtuProbeFrame);

      _processPacketFrames(udxPacket, fromAddress, fromPort);

      if (ackEliciting) {
        // ACKs reflect receipt, not delivery. A packet whose bytes are waiting
        // on an earlier gap has still arrived, and saying so lets the peer
        // retransmit only what is genuinely missing.
        _noteReceived(udxPacket);
      }
    } catch (e) {
      // Ignore invalid packets
    }
  }

  /// Processes the frames of a packet that is in sequence order.
  void _processPacketFrames(UDXPacket packet, InternetAddress fromAddress, int fromPort) {
    final targetStreamId = packet.destinationStreamId;
    final remoteStreamId = packet.sourceStreamId;

    for (final frame in packet.frames) {
      if (frame is StreamFrame) {
        _connectionBytesReceived += frame.data.length;
        _checkAndSendLocalMaxDataUpdate();

        // Route to an existing stream, or open one on first reference. A peer
        // that has not learned our local id (go-udx and js-udx never do)
        // addresses its packets to 0, so match on the sender's own id too.
        UDXStream? stream = _findStream(targetStreamId, remoteStreamId);

        if (stream == null &&
            remoteStreamId != 0 &&
            (frame.isSyn || frame.data.isNotEmpty)) {
          // Data opens the stream too, not just SYN.
          //
          // Requiring SYN was safe only while the socket reordered packets
          // before delivery, which guaranteed the SYN — the lowest sequence
          // number — arrived first. Now that frames are handled on arrival a
          // reordered data packet can beat it, and there would be nothing to
          // attach the bytes to: they would be dropped despite having been
          // acknowledged, so the peer would never re-send them and the stream
          // would stall at that offset forever.
          //
          // A bare FIN or RESET is deliberately not enough. It carries nothing
          // to deliver, so conjuring a stream for one only invents a stream the
          // application never had — which is exactly what a FIN arriving for an
          // already-closed stream would do.
          final currentIncomingStreams = _registeredStreams.values.where((s) => !s.isInitiator).length;
          if (currentIncomingStreams >= _localMaxStreams) {
            // Reject
            sendStreamPacket(remoteStreamId, targetStreamId, [ResetStreamFrame(errorCode: 2)], trackForRetransmit: false);
            return;
          }

          final newStream = UDXStream.createIncoming(
            udx,
            this,
            targetStreamId,
            remoteStreamId,
            fromAddress.address,
            fromPort,
            initialSeq: packet.sequence,
            destinationCid: packet.destinationCid,
            sourceCid: packet.sourceCid,
          );

          stream = newStream;
          emit('stream', newStream);
          _streamBuffer.add(newStream);
        }

        if (stream == null) continue;

        // Deliver data at its offset; the stream orders its own bytes.
        if (frame.data.isNotEmpty) {
          stream.deliverData(frame.offset, frame.data);
        }
        if (frame.isFin) {
          // The stream ends one past this frame's last byte, which is the
          // frame's own offset when the FIN carries no data of its own.
          stream.deliverFin(frame.offset + frame.data.length);
        }
        if (frame.isSyn && stream.remoteId == null) {
          // Set the remote ID from the SYN packet
          stream.remoteId = remoteStreamId;
        }
      }
    }
  }

  /// Handles an ACK frame at the connection level (RFC 9002 sections 5.1 and
  /// 7.3.1), the way go-udx's handleAckFrame does.
  ///
  /// Every packet the frame newly acknowledges, under whatever sequence it was
  /// last sent with, leaves flight and gives its bytes back to the connection's
  /// send window. The controller hears about the frame once, with all of those
  /// bytes together, and takes its RTT sample from the largest acknowledged
  /// packet when that one is among them.
  ///
  /// This used to keep a TCP-style cumulative-ack point and count "duplicate"
  /// ACKs against it. A retransmission is re-keyed under a fresh sequence, so
  /// the original sequence is never acknowledged and the point stuck there for
  /// the rest of the connection: every later ACK counted as a duplicate, the
  /// RTT was never sampled again, the window never grew again, recovery never
  /// ended, and fast retransmit was aimed at a retired sequence.
  void _handleConnectionAckFrame(AckFrame frame) {
    final acked = _packetManager.handleAckFrame(frame);
    if (acked.isEmpty) return;

    var bytes = 0;
    UDXPacket? largest;
    for (final packet in acked) {
      final size = packet.dataBytes;
      bytes += size;
      if (packet.sequence == frame.largestAcked) largest = packet;
      decrementConnectionBytesSent(size);
      emit('ack', {'largestAcked': packet.sequence});
    }

    _congestionController.onPacketAcked(
      bytes,
      largest?.lastSentTime,
      Duration(milliseconds: frame.ackDelay),
      largest != null,
      frame.largestAcked,
    );
    // Then loss detection over every outstanding packet below the largest
    // acknowledged (RFC 9002 section 6.1); what it declares lost goes to
    // _onPacketsLost. Lost data first, then new data: the window the ACK
    // opened goes to the resend queue before writers are woken.
    _packetManager.detectLostPackets();
    _lostQueue.flush();
    notifySendCredit();
  }

  /// The connection-level congestion controller, exposed for stream flow control checks.
  CongestionController get congestionController => _congestionController;

  /// The connection-level packet manager, exposed for sequence number access.
  PacketManager get packetManager => _packetManager;

  /// Sends a packet with the given frames on behalf of a stream.
  /// Uses connection-level sequence numbers (per QUIC RFC 9000).
  /// If [trackForRetransmit] is true, the packet is registered with the PacketManager
  /// for retransmission and congestion control.
  void sendStreamPacket(int dstStreamId, int srcStreamId, List<Frame> frames, {bool trackForRetransmit = true}) {
    if (_closing) return;

    // Determine if this packet carries stream data (data, SYN, or FIN).
    // Control-only packets (WindowUpdate, ACK, etc.) use seq=0 to avoid
    // consuming sequence numbers that create gaps in the receiver's ordered
    // delivery. This matches the Go UDX sendPacket() logic.
    bool hasData = false;
    int dataSize = 0;
    for (final frame in frames) {
      if (frame is StreamFrame) {
        dataSize += frame.data.length;
        if (frame.data.isNotEmpty || frame.isSyn || frame.isFin) {
          hasData = true;
        }
      }
    }

    final seq = hasData ? _packetManager.nextSequence : 0;
    final packet = UDXPacket(
      destinationCid: cids.remoteCid,
      sourceCid: cids.localCid,
      destinationStreamId: dstStreamId,
      sourceStreamId: srcStreamId,
      sequence: seq,
      frames: frames,
    );

    if (hasData && trackForRetransmit) {
      _packetManager.sendPacket(packet);
      _congestionController.onPacketSent(dataSize);
    }

    send(packet.toBytes());

    if (dataSize > 0) {
      incrementConnectionBytesSent(dataSize);
      _congestionController.pacingController.onPacketSent(packet.toBytes().length);
    }
  }

  /// Records an ack-eliciting packet and decides whether to acknowledge now
  /// or later (RFC 9000 section 13.2; go-udx's noteReceived).
  ///
  /// Now: the packet is out of order (the sender should learn of the gap
  /// without waiting), or it opens or closes a stream (a SYN is what a dial
  /// is waiting on; a FIN's ACK lets the sender retire the stream), or it
  /// carries a PING or MTU probe (the sender is timing the answer), or it is
  /// the [ackElicitingThreshold]-th unacknowledged packet. Later: the ACK
  /// timer. Every packet used to be acknowledged on arrival, one datagram
  /// sent for every datagram received.
  void _noteReceived(UDXPacket packet) {
    final now = clock.now();
    var edge = false;
    for (final f in packet.frames) {
      if (f is StreamFrame && (f.isSyn || f.isFin)) {
        edge = true;
        break;
      }
      if (f is PingFrame || f is MtuProbeFrame) {
        edge = true;
        break;
      }
    }

    final hadAny = _recvd.any;
    final before = _recvd.largest;
    final outOfOrder = _recvd.add(packet.sequence);
    if (!hadAny || _recvd.largest != before) {
      _largestArrival = now;
    }
    _ackPending++;
    if (outOfOrder || edge || _ackPending >= ackElicitingThreshold) {
      _sendConnectionAck();
      return;
    }
    if (_ackTimer == null) {
      var delay = _congestionController.smoothedRtt ~/ 4;
      if (delay < minAckDelay) delay = minAckDelay;
      if (delay > maxAckDelay) delay = maxAckDelay;
      _ackTimer = clock.timer(delay, () {
        _ackTimer = null;
        if (_ackPending > 0) _sendConnectionAck();
      });
    }
  }

  /// Sends the ACK for everything received, with ranges from the history,
  /// and disarms the ACK timer.
  void _sendConnectionAck() {
    _ackTimer?.cancel();
    _ackTimer = null;
    _ackPending = 0;
    if (_closing || !_recvd.any) return;

    var ackDelayMs = 0;
    final arrival = _largestArrival;
    if (arrival != null) {
      ackDelayMs = (clock.now() - arrival).inMilliseconds.clamp(0, 65535);
    }
    final ackFrame = _recvd.frame(ackDelayMs);
    if (UdxLogging.info) {
      UdxLogging.infoLog('[DIAG-UDX-ACK-OUT] largest=${ackFrame.largestAcked} '
          'first=${ackFrame.firstAckRangeLength} ranges=${ackFrame.ackRanges.length} delay=${ackDelayMs}ms');
    }

    // ACK-only packets reuse last sent sequence to avoid consuming new sequences
    final ackSeq = _packetManager.lastSentPacketNumber >= 0
        ? _packetManager.lastSentPacketNumber
        : 0;

    final ackPacket = UDXPacket(
      destinationCid: cids.remoteCid,
      sourceCid: cids.localCid,
      destinationStreamId: 0,
      sourceStreamId: 0,
      sequence: ackSeq,
      frames: [ackFrame],
    );

    try {
      send(ackPacket.toBytes());
    } catch (_) {
      // The socket closed under us; nothing to acknowledge to.
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
    
    if (UdxLogging.info) {
      UdxLogging.infoLog('[DIAG-UDX-SEND] ${data.length}B to=${remoteAddress.address}:$remotePort');
    }

    try {
      multiplexer.send(data, remoteAddress, remotePort);
    } on SocketException catch (e) {
      emit('error', {'error': e, 'message': 'Send failed: ${e.message}'});
      close();
      rethrow;
    }
  }

  /// Called when the peer's address has been validated.
  /// Flushes any packets that were queued due to amplification limits.
  void _onAddressValidated() {
    if (_addressValidated) return;

    _addressValidated = true;
    emit('addressValidated');

    // Flush all pending packets
    for (final packet in _pendingPackets) {
      try {
        multiplexer.send(packet, remoteAddress, remotePort);
      } on SocketException catch (e) {
        emit('error', {'error': e, 'message': 'Flush failed: ${e.message}'});
        _pendingPackets.clear();
        close();
        return;
      }
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
    _idleTimer?.cancel();
    _ackTimer?.cancel();
    notifySendCredit();
    UdxLogging.warn(
        'socket closeWithError: code=$errorCode reason="$reason" '
        'cid=${cids.localCid} peer=${remoteAddress.address}:$remotePort streams=${_registeredStreams.length}');

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

      _lostQueue.dispose();
      _packetManager.destroy();
      _congestionController.destroy();

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
    _idleTimer?.cancel();
    _ackTimer?.cancel();
    notifySendCredit();
    UdxLogging.warn(
        'socket close(): cid=${cids.localCid} peer=${remoteAddress.address}:$remotePort '
        'streams=${_registeredStreams.length}');

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

      _lostQueue.dispose();
      _packetManager.destroy();
      _congestionController.destroy();

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
  /// The stream a packet is for: by our local id (the packet's destination
  /// stream id), falling back to the sender's id. go-udx and js-udx never learn
  /// the peer's id for a stream they opened, so they address it to 0 and
  /// identify it by their own id alone, as STREAM frames are already routed.
  UDXStream? _findStream(int destinationStreamId, int sourceStreamId) {
    final stream = _registeredStreams[destinationStreamId];
    // A stream the peer opened is the peer's stream [sourceStreamId]; a hit on
    // our id for a different one of its streams is a collision, not a match.
    if (stream != null &&
        (sourceStreamId == 0 || stream.isInitiator || stream.remoteId == sourceStreamId)) {
      return stream;
    }
    if (sourceStreamId == 0) return null;
    for (final candidate in _registeredStreams.values) {
      if (candidate.remoteId == sourceStreamId) return candidate;
    }
    return null;
  }

  int _nextIncomingStreamId = 2;

  /// The local id for a stream the peer is opening. A peer that names one
  /// (dart-libp2p picks both ids of its first stream) gets it if it's free.
  /// go-udx and js-udx never learn our id for a stream they open: they address
  /// it to 0 throughout and identify it by their own id. Those, and any id
  /// already taken, get the next free even id, as a go-udx acceptor would.
  int allocateIncomingStreamId(int requested) {
    if (requested != 0 && !_registeredStreams.containsKey(requested)) return requested;
    while (_nextIncomingStreamId == 0 || _registeredStreams.containsKey(_nextIncomingStreamId)) {
      _nextIncomingStreamId = (_nextIncomingStreamId + 2) & 0xFFFFFFFF;
    }
    final id = _nextIncomingStreamId;
    _nextIncomingStreamId = (id + 2) & 0xFFFFFFFF;
    return id;
  }

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
    _pathChallengeTimer = clock.timer(const Duration(seconds: 5), () {
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

  /// Sends a PING under a fresh sequence and waits for its acknowledgement:
  /// true if the peer answered within [timeout]. Both peers acknowledge a
  /// numbered PING at once. The packet is tracked until acknowledged or the
  /// wait ends, so its ACK is matched (and gives an RTT sample); it is never
  /// retransmitted. A later packet's acknowledgement also answers, since it
  /// proves the same thing.
  ///
  /// The PING used to be sent untracked, so on a connection with nothing
  /// else in flight its ACK matched nothing and this always timed out.
  Future<bool> ping({Duration timeout = const Duration(seconds: 5)}) async {
    if (_closing || closing) return false;

    final pingSequence = _packetManager.nextSequence;
    final packet = UDXPacket(
      destinationCid: cids.remoteCid,
      sourceCid: cids.localCid,
      destinationStreamId: 0, // Connection-level packet
      sourceStreamId: 0, // Connection-level packet
      sequence: pingSequence,
      frames: [PingFrame()],
    );

    final completer = Completer<bool>();
    Timer? timeoutTimer;
    StreamSubscription? ackSubscription;

    void finish(bool answered) {
      if (completer.isCompleted) return;
      timeoutTimer?.cancel();
      ackSubscription?.cancel();
      _packetManager.forget(pingSequence);
      completer.complete(answered);
    }

    ackSubscription = on('ack').listen((event) {
      final data = event.data;
      if (data is Map && data['largestAcked'] is int && (data['largestAcked'] as int) >= pingSequence) {
        finish(true);
      }
    });
    timeoutTimer = clock.timer(timeout, () => finish(false));

    _packetManager.trackUntilAcked(packet);
    try {
      send(packet.toBytes());
    } catch (e) {
      finish(false);
    }

    return completer.future;
  }

  // --- PMTUD Methods ---

  void _sendMtuProbeIfNeeded() {
    if (!_pmtudController.shouldSendProbe()) {
      return;
    }

    final (probePacket, sequence) = _pmtudController.buildProbePacket(
        cids.remoteCid, cids.localCid, 0, 0, _packetManager.nextSequence);
    
    send(probePacket.toBytes());

    final timer = clock.timer(const Duration(seconds: 3), () {
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
      notifySendCredit();
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

  /// The peer's connection-level limit on what we may send (its last MAX_DATA).
  int get remoteConnectionMaxData => _remoteConnectionMaxData;

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
