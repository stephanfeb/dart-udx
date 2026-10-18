import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/multiplexer.dart';
import 'package:test/test.dart';

/// A multiplexer whose UDP socket stops by itself (the OS closes it, or an
/// error closes it: Dart closes a socket on any error) says so, and closes
/// its connections, rather than keep sending into a dead socket.
void main() {
  late RawDatagramSocket raw;
  late UDXMultiplexer mux;

  setUp(() async {
    raw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    mux = UDXMultiplexer(raw);
  });

  test('a socket that stops by itself is lost, and its connections close', () async {
    final conn = mux.createSocket(UDX(), '127.0.0.1', 9);
    final closed = conn.on('close').first.timeout(const Duration(seconds: 5));
    final connectionsDone = mux.connections.toList();

    raw.close(); // what the OS does to the multiplexer's socket

    await mux.done.timeout(const Duration(seconds: 5));
    expect(mux.lost, isTrue);
    await closed;
    await connectionsDone.timeout(const Duration(seconds: 5));
    expect(mux.socketsByCid, isEmpty);
    // Sending into it no longer reaches the socket, and does not throw.
    mux.send(Uint8List(20), InternetAddress.loopbackIPv4, 9);
  });

  test('close() is not a loss', () async {
    mux.close();
    await mux.done.timeout(const Duration(seconds: 5));
    expect(mux.lost, isFalse);
  });
}
