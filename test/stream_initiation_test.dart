import 'dart:async';
import 'dart:io';

import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:dart_udx/udx.dart';
import 'package:test/test.dart';
import 'package:dart_udx/src/multiplexer.dart';

void main() {
  group('UDXStream Initiation', () {
    late UDX udx;
    late RawDatagramSocket rawSocketA;
    late RawDatagramSocket rawSocketB;
    late UDXMultiplexer multiplexerA;
    late UDXMultiplexer multiplexerB;
    late UDPSocket socketA;
    late UDPSocket socketB;

    setUp(() async {
      udx = UDX();
      rawSocketA = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      rawSocketB = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      multiplexerA = UDXMultiplexer(rawSocketA);
      multiplexerB = UDXMultiplexer(rawSocketB);
      socketA = multiplexerA.createSocket(udx, rawSocketB.address.address, rawSocketB.port);
      socketB = multiplexerB.createSocket(udx, rawSocketA.address.address, rawSocketA.port);
    });

    tearDown(() {
      multiplexerA.close();
      multiplexerB.close();
    });

    test('peer B should create a new stream upon receiving a SYN packet', () async {
      final completer = Completer<UDXStream>();

      // Listen on socketB for a new stream event
      final subscription = socketB.on('stream').listen((event) {
        completer.complete(event.data as UDXStream);
      });
      addTearDown(subscription.cancel);
      socketB.flushStreamBuffer();

      // 1. Stream A creates an outgoing stream targeting socketB
      final streamA = await UDXStream.createOutgoing(
        udx,
        socketA,
        1, // localId
        1, // remoteId (destination)
        rawSocketB.address.address,
        rawSocketB.port,
      );
      addTearDown(streamA.close);

      // The createOutgoing method sends an initial packet with the SYN flag.
      // We wait for socketB to process it and emit the stream.
      final newStream = await completer.future.timeout(const Duration(seconds: 2));
      addTearDown(newStream.close);

      expect(newStream, isNotNull);
      expect(newStream.id, 1); // Should match the destination ID from stream A
      expect(newStream.remoteId, 1); // Should match the source ID from stream A
    });
  });
}
