import 'package:dart_udx/src/multiplexer.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:test/test.dart';
import 'dart:typed_data';
import 'dart:async';
import 'dart:io';

// A custom multiplexer to simulate packet loss for testing
class FlakyUDXMultiplexer extends UDXMultiplexer {
  final Set<int> dropSequences;
  final Set<int> _alreadyAttempted = {};
  int packetsSent = 0;
  int packetsDropped = 0;

  FlakyUDXMultiplexer(
    RawDatagramSocket socket, {
    required this.dropSequences,
  }) : super(socket);

  @override
  void send(Uint8List data, InternetAddress address, int port) {
    try {
      final packet = UDXPacket.fromBytes(data);
      final isFirstAttempt = !_alreadyAttempted.contains(packet.sequence);
      _alreadyAttempted.add(packet.sequence);

      if (isFirstAttempt && dropSequences.contains(packet.sequence)) {
        print('FlakyUDXMultiplexer: Dropping packet with seq: ${packet.sequence}');
        packetsDropped++;
        return; // Drop the packet
      }
      
      packetsSent++;
      super.send(data, address, port);
    } catch (e) {
      // Not a UDX packet, or some other issue, send anyway
      super.send(data, address, port);
    }
  }
}

void main() {
  group('Loss Detection', () {
    late UDX udx;
    late FlakyUDXMultiplexer clientMultiplexer;
    late UDXMultiplexer serverMultiplexer;
    late RawDatagramSocket clientRawSocket;
    late RawDatagramSocket serverRawSocket;

    // Helper to set up a standard client/server connection for a test
    Future<({UDPSocket clientSocket, UDPSocket serverSocket, UDXStream clientStream, UDXStream serverStream})>
        setupTestEnvironment({required Set<int> dropSequences}) async {
      
      clientRawSocket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      serverRawSocket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);

      clientMultiplexer = FlakyUDXMultiplexer(clientRawSocket, dropSequences: dropSequences);
      serverMultiplexer = UDXMultiplexer(serverRawSocket);
      
      final serverAddress = serverRawSocket.address;
      final serverPort = serverRawSocket.port;

      final clientSocket = clientMultiplexer.createSocket(udx, serverAddress.address, serverPort);
      
      final serverConnectionCompleter = Completer<UDPSocket>();
      serverMultiplexer.connections.listen(serverConnectionCompleter.complete);

      final clientStream = await UDXStream.createOutgoing(udx, clientSocket, 1, 2, serverAddress.address, serverPort);
      
      final serverSocket = await serverConnectionCompleter.future.timeout(const Duration(seconds: 2));
      
      final serverStreamCompleter = Completer<UDXStream>();
      serverSocket.on('stream').listen((event) {
        if (!serverStreamCompleter.isCompleted) {
          serverStreamCompleter.complete(event.data as UDXStream);
        }
      });
      serverSocket.flushStreamBuffer();
      
      final serverStream = await serverStreamCompleter.future.timeout(const Duration(seconds: 2));

      return (
        clientSocket: clientSocket,
        serverSocket: serverSocket,
        clientStream: clientStream,
        serverStream: serverStream
      );
    }

    setUp(() {
      udx = UDX();
    });

    tearDown(() async {
      clientMultiplexer.close();
      serverMultiplexer.close();
    });

    test('retransmits lost packet and completes data transfer', () async {
      final setup = await setupTestEnvironment(dropSequences: {1});
      final clientStream = setup.clientStream;
      final serverStream = setup.serverStream;

      final dataToSend = Uint8List.fromList([1, 2, 3, 4, 5]);
      final serverReceivedCompleter = Completer<Uint8List>();

      serverStream.data.listen((receivedData) {
        if (!serverReceivedCompleter.isCompleted) {
          serverReceivedCompleter.complete(receivedData);
        }
      });

      await clientStream.add(dataToSend);

      final receivedData = await serverReceivedCompleter.future.timeout(
        Duration(milliseconds: clientStream.packetManager.retransmitTimeout + 500),
        onTimeout: () => throw TimeoutException('Server did not receive data in time.'),
      );

      expect(receivedData, equals(dataToSend));
      expect(clientMultiplexer.packetsDropped, equals(1));
      expect(clientMultiplexer.packetsSent, greaterThan(1)); // Original + retransmit
    });

    test('triggers fast retransmit on 3 duplicate ACKs', () async {
      final setup = await setupTestEnvironment(dropSequences: {1});
      final clientStream = setup.clientStream;
      
      final fastRetransmitCompleter = Completer<void>();
      clientStream.packetManager.congestionController.onFastRetransmit = (seq) {
        if (!fastRetransmitCompleter.isCompleted) {
          fastRetransmitCompleter.complete();
        }
      };

      // Send 4 packets. The first data packet (seq 1) will be dropped.
      // The next 3 (seq 2, 3, 4) will trigger duplicate ACKs, leading to fast retransmit.
      for (int i = 0; i < 4; i++) {
        await clientStream.add(Uint8List.fromList([i]));
      }

      await fastRetransmitCompleter.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw TimeoutException('Fast retransmit was not triggered.'),
      );
      
      expect(clientMultiplexer.packetsDropped, equals(1));
    });

    test('recovers from multiple lost packets', () async {
      final setup = await setupTestEnvironment(dropSequences: {2, 4});
      final clientStream = setup.clientStream;
      final serverStream = setup.serverStream;

      final allData = List.generate(5 * 1000, (i) => i % 256);
      final dataToSend = Uint8List.fromList(allData);
      final receivedData = <int>[];
      final serverReceivedCompleter = Completer<void>();

      serverStream.data.listen((chunk) {
        receivedData.addAll(chunk);
        if (receivedData.length >= dataToSend.length) {
          if (!serverReceivedCompleter.isCompleted) {
            serverReceivedCompleter.complete();
          }
        }
      });

      await clientStream.add(dataToSend);
      await serverReceivedCompleter.future.timeout(const Duration(seconds: 5));

      expect(receivedData, equals(dataToSend));
      expect(clientMultiplexer.packetsDropped, equals(2));
      expect(clientMultiplexer.packetsSent, greaterThan(dataToSend.length / 1400));
    });

    test('retransmits single lost packet after subsequent ACK', () async {
      // This test specifically targets a bug where an ACK for a later packet
      // incorrectly cancels the retransmission timer for an earlier, lost packet.
      final setup = await setupTestEnvironment(dropSequences: {0});
      final clientStream = setup.clientStream;
      final serverStream = setup.serverStream;

      final receivedData = <int>[];
      final serverReceivedCompleter = Completer<void>();

      serverStream.data.listen((chunk) {
        receivedData.addAll(chunk);
        if (receivedData.length >= 2) {
          if (!serverReceivedCompleter.isCompleted) {
            serverReceivedCompleter.complete();
          }
        }
      });

      // Send two packets. Packet 0 will be dropped. Packet 1 will be sent.
      // The server will receive packet 1 and send an ACK for it, creating a SACK.
      // This SACK should NOT cancel the retransmit timer for packet 0.
      await clientStream.add(Uint8List.fromList([1])); // Packet 0
      await clientStream.add(Uint8List.fromList([2])); // Packet 1

      await serverReceivedCompleter.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw TimeoutException('Server did not receive all data in time.'),
      );

      expect(receivedData, equals([1, 2]));
      expect(clientMultiplexer.packetsDropped, equals(1));
    });
  });
}
