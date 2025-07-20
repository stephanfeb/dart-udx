import 'package:dart_udx/src/multiplexer.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:test/test.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

void main() {
  group('UDX Simultaneous Open', () {
    late UDX udx;
    late UDXMultiplexer multiplexer1;
    late UDXMultiplexer multiplexer2;
    late RawDatagramSocket rawSocket1;
    late RawDatagramSocket rawSocket2;
    UDXStream? stream1;
    UDXStream? stream2;

    setUp(() async {
      udx = UDX();
      rawSocket1 = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      rawSocket2 = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      multiplexer1 = UDXMultiplexer(rawSocket1);
      multiplexer2 = UDXMultiplexer(rawSocket2);
    });

    tearDown(() async {
      await stream1?.close();
      await stream2?.close();
      multiplexer1.close();
      multiplexer2.close();
    });

    test('handles simultaneous open and establishes a single stream', () async {
      final address1 = rawSocket1.address;
      final port1 = rawSocket1.port;
      final address2 = rawSocket2.address;
      final port2 = rawSocket2.port;
      
      const id1 = 100;
      const id2 = 200;

      final completer1 = Completer<Uint8List>();
      final completer2 = Completer<Uint8List>();

      // Both sides create sockets targeting each other
      final socket1 = multiplexer1.createSocket(udx, address2.address, port2);
      final socket2 = multiplexer2.createSocket(udx, address1.address, port1);

      // Both sides try to create an outgoing stream at the same time
      final f1 = UDXStream.createOutgoing(udx, socket1, id1, id2, address2.address, port2);
      final f2 = UDXStream.createOutgoing(udx, socket2, id2, id1, address1.address, port1);

      final results = await Future.wait([f1, f2]);
      stream1 = results[0];
      stream2 = results[1];

      // The multiplexer should have resolved this into a single connection on each side.
      // Now, we set up listeners and exchange data to confirm.
      stream1!.data.listen(completer2.complete); // stream1 receives data for completer2
      stream2!.data.listen(completer1.complete); // stream2 receives data for completer1

      final data1 = Uint8List.fromList([1, 2, 3]);
      final data2 = Uint8List.fromList([4, 5, 6]);

      // Send data in both directions
      await stream1!.add(data1);
      await stream2!.add(data2);

      // Wait for the data to be received
      final receivedOnSocket2 = await completer1.future.timeout(const Duration(seconds: 2));
      final receivedOnSocket1 = await completer2.future.timeout(const Duration(seconds: 2));

      // Verify that the data was correctly exchanged
      expect(receivedOnSocket2, equals(data1), reason: "Socket 2 should receive data from socket 1");
      expect(receivedOnSocket1, equals(data2), reason: "Socket 1 should receive data from socket 2");
      
      expect(stream1!.connected, isTrue);
      expect(stream2!.connected, isTrue);
    });
  });
}
