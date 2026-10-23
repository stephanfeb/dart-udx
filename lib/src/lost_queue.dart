import 'dart:async';
import 'dart:typed_data';

import 'clock.dart';
import 'congestion.dart';
import 'packet.dart';

/// Packets declared lost, waiting to be re-sent as the congestion window and
/// the pacer allow, oldest first (go-udx's lostQueue / flushLost).
///
/// A lost packet's bytes left flight when it was declared lost
/// (CongestionController.onPacketLost); when it goes out again it takes a
/// fresh sequence (PacketManager.resend) and is booked as the new packet it
/// is. When the pacer says wait, a timer resumes the flush; when the window
/// is full, the next ACK does (the socket flushes before waking writers, so
/// lost data goes before new data).
class LostQueue {
  LostQueue({
    required this.packetManager,
    required this.congestionController,
    required this.clock,
    required this.send,
    this.maxDatagram,
  });

  /// The datagram size the path carries now (MtuDiscovery): a queued packet
  /// larger than it is re-chunked before it goes out.
  final int Function()? maxDatagram;

  final PacketManager packetManager;
  final CongestionController congestionController;
  final Clock clock;

  /// Puts an encoded packet on the wire.
  final void Function(Uint8List bytes) send;

  final List<UDXPacket> _queue = [];
  Timer? _timer;

  /// How many lost packets wait for window to be re-sent.
  int get length => _queue.length;

  /// Queues [lost] and re-sends what the window admits now.
  void add(List<UDXPacket> lost) {
    _queue.addAll(lost);
    flush();
  }

  /// Re-sends queued packets, oldest first, while the window admits them and
  /// the pacer allows.
  void flush() {
    _timer?.cancel();
    _timer = null;
    while (_queue.isNotEmpty) {
      final packet = _queue.first;
      if (packet.isAcked) {
        _queue.removeAt(0);
        continue;
      }
      final limit = maxDatagram?.call();
      if (limit != null && (packet.wireSize ?? packet.toBytes().length) > limit) {
        // The path shrank under it: its pieces take its place in the
        // queue, each through the gates below.
        final pieces = packetManager.fitToPath(packet, limit);
        if (pieces.length > 1) {
          _queue.replaceRange(0, 1, pieces);
          continue;
        }
      }
      final wait = congestionController.pacingController.timeUntilSend();
      if (wait > Duration.zero) {
        _timer = clock.timer(wait, flush);
        return;
      }
      final size = packet.dataBytes;
      if (congestionController.inflight + size > congestionController.cwnd) return;
      _queue.removeAt(0);
      if (packetManager.resend(packet) == null) continue;
      congestionController.onPacketSent(size);
      final bytes = packet.toBytes();
      congestionController.pacingController.onPacketSent(bytes.length);
      send(bytes);
    }
  }

  /// Stops the pacer wait and forgets what is queued.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _queue.clear();
  }
}
