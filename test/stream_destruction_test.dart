import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:test/test.dart';
import 'dart:async';
import 'dart:io';
import 'package:dart_udx/src/multiplexer.dart';

void main() {
  group('UDXStream Destruction', () {
    late UDX udx;
    late RawDatagramSocket rawSocket1;
    late RawDatagramSocket rawSocket2;
    late UDXMultiplexer multiplexer1;
    late UDXMultiplexer multiplexer2;
    late UDPSocket socket1;
    late UDPSocket socket2;
    late UDXStream stream;

    setUp(() async {
      udx = UDX();
      rawSocket1 = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      rawSocket2 = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      multiplexer1 = UDXMultiplexer(rawSocket1);
      multiplexer2 = UDXMultiplexer(rawSocket2);
      socket1 = multiplexer1.createSocket(udx, rawSocket2.address.address, rawSocket2.port);
      socket2 = multiplexer2.createSocket(udx, rawSocket1.address.address, rawSocket1.port);

      final completer = Completer<UDXStream>();
      socket2.on('stream').listen((event) {
        completer.complete(event.data as UDXStream);
      });
      socket2.flushStreamBuffer();

      stream = await UDXStream.createOutgoing(
        udx,
        socket1,
        1,
        2,
        rawSocket2.address.address,
        rawSocket2.port,
      );
      // wait for stream to be established
      await completer.future;
    });

    tearDown(() {
      multiplexer1.close();
      multiplexer2.close();
    });

    test('close cleans up resources and emits "close" event', () async {
      final closeCompleter = Completer<void>();
      stream.on('close').listen((_) {
        if (!closeCompleter.isCompleted) {
          closeCompleter.complete();
        }
      });

      stream.close();

      await expectLater(closeCompleter.future, completes);
      expect(stream.connected, isFalse);
    });
  });
}
