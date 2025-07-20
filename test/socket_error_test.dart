import 'package:test/test.dart';
import 'dart:io';

void main() {
  group('UDXMultiplexer Error Handling', () {
    test('binding to an address already in use throws a SocketException', () async {
      RawDatagramSocket? rawSocket1;
      try {
        rawSocket1 = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = rawSocket1.port;

        // Attempt to bind the second socket to the same port
        await expectLater(
          RawDatagramSocket.bind(InternetAddress.loopbackIPv4, port),
          throwsA(isA<SocketException>()),
        );
      } finally {
        rawSocket1?.close();
      }
    });
  });
}
