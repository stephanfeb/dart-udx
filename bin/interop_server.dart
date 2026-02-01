// interop_server is a raw UDX v2 packet echo server for cross-language testing.
// Protocol: receives UDX v2 packets, echoes STREAM frame data back with swapped CIDs/stream IDs.
// Prints "READY <port>" to stderr when listening.
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_udx/src/packet.dart';

void main() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  stderr.writeln('READY $port');

  socket.listen((event) {
    if (event != RawSocketEvent.read) return;

    final datagram = socket.receive();
    if (datagram == null) return;

    final data = datagram.data;
    if (data.length < 18) return; // Minimum v2 packet size

    try {
      final pkt = UDXPacket.fromBytes(data);

      // Find STREAM frames and echo them back
      for (final frame in pkt.frames) {
        if (frame is! StreamFrame || frame.data.isEmpty) continue;

        // Build response: swap CIDs and stream IDs
        final resp = UDXPacket(
          destinationCid: pkt.sourceCid,
          sourceCid: pkt.destinationCid,
          sequence: pkt.sequence + 1,
          destinationStreamId: pkt.sourceStreamId,
          sourceStreamId: pkt.destinationStreamId,
          frames: [
            StreamFrame(data: Uint8List.fromList(frame.data)),
          ],
        );

        final respBytes = resp.toBytes();
        socket.send(respBytes, datagram.address, datagram.port);
        stderr.writeln('echoed ${frame.data.length} bytes to ${datagram.address}:${datagram.port}');
      }
    } catch (e) {
      stderr.writeln('error: $e');
    }
  });
}
