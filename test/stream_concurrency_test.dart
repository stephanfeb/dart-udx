import 'dart:async';
import 'dart:io';

import 'package:dart_udx/src/socket.dart';
import 'package:test/test.dart';
import 'package:dart_udx/udx.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:dart_udx/src/multiplexer.dart';
import 'package:dart_udx/src/events.dart';

void main() {
  group('Stream Concurrency Control', () {
    late UDX udx;
    late RawDatagramSocket rawSocket1;
    late RawDatagramSocket rawSocket2;
    late UDXMultiplexer multiplexer1;
    late UDXMultiplexer multiplexer2;
    late InternetAddress address1;
    late InternetAddress address2;
    late int port1;
    late int port2;

    setUp(() async {
      udx = UDX();
      rawSocket1 = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      rawSocket2 = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      multiplexer1 = UDXMultiplexer(rawSocket1);
      multiplexer2 = UDXMultiplexer(rawSocket2);
      address1 = rawSocket1.address;
      port1 = rawSocket1.port;
      address2 = rawSocket2.address;
      port2 = rawSocket2.port;
    });

    tearDown(() async {
      multiplexer1.close();
      multiplexer2.close();
    });

    test('client respects server stream limit and throws error when exceeded', () async {
      const serverMaxStreams = 2;

      final socket1 = multiplexer1.createSocket(udx, address2.address, port2);
      final socket2 = multiplexer2.createSocket(udx, address1.address, port1);
      
      // Set up the server to advertise its stream limit
      socket2.setLocalMaxStreamsForTest(serverMaxStreams);
      
      // Set up the client to receive the stream limit update
      final streamLimitCompleter = Completer<void>();
      socket1.on('remoteMaxStreamsUpdate').listen((event) {
        streamLimitCompleter.complete();
      });
      
      // Establish connection by creating an initial stream
      // This will trigger the handshake and connection establishment
      final initialStream = await UDXStream.createOutgoing(
        udx,
        socket1,
        99,
        199,
        address2.address,
        port2,
      );
      
      // Wait for connection to be established
      await socket1.handshakeComplete;
      await socket2.handshakeComplete;
      
      // Now have the server send its stream limit to the client
      await socket2.sendMaxStreamsFrame();
      
      // Wait for the client to receive and process the stream limit
      await streamLimitCompleter.future.timeout(const Duration(seconds: 2));
      
      // Close the initial stream
      await initialStream.close();

      final streams = <UDXStream>[];
      
      // Create streams up to the limit
      for (int i = 0; i < serverMaxStreams; i++) {
        final stream = await UDXStream.createOutgoing(
          udx,
          socket1,
          100 + i,
          200 + i,
          address2.address,
          port2,
        );
        streams.add(stream);
      }

      expect(streams.length, serverMaxStreams);

      // Attempting to create one more stream should fail
      expect(
        () async => await UDXStream.createOutgoing(
          udx,
          socket1,
          100 + serverMaxStreams,
          200 + serverMaxStreams,
          address2.address,
          port2,
        ),
        throwsA(isA<StreamLimitExceededError>()),
      );

      // Close one stream
      await streams.first.close();

      // Now, creating a new stream should succeed
      final newStream = await UDXStream.createOutgoing(
        udx,
        socket1,
        500,
        600,
        address2.address,
        port2,
      );
      expect(newStream, isA<UDXStream>());
      await newStream.close();

      // Clean up remaining streams
      for (final s in streams) {
        if (s.connected) {
          await s.close();
        }
      }
      await socket1.close();
      await socket2.close();
    });

    test('server rejects incoming stream when its limit is exceeded', () async {
      final socket1 = multiplexer1.createSocket(udx, address2.address, port2);
      final socket2 = multiplexer2.createSocket(udx, address1.address, port1);

      // Set server's local max streams to a low value
      socket2.setLocalMaxStreamsForTest(1);

      final serverStreamCompleter = Completer<UDXStream>();
      socket2.on('stream').listen((event) {
        if (!serverStreamCompleter.isCompleted) {
          serverStreamCompleter.complete(event.data as UDXStream);
        }
      });
      socket2.flushStreamBuffer();

      // Client creates the first stream, which should be accepted
      final clientStream1 = await UDXStream.createOutgoing(
        udx,
        socket1,
        10,
        20,
        address2.address,
        port2,
      );
      
      final serverStream1 = await serverStreamCompleter.future.timeout(const Duration(seconds: 2));
      expect(serverStream1, isA<UDXStream>());

      // Client attempts to create a second stream
      // This should be rejected by the server with a ResetStreamFrame
      final resetCompleter = Completer<void>();
      
      final clientStream2 = await UDXStream.createOutgoing(
        udx,
        socket1,
        11,
        21,
        address2.address,
        port2,
      );

      clientStream2.on('error').listen((event) {
        if (event.data is StreamResetError) {
          resetCompleter.complete();
        }
      });


      // Give the server time to process and reject the stream
      await resetCompleter.future.timeout(const Duration(seconds: 2));

      // Verify that no new stream was created on the server
      expect(socket2.getRegisteredStreamsCount(), 1);


      await clientStream1.close();
      await clientStream2.close();
      await socket1.close();
      await socket2.close();
    });
  });
}
