import 'dart:typed_data';
import 'dart:io';

import 'package:dart_udx/src/packet.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:dart_udx/udx.dart';
import 'package:test/test.dart';
import 'dart:async';
import 'package:dart_udx/src/multiplexer.dart';

void main() {
  group('ResetStreamFrame', () {
    test('should serialize and deserialize correctly', () {
      // 1. Setup
      const originalErrorCode = 123;
      final originalFrame = ResetStreamFrame(errorCode: originalErrorCode);

      // 2. Serialize
      final bytes = originalFrame.toBytes();
      final view = ByteData.view(bytes.buffer);

      // 3. Deserialize
      // The Frame.fromBytes factory expects to read the type from the first byte.
      final deserializedFrame = Frame.fromBytes(view, 0) as ResetStreamFrame;

      // 4. Verify
      expect(deserializedFrame.type, FrameType.resetStream);
      expect(deserializedFrame.errorCode, originalErrorCode);
      expect(deserializedFrame.length, 5); // 1 byte for type, 4 for error code
    });
  });

  group('UDXStream Reset', () {
    late UDX udx;
    late RawDatagramSocket rawSocketA;
    late RawDatagramSocket rawSocketB;
    late UDXMultiplexer multiplexerA;
    late UDXMultiplexer multiplexerB;
    late UDPSocket socketA;
    late UDPSocket socketB;
    UDXStream? streamA;
    UDXStream? streamB;

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
      streamA?.close();
      streamB?.close();
      multiplexerA.close();
      multiplexerB.close();
    });

    test('sending reset closes both streams and emits error', () async {
      const testErrorCode = 404;
      final completerB = Completer<UDXStream>();
      final closeCompleterA = Completer<void>();
      final closeCompleterB = Completer<void>();
      final errorCompleterB = Completer<dynamic>();

      // Setup listener for incoming stream on socket B
      socketB.on('stream').listen((event) {
        streamB = event.data as UDXStream;
        streamB!.on('close').listen((_) => closeCompleterB.complete());
        streamB!.on('error').listen((err) {
          if (!errorCompleterB.isCompleted) {
            errorCompleterB.complete(err.data);
          }
        });
        completerB.complete(streamB);
      });
      socketB.flushStreamBuffer();

      // Create outgoing stream from socket A
      streamA = await UDXStream.createOutgoing(
        udx,
        socketA,
        1, // localId
        2, // remoteId
        rawSocketB.address.address,
        rawSocketB.port,
      );
      streamA!.on('close').listen((_) => closeCompleterA.complete());

      // Wait for stream B to be established
      await completerB.future.timeout(const Duration(seconds: 2));
      expect(streamB, isNotNull);

      // 1. Stream A sends a reset to Stream B
      await streamA!.reset(testErrorCode);

      // 4. Verify the outcomes
      await Future.wait([
        closeCompleterA.future,
        closeCompleterB.future,
        errorCompleterB.future,
      ]).timeout(const Duration(seconds: 2));

      // Verify Stream A closed
      expect(streamA!.connected, isFalse);

      // Verify Stream B received the reset, emitted an error, and closed
      expect(streamB!.connected, isFalse);
      final streamBError = await errorCompleterB.future;
      expect(streamBError, isA<StreamResetError>());
      expect(
        (streamBError as StreamResetError).errorCode,
        testErrorCode,
      );
    });
  });
}
