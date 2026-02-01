import 'dart:io';
import 'dart:typed_data';
import 'package:dart_udx/dart_udx.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln('Usage: dart run test.dart <port>');
    exit(1);
  }
  final port = int.parse(arguments[0]);
  
  stderr.writeln('Dart: binding socket...');
  final rawSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  stderr.writeln('Dart: creating multiplexer...');
  final mux = UDXMultiplexer(rawSocket);
  
  stderr.writeln('Dart: creating socket to 127.0.0.1:$port...');
  final udpSocket = mux.createSocket(UDX(), '127.0.0.1', port);
  
  // Create a stream and send data
  final localId = 1;
  final remoteId = 0; // Don't know remote's stream ID yet
  stderr.writeln('Dart: creating outgoing stream (localId=$localId, remoteId=$remoteId)...');
  
  final stream = await UDXStream.createOutgoing(
    UDX(), udpSocket, localId, remoteId, '127.0.0.1', port,
  );
  stderr.writeln('Dart: stream created, waiting for handshake...');
  
  await udpSocket.handshakeComplete.timeout(Duration(seconds: 5));
  stderr.writeln('Dart: handshake complete!');
  
  // Write some data
  final data = Uint8List.fromList('hello from dart'.codeUnits);
  await stream.add(data);
  stderr.writeln('Dart: wrote ${data.length} bytes');

  // Read echo
  final echo = await stream.data.first.timeout(Duration(seconds: 5));
  stderr.writeln('Dart: read ${echo.length} bytes: ${String.fromCharCodes(echo)}');
  
  stream.close();
  mux.close();
  stderr.writeln('OK');
  exit(0);
}
