import 'cid.dart';

/// Observer interface for UDX metrics and events.
/// 
/// This interface allows external systems to observe low-level UDX transport
/// events such as handshakes, retransmissions, congestion control changes,
/// and flow control events.
abstract class UdxMetricsObserver {
  /// Called when a UDX handshake begins.
  /// 
  /// [localCid] is the local connection ID.
  /// [remoteCid] is the remote connection ID.
  /// [remoteAddr] is the remote address in "host:port" format.
  void onHandshakeStart(ConnectionId localCid, ConnectionId remoteCid, String remoteAddr);
  
  /// Called when a UDX handshake completes (success or failure).
  /// 
  /// [localCid] is the local connection ID.
  /// [duration] is how long the handshake took.
  /// [success] indicates whether the handshake succeeded.
  /// [error] contains the error message if the handshake failed.
  void onHandshakeComplete(ConnectionId localCid, Duration duration, bool success, String? error);
  
  /// Called when a new UDX stream is created.
  /// 
  /// [cid] is the connection ID this stream belongs to.
  /// [streamId] is the stream ID.
  /// [isInitiator] indicates whether this endpoint initiated the stream.
  void onStreamCreated(ConnectionId cid, int streamId, bool isInitiator);
  
  /// Called when a UDX stream is closed.
  /// 
  /// [cid] is the connection ID.
  /// [streamId] is the stream ID.
  /// [duration] is how long the stream was open.
  /// [bytesRead] is the total bytes read from the stream.
  /// [bytesWritten] is the total bytes written to the stream.
  void onStreamClosed(ConnectionId cid, int streamId, Duration duration, int bytesRead, int bytesWritten);
  
  /// Called when an attempt to create a stream fails because the limit is exceeded.
  /// 
  /// [cid] is the connection ID.
  /// [currentCount] is the current number of active streams.
  /// [limit] is the maximum allowed streams.
  void onStreamLimitExceeded(ConnectionId cid, int currentCount, int limit);
  
  /// Called when the congestion window is updated.
  /// 
  /// [cid] is the connection ID.
  /// [oldCwnd] is the previous congestion window size.
  /// [newCwnd] is the new congestion window size.
  /// [reason] describes why the window changed (e.g., "ack", "loss", "timeout").
  void onCongestionWindowUpdate(ConnectionId cid, int oldCwnd, int newCwnd, String reason);
  
  /// Called when flow control blocks sending on a stream.
  /// 
  /// [cid] is the connection ID.
  /// [streamId] is the stream ID that was blocked.
  /// [pendingBytes] is the number of bytes waiting to be sent.
  /// [windowSize] is the current flow control window size.
  void onFlowControlBlocked(ConnectionId cid, int streamId, int pendingBytes, int windowSize);
  
  /// Called when a new RTT sample is calculated.
  /// 
  /// [cid] is the connection ID.
  /// [rtt] is the raw RTT sample.
  /// [smoothedRtt] is the smoothed RTT (SRTT).
  /// [rttVar] is the RTT variance.
  void onRttSample(ConnectionId cid, Duration rtt, Duration smoothedRtt, Duration rttVar);
  
  /// Called when a packet is retransmitted.
  /// 
  /// [cid] is the connection ID.
  /// [seq] is the sequence number of the retransmitted packet.
  /// [attemptCount] is how many times this packet has been retransmitted.
  /// [rto] is the current retransmission timeout.
  void onPacketRetransmit(ConnectionId cid, int seq, int attemptCount, Duration rto);
  
  /// Called when packet loss is detected.
  /// 
  /// [cid] is the connection ID.
  /// [seq] is the sequence number of the lost packet.
  /// [lossType] describes how loss was detected: 'timeout' or 'fast_retransmit'.
  void onPacketLoss(ConnectionId cid, int seq, String lossType);
  
  /// Called when path migration starts (address change detected).
  /// 
  /// [cid] is the connection ID.
  /// [oldAddr] is the previous remote address.
  /// [newAddr] is the new remote address being validated.
  void onPathMigrationStart(ConnectionId cid, String oldAddr, String newAddr);
  
  /// Called when path migration completes.
  /// 
  /// [cid] is the connection ID.
  /// [success] indicates whether the migration succeeded.
  void onPathMigrationComplete(ConnectionId cid, bool success);
}

