import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/multiplexer.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:test/test.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

void main() {
  group('UDX Multiplexer', () {
    late UDX udx;
    late UDXMultiplexer clientMultiplexer;
    late UDXMultiplexer serverMultiplexer;
    late RawDatagramSocket clientRawSocket;
    late RawDatagramSocket serverRawSocket;

    setUp(() async {
      udx = UDX();
      clientRawSocket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      serverRawSocket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      clientMultiplexer = UDXMultiplexer(clientRawSocket);
      serverMultiplexer = UDXMultiplexer(serverRawSocket);
    });

    tearDown(() {
      clientMultiplexer.close();
      serverMultiplexer.close();
    });

    test('routes packets to the correct UDXSocket based on CID', () async {
      final serverAddress = serverRawSocket.address;
      final serverPort = serverRawSocket.port;

      // Client creates a socket to connect to the server
      final clientSocket = clientMultiplexer.createSocket(
        udx,
        serverAddress.address,
        serverPort,
      );

      final completer = Completer<UDPSocket>();
      serverMultiplexer.connections.listen(completer.complete);

      // Client sends initial packet to establish connection
      final stream = await UDXStream.createOutgoing(
        udx,
        clientSocket,
        1,
        2,
        serverAddress.address,
        serverPort,
      );

      final serverSocket = await completer.future.timeout(const Duration(seconds: 2));
      expect(serverSocket, isA<UDPSocket>());
      expect(serverSocket.remoteAddress, equals(clientRawSocket.address));
      expect(serverSocket.remotePort, equals(clientRawSocket.port));

      final dataCompleter = Completer<Uint8List>();
      serverSocket.on('stream').listen((event) {
        final serverStream = event.data as UDXStream;
        serverStream.data.listen(dataCompleter.complete);
      });

      // Flush any streams that were created before the listener was attached.
      serverSocket.flushStreamBuffer();

      final testData = Uint8List.fromList([1, 2, 3, 4, 5]);
      await stream.add(testData);

      final receivedData = await dataCompleter.future.timeout(const Duration(seconds: 2));
      expect(receivedData, equals(testData));

      await stream.close();
    });
  });
}
