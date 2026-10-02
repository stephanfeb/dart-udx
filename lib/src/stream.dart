import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'cid.dart';
import 'events.dart';
import 'logging.dart';
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

  /// The local receive window size, in bytes. Auto-tuned upward for streams
  /// that actually move bulk data, capped at [_maxReceiveWindow].
  ///
  /// This is a window *size*. What goes on the wire is an absolute offset,
  /// [_lastAdvertised], computed as bytesConsumed + this window.
  int get receiveWindow => _receiveWindow;
  static const int _initialReceiveWindow = 65536;
  static const int _maxReceiveWindow = 4 * 1024 * 1024;
  int _receiveWindow = _initialReceiveWindow;

  /// Backstop on bytes held out of order. Flow control is what actually bounds
  /// the buffer; this only catches a peer ignoring its limit, so it sits above
  /// the largest window rather than at it.
  static const int _maxOutOfOrderBytes = 2 * _maxReceiveWindow;

  /// Cumulative bytes handed to the application, and the absolute offset last
  /// advertised to the peer.
  ///
  /// Flow control is anchored to *consumption*, not receipt. Advertising on
  /// receipt grants credit whether or not anyone is reading, which is no
  /// back-pressure at all: a fast sender against a slow reader grows this
  /// stream's buffer without bound. The peer's matching accounting lives in
  /// go-udx's StreamFlowController.
  int _bytesConsumed = 0;
  int _lastAdvertised = _initialReceiveWindow;

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
      if (inflight < cwnd &&
          bytesWritten < _remoteReceiveWindow &&
          connWindowAvailable > 0) {
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

  /// Bytes that arrived ahead of a gap, keyed by their offset.
  final Map<int, Uint8List> _recvOOO = {};

  /// Total bytes handed to the application so far, and therefore the offset the
  /// next contiguous chunk must start at.
  int _recvOffset = 0;

  /// Bytes currently held in [_recvOOO], so the buffer can be bounded.
  int _oooBytes = 0;

  /// Where the stream ends, once the peer has told us. A FIN can overtake data
  /// still in flight, so arrival is not the same as completion.
  int? _finalSize;

  /// Delivers a chunk at its offset in the stream, releasing whatever has
  /// become contiguous.
  ///
  /// Ordering is per stream, on these offsets. It used to happen at the socket,
  /// on the connection's packet sequence number, which meant a gap belonging to
  /// one stream stalled delivery on all of them.
  void deliverData(int offset, Uint8List data) {
    if (data.isEmpty) return;

    final end = offset + data.length;

    // Already delivered. A retransmission of bytes the application has seen
    // arrives here, and must not be handed over twice — that corrupts the byte
    // stream, and the Noise layer above fails its MAC rather than merely
    // reading duplicates.
    if (end <= _recvOffset) return;

    // Partly delivered: keep only the tail that is new.
    if (offset < _recvOffset) {
      data = Uint8List.sublistView(data, _recvOffset - offset);
      offset = _recvOffset;
    }

    if (offset > _recvOffset) {
      // Ahead of a gap. Hold it until the missing bytes arrive.
      //
      // Flow control is the real bound here; the backstop below only catches a
      // peer ignoring its limit, which is why it sits above the largest window
      // rather than at it. Discarding is never safe: the packet was
      // acknowledged on arrival, so the sender has already stopped tracking it
      // and will never send those bytes again, stranding the stream at this
      // offset for good. A backstop equal to the maximum window fires during
      // legitimate transfers, because a stream whose window has grown to the
      // maximum can have that whole window sitting out of order.
      if (_recvOOO.containsKey(offset)) return;
      if (_oooBytes + data.length > _maxOutOfOrderBytes) {
        addError(StreamResetError(2)); // flow control violation
        _close(isReset: true);
        return;
      }
      _recvOOO[offset] = Uint8List.fromList(data);
      _oooBytes += data.length;
      _accountReceived(data.length);
      return;
    }

    _emitContiguous(data);

    // Release anything that was waiting on the bytes just delivered.
    while (true) {
      final next = _recvOOO.remove(_recvOffset);
      if (next == null) break;
      _oooBytes -= next.length;
      _emitContiguous(next, alreadyAccounted: true);
    }

    _checkFinished();
  }

  /// Hands a contiguous chunk to the application and advances the offset.
  void _emitContiguous(Uint8List data, {bool alreadyAccounted = false}) {
    _recvOffset += data.length;
    bytesRead += data.length;
    if (UdxLogging.verbose) {
      UdxLogging.infoLog(
          '[UDX-STREAM $id] deliverData: ${data.length} bytes, totalBytesRead=$bytesRead');
    }
    if (!_dataController.isClosed) {
      _dataController.add(data);
    }
    if (!alreadyAccounted) _accountReceived(data.length);
  }

  /// Records bytes as received for connection-level accounting. Bytes waiting
  /// out of order count too — they are buffered either way.
  void _accountReceived(int n) {
    if (_socket != null) {
      _socket!.onStreamDataProcessed(n);
    }
    // No window update here. Receipt only buffers; the window reopens in
    // _onDataConsumed, when the application actually takes the bytes.
  }

  /// Completes the stream once every byte up to the final size has arrived.
  void _checkFinished() {
    final finalSize = _finalSize;
    if (finalSize == null || _remoteWriteClosed || _recvOffset < finalSize) {
      return;
    }
    _remoteWriteClosed = true;
    if (!_dataController.isClosed) {
      _dataController.close();
    }
    emit('end');
    if (_localWriteClosed) {
      _close();
    }
  }

  /// Records bytes handed to the application and reopens the receive window.
  ///
  /// An update is sent once the peer's remaining credit under our last
  /// advertisement falls below half the window. That threshold is stable under
  /// growth: each update grants at least half a window of fresh credit and the
  /// next threshold is measured against the same window, so the grant can never
  /// fall behind the threshold.
  ///
  /// The earlier scheme granted roughly a quarter window per update while
  /// raising the trigger along with the window, which diverged and stalled the
  /// stream outright — the deadlock this class previously worked around by
  /// pinning the trigger to the initial window size.
  void _onDataConsumed(int n) {
    _bytesConsumed += n;

    if (_lastAdvertised - _bytesConsumed >= _receiveWindow ~/ 2) return;

    // Auto-tune: a stream that keeps draining its window earns a bigger one.
    // Because an update only fires after half a window is drained, a stream has
    // to genuinely move this much data before reaching the cap.
    if (_receiveWindow < _maxReceiveWindow) {
      _receiveWindow *= 2;
      if (_receiveWindow > _maxReceiveWindow) _receiveWindow = _maxReceiveWindow;
    }

    final limit = _bytesConsumed + _receiveWindow;
    if (limit > _lastAdvertised) _lastAdvertised = limit;

    if (_connected && remoteId != null && _socket != null && !_socket!.closing) {
      _socket!.sendStreamPacket(
        remoteId!,
        id,
        // The offset grows without bound; the frame field is a uint32, so send
        // it modulo 2^32 and let the peer reconstruct the full value (see
        // deliverWindowUpdate). Masking explicitly rather than relying on
        // setUint32 truncation.
        [WindowUpdateFrame(windowSize: _lastAdvertised & 0xFFFFFFFF)],
        trackForRetransmit: false,
      );
    }
  }

  /// Records where the stream ends. [finalSize] is the offset one past the
  /// peer's last byte.
  ///
  /// A FIN is a flag on a frame that can overtake data still in flight, so
  /// closing the stream on its arrival would silently truncate whatever had not
  /// caught up. The stream finishes when the delivered bytes reach [finalSize],
  /// which may be now or may be several packets away.
  void deliverFin(int finalSize) {
    _finalSize = finalSize;
    _checkFinished();
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
  ///
  /// [windowSize] is an ABSOLUTE OFFSET: the highest cumulative byte position
  /// the peer will accept on this stream, not a count of bytes that may be
  /// outstanding. Both implementations already advertise it this way — see
  /// _deliverDataInternal below, which sends _receiveWindow as
  /// initialWindow + cumulative bytes received.
  ///
  /// The value arrives modulo 2^32 because the frame field is a uint32, so
  /// recover the full offset by choosing the candidate nearest the limit we
  /// already hold (RFC 1982 serial-number arithmetic). This is unambiguous
  /// because the true offset is always within one receive window of the
  /// current limit, and the window is orders of magnitude below 2^32.
  void deliverWindowUpdate(int windowSize) {
    const modulus = 1 << 32;
    final base = _remoteReceiveWindow & ~(modulus - 1);
    var candidate = base + windowSize;
    for (final alt in [candidate - modulus, candidate + modulus]) {
      if ((alt - _remoteReceiveWindow).abs() <
          (candidate - _remoteReceiveWindow).abs()) {
        candidate = alt;
      }
    }
    // Monotonic: a stale or reordered frame must never revoke granted credit.
    if (candidate > _remoteReceiveWindow) {
      _remoteReceiveWindow = candidate;
    }

    if (_drain != null && !_drain!.isCompleted) {
      final connWindowAvailable = _socket?.getAvailableConnectionSendWindow() ?? 0;
      if (inflight < cwnd &&
          bytesWritten < _remoteReceiveWindow &&
          connWindowAvailable > 0) {
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
      // bytesWritten is this stream's cumulative sent total, which is what the
      // peer's advertised offset bounds. Comparing `inflight` here instead
      // stopped binding as soon as the offset outgrew one window's worth of
      // outstanding bytes, leaving cwnd as the only limit — and `inflight` is
      // the connection-level counter, so it was the wrong quantity for a
      // per-stream limit regardless.
      if (inflight < cwnd &&
          bytesWritten + fragment.length <= _remoteReceiveWindow &&
          connWindowAvailable > 0) {
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

    // Send via socket's connection-level packet manager. The fragment's
    // position in the stream is where the write had reached before it, which is
    // what the peer reassembles on.
    final fragmentOffset = bytesWritten;
    bytesWritten += fragment.length;
    currentSocket.sendStreamPacket(
      remoteId!,
      id,
      [StreamFrame(data: fragment, offset: fragmentOffset)],
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

  /// The peer is out of send credit (STREAM_DATA_BLOCKED). Re-advertise the
  /// current limit without growing the window, as go-udx does. WINDOW_UPDATE
  /// is never retransmitted, so this is what repairs a stream whose update was
  /// lost; not growing the window means a peer can't inflate our receive
  /// buffer just by claiming to be blocked.
  void deliverStreamDataBlocked() {
    final limit = _bytesConsumed + _receiveWindow;
    if (limit > _lastAdvertised) _lastAdvertised = limit;
    if (_connected && remoteId != null && _socket != null && !_socket!.closing) {
      _socket!.sendStreamPacket(
        remoteId!,
        id,
        // See _onDataConsumed: sent modulo 2^32, reconstructed by the peer.
        [WindowUpdateFrame(windowSize: _lastAdvertised & 0xFFFFFFFF)],
        trackForRetransmit: false,
      );
    }
  }

  /// Sets the receive window *size* and re-advertises.
  ///
  /// Note this cannot revoke credit already granted: what goes on the wire is
  /// bytesConsumed + newSize, and the peer applies offsets monotonically. A
  /// size smaller than the outstanding grant simply takes effect once the peer
  /// catches up to the offset it already holds.
  void setWindow(int newSize) {
    _receiveWindow = newSize;
    final limit = _bytesConsumed + _receiveWindow;
    if (limit > _lastAdvertised) _lastAdvertised = limit;
    if (_connected && remoteId != null && _socket != null && !_socket!.closing) {
      _socket!.sendStreamPacket(
        remoteId!,
        id,
        // See _onDataConsumed: sent modulo 2^32, reconstructed by the peer.
        [WindowUpdateFrame(windowSize: _lastAdvertised & 0xFFFFFFFF)],
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
      // A FIN carries no data, so its offset is this stream's final size. The
      // peer needs that to know when it has everything: a FIN can overtake data
      // still in flight, and treating its arrival as the end would truncate the
      // tail.
      [StreamFrame(data: Uint8List(0), isFin: true, offset: bytesWritten)],
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
          // A FIN carries no data, so its offset is this stream's final size. The
      // peer needs that to know when it has everything: a FIN can overtake data
      // still in flight, and treating its arrival as the end would truncate the
      // tail.
      [StreamFrame(data: Uint8List(0), isFin: true, offset: bytesWritten)],
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

  /// Data received on this stream.
  ///
  /// Bytes are counted as consumed at the moment they are delivered to the
  /// subscriber, which is what drives the receive window. If nobody is
  /// listening, or the subscription is paused, events sit in the controller,
  /// nothing is counted, the advertised offset stops advancing and the sender
  /// stalls — which is the back-pressure. Cached because _dataController is
  /// single-subscription, so the mapped view must be a single stable object.
  Stream<Uint8List> get data => _consumedData ??=
      _dataController.stream.map((chunk) {
        _onDataConsumed(chunk.length);
        return chunk;
      });
  Stream<Uint8List>? _consumedData;
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
      socket.allocateIncomingStreamId(localId),
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
      stream.id,
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
