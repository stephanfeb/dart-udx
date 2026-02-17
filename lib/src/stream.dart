import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'cid.dart';
import 'events.dart';
import 'udx.dart';
import 'socket.dart';
import 'packet.dart';

/// Defines the directionality of a stream
enum StreamType {
  /// Bidirectional stream - both ends can send and receive
  bidirectional,

  /// Unidirectional stream - local endpoint sends, remote receives
  unidirectionalLocal,

  /// Unidirectional stream - remote endpoint sends, local receives
  unidirectionalRemote,
}

/// Helper class for QUIC-style stream ID encoding
class StreamIdHelper {
  static StreamType getStreamType(int streamId, bool isInitiator) {
    final isUnidirectional = (streamId & 0x02) != 0;
    if (!isUnidirectional) {
      return StreamType.bidirectional;
    }
    final initiatedByServer = (streamId & 0x01) != 0;
    if ((isInitiator && !initiatedByServer) || (!isInitiator && initiatedByServer)) {
      return StreamType.unidirectionalLocal;
    } else {
      return StreamType.unidirectionalRemote;
    }
  }

  static int encodeStreamId(int baseId, bool isUnidirectional, bool isServer) {
    int id = baseId << 2;
    if (isServer) id |= 0x01;
    if (isUnidirectional) id |= 0x02;
    return id;
  }
}

/// A reliable, ordered stream over UDP.
///
/// With per-connection sequencing (QUIC RFC 9000), the stream no longer owns
/// packet sequencing, congestion control, or receive ordering. Those are handled
/// by the parent [UDPSocket]. The stream is a thin layer that:
/// - Receives data via [deliverData]/[deliverFin]/[deliverReset] from the socket
/// - Sends data via [socket.sendStreamPacket()]
class UDXStream with UDXEventEmitter implements StreamSink<Uint8List> {
  /// The UDX instance that created this stream
  final UDX udx;

  /// The socket this stream is connected to
  UDPSocket? _socket;

  /// The stream ID
  final int id;

  /// The type/directionality of this stream
  final StreamType streamType;

  /// Priority for this stream (0-255, lower value = higher priority)
  int priority = 128;

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

  /// Timestamp when the stream connected
  DateTime? connectedAt;

  /// Total bytes read from the stream
  int bytesRead = 0;

  /// Total bytes written to the stream
  int bytesWritten = 0;

  /// Whether the local write side has been closed (FIN sent)
  bool _localWriteClosed = false;

  /// Whether the remote write side has been closed (FIN received)
  bool _remoteWriteClosed = false;

  /// Whether this stream was created by this endpoint.
  final bool isInitiator;

  /// The maximum transmission unit (MTU)
  int get mtu => _mtu;
  int _mtu = 1400;

  int get _maxPayloadSize => _mtu - 16;

  /// Maximum number of retransmission attempts before considering packet lost
  int maxRetransmissionAttempts = 10;

  /// Total timeout tolerance for packet-level operations (in seconds)
  int packetTimeoutTolerance = 30;

  /// The round-trip time (from connection-level CC)
  Duration get rtt => _socket?.congestionController.smoothedRtt ?? const Duration(milliseconds: 100);

  /// The congestion window (from connection-level CC)
  int get cwnd => _socket?.congestionController.cwnd ?? 65536;

  /// The number of bytes in flight (from connection-level CC)
  int get inflight => _socket?.congestionController.inflight ?? 0;

  /// The local receive window size
  int get receiveWindow => _receiveWindow;
  int _receiveWindow = 65536;
  int _bytesReceivedSinceWindowUpdate = 0;

  /// The remote peer's receive window size
  int get remoteReceiveWindow => _remoteReceiveWindow;
  int _remoteReceiveWindow = 65536;

  /// The stream controller for data events
  final _dataController = StreamController<Uint8List>();

  /// A completer that resolves when the stream can send more data.
  Completer<void>? _drain;

  StreamSubscription? _remoteConnectionWindowUpdateSubscription;

  /// Whether the stream is in framed mode
  final bool framed;

  /// The initial sequence number (kept for API compatibility but not used for per-stream ordering)
  final int initialSeq;

  /// The firewall function
  final bool Function(UDPSocket socket, int port, String host)? firewall;

  /// Creates a new UDX stream
  UDXStream(
    this.udx,
    this.id, {
    this.streamType = StreamType.bidirectional,
    this.framed = false,
    this.initialSeq = 0,
    this.firewall,
    int? initialCwnd,
    this.isInitiator = false,
  });

  void _handleRemoteConnectionWindowUpdate(UDXEvent event) {
    if (_socket == null) return;
    if (_drain != null && !_drain!.isCompleted) {
      final socket = _socket;
      if (socket == null) return;
      final connWindowAvailable = socket.getAvailableConnectionSendWindow();
      if (inflight < cwnd && inflight < _remoteReceiveWindow && connWindowAvailable > 0) {
        _drain!.complete();
      }
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
    connectedAt = DateTime.now();

    socket.registerStream(this);
    _remoteConnectionWindowUpdateSubscription?.cancel();
    _remoteConnectionWindowUpdateSubscription = _socket!.on('remoteConnectionWindowUpdate').listen(_handleRemoteConnectionWindowUpdate);

    emit('connect');
  }

  // --- Data delivery methods (called by UDPSocket) ---

  /// Delivers data from the socket's connection-level receive ordering.
  void deliverData(Uint8List data) {
    if (data.isEmpty) return;
    bytesRead += data.length;
    if (!_dataController.isClosed) {
      _dataController.add(data);
    }
    if (_socket != null) {
      _socket!.onStreamDataProcessed(data.length);
    }
    // Send stream-level window update when 25% of receive window consumed.
    // Without this, the peer's stream flow controller blocks after exhausting
    // the initial 64KB window — killing the entire yamux mux on this stream.
    _bytesReceivedSinceWindowUpdate += data.length;
    if (_bytesReceivedSinceWindowUpdate > _receiveWindow ~/ 4) {
      _receiveWindow += _bytesReceivedSinceWindowUpdate;
      _bytesReceivedSinceWindowUpdate = 0;
      if (_connected && remoteId != null && _socket != null && !_socket!.closing) {
        _socket!.sendStreamPacket(
          remoteId!,
          id,
          [WindowUpdateFrame(windowSize: _receiveWindow)],
          trackForRetransmit: false,
        );
      }
    }
  }

  /// Delivers FIN from the socket.
  void deliverFin() {
    _remoteWriteClosed = true;
    if (!_dataController.isClosed) {
      _dataController.close();
    }
    emit('end');
    if (_localWriteClosed) {
      _close();
    }
  }

  /// Delivers RESET from the socket.
  void deliverReset(int errorCode) {
    addError(StreamResetError(errorCode));
    _close(isReset: true);
  }

  /// Delivers STOP_SENDING from the socket.
  void deliverStopSending(int errorCode) {
    _localWriteClosed = true;
    emit('stopSending', {'errorCode': errorCode});
    if (_remoteWriteClosed) {
      _close();
    }
  }

  /// Delivers WINDOW_UPDATE from the socket.
  void deliverWindowUpdate(int windowSize) {
    _remoteReceiveWindow = windowSize;
    if (_drain != null && !_drain!.isCompleted) {
      final connWindowAvailable = _socket?.getAvailableConnectionSendWindow() ?? 0;
      if (inflight < cwnd && inflight < _remoteReceiveWindow && connWindowAvailable > 0) {
        _drain!.complete();
      }
    }
    emit('drain');
  }

  /// Handles an incoming socket event (datagram).
  /// This is kept for backward compatibility but the socket now handles
  /// connection-level sequencing and calls deliverData/deliverFin/deliverReset directly.
  void internalHandleSocketEvent(dynamic event) {
    // With per-connection sequencing, the socket handles all receive ordering
    // and calls deliverData/deliverFin/deliverReset directly.
    // This method is kept as a no-op for any remaining callers.
  }

  @override
  Future<void> add(Uint8List data) async {
    if (streamType == StreamType.unidirectionalRemote) {
      throw StateError('UDXStream ($id): Cannot write to a receive-only unidirectional stream');
    }
    if (!_connected) throw StateError('UDXStream ($id): Stream is not connected');
    if (_socket == null) throw StateError('UDXStream ($id): Stream is not connected to a socket');
    if (_localWriteClosed) throw StateError('UDXStream ($id): Cannot write after closeWrite() has been called');

    if (remoteId == null || remoteHost == null || remotePort == null) {
      throw StateError('UDXStream ($id): Remote peer details not set');
    }
    if (data.isEmpty) return;

    final fragments = _fragmentData(data);
    for (final fragment in fragments) {
      await _sendFragment(fragment);
    }
    emit('send', data);
  }

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

  Future<void> _sendFragment(Uint8List fragment) async {
    final socket = _socket;
    if (socket == null) {
      throw StateError('UDXStream ($id): Socket is null during operation');
    }

    // Wait for handshake
    try {
      await socket.handshakeComplete.timeout(
        Duration(seconds: packetTimeoutTolerance),
        onTimeout: () {},
      );
    } catch (e) {
      // Continue with send attempt
    }

    // Wait for send window
    final completer = Completer<void>();
    Timer? timeoutTimer;

    void checkAndSend() {
      final connWindowAvailable = socket.getAvailableConnectionSendWindow();
      if (inflight < cwnd && inflight < _remoteReceiveWindow && connWindowAvailable > 0) {
        if (!completer.isCompleted) {
          completer.complete();
        }
      } else {
        if (_drain == null || _drain!.isCompleted) {
          _drain = Completer<void>();
        }
        Timer(Duration(milliseconds: 50), checkAndSend);
      }
    }

    timeoutTimer = Timer(Duration(seconds: packetTimeoutTolerance), () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });

    checkAndSend();

    try {
      await completer.future;
    } finally {
      timeoutTimer?.cancel();
    }

    // Wait for pacer
    try {
      await socket.congestionController.pacingController.waitUntilReady().timeout(
        Duration(seconds: 5),
        onTimeout: () {},
      );
    } catch (e) {
      // Continue without pacing
    }

    final currentSocket = _socket;
    if (currentSocket == null) {
      throw StateError('UDXStream ($id): Socket became null during operation');
    }
    if (currentSocket.closing) return;

    // Send via socket's connection-level packet manager
    bytesWritten += fragment.length;
    currentSocket.sendStreamPacket(
      remoteId!,
      id,
      [StreamFrame(data: fragment)],
    );
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
    if (_connected && remoteId != null && _socket != null && !_socket!.closing) {
      _socket!.sendStreamPacket(
        remoteId!,
        id,
        [WindowUpdateFrame(windowSize: _receiveWindow)],
        trackForRetransmit: false,
      );
    }
  }

  void setPriority(int newPriority) {
    priority = newPriority.clamp(0, 255);
    emit('priorityChanged', {'priority': priority});
  }

  Future<void> reset(int errorCode) async {
    if (!_connected) return;

    if (remoteId != null && _socket != null && !_socket!.closing) {
      _socket!.sendStreamPacket(
        remoteId!,
        id,
        [ResetStreamFrame(errorCode: errorCode)],
        trackForRetransmit: false,
      );
    }

    await _close(isReset: true);
  }

  Future<void> stopReceiving(int errorCode) async {
    if (!_connected || _remoteWriteClosed) return;

    if (remoteId != null && _socket != null && !_socket!.closing) {
      _socket!.sendStreamPacket(
        remoteId!,
        id,
        [StopSendingFrame(streamId: remoteId!, errorCode: errorCode)],
        trackForRetransmit: false,
      );
    }

    _remoteWriteClosed = true;
    if (!_dataController.isClosed) {
      _dataController.close();
    }
    emit('end');

    if (_localWriteClosed) {
      await _close();
    }
  }

  Future<void> closeWrite() async {
    if (_localWriteClosed) return;
    _localWriteClosed = true;

    if (!_connected || remoteId == null || _socket == null || _socket!.closing) return;

    // Send FIN via socket
    _socket!.sendStreamPacket(
      remoteId!,
      id,
      [StreamFrame(data: Uint8List(0), isFin: true)],
    );

    // Small delay to ensure FIN is sent
    await Future.delayed(Duration(milliseconds: 50));

    if (_remoteWriteClosed) {
      await _close();
    }
  }

  @override
  Future<void> close() async {
    await _close();
  }

  Future<void> _close({bool isReset = false}) async {
    if (!_connected) return;

    _localWriteClosed = true;
    _remoteWriteClosed = true;

    if (!isReset && remoteId != null && _socket != null && !_socket!.closing) {
      try {
        _socket!.sendStreamPacket(
          remoteId!,
          id,
          [StreamFrame(data: Uint8List(0), isFin: true)],
        );
        await Future.delayed(Duration(milliseconds: 50));
      } catch (e) {
        // Ignore errors during close
      }
    }

    _connected = false;

    try {
      if (!_dataController.isClosed) {
        _dataController.close();
      }
      _socket?.unregisterStream(id);

      await _remoteConnectionWindowUpdateSubscription?.cancel();
      _remoteConnectionWindowUpdateSubscription = null;

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
    StreamType streamType = StreamType.bidirectional,
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
      streamType: streamType,
      isInitiator: true,
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
    stream._connected = true;
    stream.connectedAt = DateTime.now();

    try {
      // Send SYN via socket's connection-level packet manager
      socket.sendStreamPacket(
        remoteId,
        localId,
        [StreamFrame(data: Uint8List(0), isSyn: true)],
      );

      if (!socket.closing) {
        await socket.sendMaxDataFrame(UDPSocket.defaultInitialConnectionWindow);
        await socket.sendMaxStreamsFrame();
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
    StreamType streamType = StreamType.bidirectional,
  }) {
    if (socket.closing) {
      throw StateError('UDXStream.createIncoming: Socket is closing');
    }

    final stream = UDXStream(
      udx,
      localId,
      streamType: streamType,
      isInitiator: false,
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
    stream._connected = true;
    stream.connectedAt = DateTime.now();

    // Send SYN-ACK via socket's connection-level packet manager
    // The SYN has already been received and processed by the socket.
    // We send our SYN back to establish the bidirectional stream.
    socket.sendStreamPacket(
      remoteId,
      localId,
      [StreamFrame(data: Uint8List(0), isSyn: true)],
    );

    if (!socket.closing) {
      socket.sendMaxDataFrame(UDPSocket.defaultInitialConnectionWindow);
    }

    stream.emit('accepted');
    return stream;
  }

  // --- Test Hooks ---
  /// Sets the internal socket. For testing purposes only.
  void setSocketForTest(UDPSocket? socket) {
    _socket = socket;
  }

  // Calculate max payload size based on default MTU (1400) minus headers (16)
  static int getMaxPayloadSizeTestHook() => 1400 - 16;
}
