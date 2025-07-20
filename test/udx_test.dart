import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/multiplexer.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:test/test.dart';
import 'dart:typed_data';
import 'dart:async';
import 'dart:io';

void main() {
  group('UDX Frames', () {
    test('StreamFrame serializes and deserializes correctly', () {
      final frame = StreamFrame(data: Uint8List.fromList([1, 2, 3]), isFin: true);
      final bytes = frame.toBytes();
      final view = ByteData.view(bytes.buffer);
      final newFrame = StreamFrame.fromBytes(view, 0);

      expect(newFrame.data, equals(frame.data));
      expect(newFrame.isFin, isTrue);
    });

    test('AckFrame serializes and deserializes correctly', () {
      final frame = AckFrame(
        largestAcked: 30,
        ackDelay: 0, // Assuming 0 for test simplicity
        firstAckRangeLength: 1, // For packet 30
        ackRanges: [
          AckRange(gap: 9, ackRangeLength: 1), // For packet 20 (gap from 30 to 20 is 30-20-1=9)
          AckRange(gap: 9, ackRangeLength: 1), // For packet 10 (gap from 20 to 10 is 20-10-1=9)
        ],
      );
      final bytes = frame.toBytes();
      final view = ByteData.view(bytes.buffer);
      final newFrame = AckFrame.fromBytes(view, 0);

      expect(newFrame.largestAcked, equals(30));
      expect(newFrame.ackDelay, equals(0));
      expect(newFrame.firstAckRangeLength, equals(1));
      expect(newFrame.ackRanges.length, equals(2));
      expect(newFrame.ackRanges[0].gap, equals(9));
      expect(newFrame.ackRanges[0].ackRangeLength, equals(1));
      expect(newFrame.ackRanges[1].gap, equals(9));
      expect(newFrame.ackRanges[1].ackRangeLength, equals(1));
    });
  });

  group('UDXPacket with Frames', () {
    test('converts to and from bytes correctly with multiple frames', () {
      final destCid = ConnectionId.random();
      final srcCid = ConnectionId.random();
      final originalPacket = UDXPacket(
        destinationCid: destCid,
        sourceCid: srcCid,
        destinationStreamId: 12345,
        sourceStreamId: 67890,
        sequence: 100,
        frames: [
          StreamFrame(data: Uint8List.fromList([1, 2, 3, 4])),
          AckFrame(largestAcked: 99, ackDelay: 0, firstAckRangeLength: 2, ackRanges: [])
        ],
      );

      final bytes = originalPacket.toBytes();
      final reconstructedPacket = UDXPacket.fromBytes(bytes);

      expect(reconstructedPacket.destinationStreamId, originalPacket.destinationStreamId);
      expect(reconstructedPacket.sourceStreamId, originalPacket.sourceStreamId);
      expect(reconstructedPacket.sequence, originalPacket.sequence);
      expect(reconstructedPacket.frames.length, 2);

      final streamFrame = reconstructedPacket.frames.firstWhere((f) => f is StreamFrame) as StreamFrame;
      final ackFrame = reconstructedPacket.frames.firstWhere((f) => f is AckFrame) as AckFrame;

      expect(streamFrame.data, equals(Uint8List.fromList([1, 2, 3, 4])));
      expect(ackFrame.largestAcked, equals(99));
      expect(ackFrame.ackDelay, equals(0));
      expect(ackFrame.firstAckRangeLength, equals(2));
      expect(ackFrame.ackRanges, isEmpty);
    });

    test('fromBytes throws ArgumentError for short byte array', () {
      final shortBytes = Uint8List(11); // Header is 12 bytes
      expect(() => UDXPacket.fromBytes(shortBytes), throwsArgumentError);
    });

    test('handles packet with only a PingFrame', () {
      final destCid = ConnectionId.random();
      final srcCid = ConnectionId.random();
      final originalPacket = UDXPacket(
        destinationCid: destCid,
        sourceCid: srcCid,
        destinationStreamId: 1,
        sourceStreamId: 2,
        sequence: 1,
        frames: [PingFrame()],
      );
      final bytes = originalPacket.toBytes();
      expect(bytes.length, 28 + 1); // Header + PingFrame

      final reconstructedPacket = UDXPacket.fromBytes(bytes);
      expect(reconstructedPacket.frames.length, 1);
      expect(reconstructedPacket.frames.first, isA<PingFrame>());
    });
  });

  group('UDX Core (Socket and Stream)', () {
    late UDX udx;
    late UDXMultiplexer multiplexer1;
    late UDXMultiplexer multiplexer2;
    late RawDatagramSocket rawSocket1;
    late RawDatagramSocket rawSocket2;

    setUp(() async {
      udx = UDX();
      rawSocket1 = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      rawSocket2 = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      multiplexer1 = UDXMultiplexer(rawSocket1);
      multiplexer2 = UDXMultiplexer(rawSocket2);
    });

    tearDown(() {
      multiplexer1.close();
      multiplexer2.close();
    });

    test('sends and receives data with new stream factories and demux', () async {
      final serverAddress = rawSocket2.address;
      final serverPort = rawSocket2.port;
      final dataReceivedCompleter = Completer<void>();
      final dataToSend = Uint8List.fromList([1, 2, 3, 4, 5]);

      // Set up the server listener.
      final subscription = multiplexer2.connections.listen((serverSocket) {
        // The new buffering logic in UDPSocket guarantees the 'stream' event will be delivered.
        final streamListener = (UDXEvent event) {
          final serverStream = event.data as UDXStream;
          final received = <int>[];
          serverStream.data.listen((chunk) {
            received.addAll(chunk);
            if (received.length >= dataToSend.length) {
              expect(received, equals(dataToSend));
              if (!dataReceivedCompleter.isCompleted) {
                dataReceivedCompleter.complete();
              }
            }
          });
        };
        
        serverSocket.on('stream').listen(streamListener);
        serverSocket.flushBufferedStreams('stream', streamListener, serverSocket.getStreamBuffer());
      });

      // Create the client socket and the outgoing stream.
      final clientSocket = multiplexer1.createSocket(udx, serverAddress.address, serverPort);
      final stream1 = await UDXStream.createOutgoing(
        udx,
        clientSocket,
        200,
        201,
        serverAddress.address,
        serverPort,
      );

      // With the socket now buffering events, we can send immediately.
      await stream1.add(dataToSend);

      // Wait for the data to be fully received and verified.
      await dataReceivedCompleter.future.timeout(const Duration(seconds: 2));

      // Clean up resources.
      await stream1.close();
      await subscription.cancel();
    });

    test('handles stream events (connect, send, ack) with new factories', () async {
      final serverAddress = rawSocket2.address;
      final serverPort = rawSocket2.port;
      final clientSocket = multiplexer1.createSocket(udx, serverAddress.address, serverPort);

      final eventsS1 = <String>[];
      final ackCompleter = Completer<void>();

      final stream1 = await UDXStream.createOutgoing(
        udx, clientSocket, 400, 401,
        serverAddress.address, serverPort
      );
      
      stream1.on('send').listen((_) => eventsS1.add('send'));
      stream1.on('ack').listen((_) {
        eventsS1.add('ack');
        if (!ackCompleter.isCompleted) ackCompleter.complete();
      });
      
      multiplexer2.connections.listen((serverSocket) {
        serverSocket.on('stream').listen((event) {
          final stream2 = event.data as UDXStream;
          stream2.data.listen((_) {}); // Consume data to trigger ACKs
        });
      });

      final data = Uint8List.fromList([1, 2, 3]);
      await stream1.add(data);
      
      await ackCompleter.future.timeout(const Duration(seconds: 1));
      
      expect(stream1.connected, isTrue);
      expect(eventsS1, contains('send'));
      expect(eventsS1, contains('ack'));
      await stream1.close();
    });

    test('listener multiplexer should emit "connection" for a new connection attempt', () async {
      final serverAddress = rawSocket2.address;
      final serverPort = rawSocket2.port;
      final clientSocket = multiplexer1.createSocket(udx, serverAddress.address, serverPort);

      final eventCompleter = Completer<UDPSocket>();
      final subscription = multiplexer2.connections.listen((socket) {
        if (!eventCompleter.isCompleted) eventCompleter.complete(socket);
      });

      final dialerStream = await UDXStream.createOutgoing(
        udx,
        clientSocket,
        301,
        302,
        serverAddress.address,
        serverPort,
      );

      UDPSocket? newSocket;
      try {
        newSocket = await eventCompleter.future.timeout(const Duration(seconds: 2));
      } finally {
        await subscription.cancel();
        await dialerStream.close();
        await newSocket?.close();
      }
      
      expect(newSocket, isNotNull);
      expect(newSocket.remoteAddress, equals(rawSocket1.address));
      expect(newSocket.remotePort, equals(rawSocket1.port));
    });
  });
}
