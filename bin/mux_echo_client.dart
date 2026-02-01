/// Multiplexer-level echo client for Go↔Dart interop testing.
/// Usage: dart run bin/mux_echo_client.dart <port>
/// Creates a UDX connection to Go's Multiplexer, sends data, reads echo, exits 0 on success.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_udx/dart_udx.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln('Usage: dart run bin/mux_echo_client.dart <port>');
    exit(1);
  }
  final port = int.parse(arguments[0]);

  stderr.writeln('Dart: binding socket...');
  final rawSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final mux = UDXMultiplexer(rawSocket);

  stderr.writeln('Dart: creating UDPSocket to 127.0.0.1:$port...');
  final udpSocket = mux.createSocket(UDX(), '127.0.0.1', port);

  final localId = 1;
  final remoteId = 0; // Don't know remote's stream ID yet
  stderr.writeln('Dart: creating outgoing stream (localId=$localId, remoteId=$remoteId)...');

  try {
    final stream = await UDXStream.createOutgoing(
      UDX(),
      udpSocket,
      localId,
      remoteId,
      '127.0.0.1',
      port,
    );
    stderr.writeln('Dart: stream created (id=${stream.id}), waiting for handshake...');

    await udpSocket.handshakeComplete.timeout(Duration(seconds: 5));
    stderr.writeln('Dart: handshake complete');

    // Write data
    final payload = Uint8List.fromList('hello from dart mux'.codeUnits);
    await stream.add(payload);
    stderr.writeln('Dart: wrote ${payload.length} bytes');

    // Read echo via the data stream
    final echo = await stream.data.first.timeout(Duration(seconds: 5));
    stderr.writeln('Dart: read ${echo.length} bytes: ${String.fromCharCodes(echo)}');

    if (String.fromCharCodes(echo) != String.fromCharCodes(payload)) {
      stderr.writeln('FAIL: echo mismatch');
      exit(1);
    }

    await stream.close();
    mux.close();
    stderr.writeln('OK');
    exit(0);
  } catch (e, s) {
    stderr.writeln('FAIL: $e');
    stderr.writeln(s);
    mux.close();
    exit(1);
  }
}
