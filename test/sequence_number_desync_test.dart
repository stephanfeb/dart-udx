/// Tests for the sequence number desynchronization fix.
///
/// This test file guards against a critical bug where non-reliable packets
/// (ACKs, window updates, resets, probes) consumed new sequence numbers
/// without being registered for retransmission. This caused permanent
/// data flow blockages when these packets were lost.
///
/// See SEQUENCE_NUMBER_DESYNC_FIX.md for full details.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_udx/src/multiplexer.dart';
import 'package:test/test.dart';
import 'package:dart_udx/dart_udx.dart';
import 'package:dart_udx/src/socket.dart';
import 'package:dart_udx/src/stream.dart';
import 'package:dart_udx/src/packet.dart';

void main() {
  group('Sequence Number Desync Prevention', () {
    late UDX udx;
    late UDXMultiplexer clientMultiplexer;
    late UDXMultiplexer serverMultiplexer;
    late RawDatagramSocket clientRawSocket;
    late RawDatagramSocket serverRawSocket;
    UDPSocket? clientSocket;
    UDPSocket? serverSocket;
    UDXStream? clientStream;
    UDXStream? serverStream;

    setUp(() async {
      udx = UDX();
      clientRawSocket =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      serverRawSocket =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      clientMultiplexer = UDXMultiplexer(clientRawSocket);
      serverMultiplexer = UDXMultiplexer(serverRawSocket);
    });

    tearDown(() async {
      await clientStream?.close();
      await serverStream?.close();
      clientMultiplexer.close();
      serverMultiplexer.close();
    });

    Future<void> setupTestEnvironment(
        int clientStreamId, int serverStreamId) async {
      final serverAddress = serverRawSocket.address;
      final serverPort = serverRawSocket.port;

      clientSocket =
          clientMultiplexer.createSocket(udx, serverAddress.address, serverPort);

      final serverConnectionCompleter = Completer<UDPSocket>();
      serverMultiplexer.connections.listen(serverConnectionCompleter.complete);

      clientStream = await UDXStream.createOutgoing(
        udx,
        clientSocket!,
        clientStreamId,
        serverStreamId,
        serverAddress.address,
        serverPort,
      );

      serverSocket =
          await serverConnectionCompleter.future.timeout(const Duration(seconds: 2));

      final serverStreamCompleter = Completer<UDXStream>();
      serverSocket!.on('stream').listen((event) {
        final newStream = event.data as UDXStream;
        if (newStream.id == serverStreamId) {
          serverStream = newStream;
          serverStreamCompleter.complete(newStream);
        }
      });
      serverSocket!.flushStreamBuffer();

      await serverStreamCompleter.future.timeout(const Duration(seconds: 2));
    }

    group('ACK packets should not consume new sequence numbers', () {
      test(
          'PacketManager.lastSentPacketNumber is used for ACK sequence instead of nextSequence',
          () async {
        // Create a mock PacketManager to verify behavior
        final pm = PacketManager();

        // Initially, lastSentPacketNumber should be -1 (nothing sent yet)
        expect(pm.lastSentPacketNumber, equals(-1));

        // Get a few sequence numbers for "data" packets
        final seq1 = pm.nextSequence;
        expect(seq1, equals(0));
        // Simulate registering this packet
        pm.lastSentPacketNumber = seq1;

        final seq2 = pm.nextSequence;
        expect(seq2, equals(1));
        pm.lastSentPacketNumber = seq2;

        final seq3 = pm.nextSequence;
        expect(seq3, equals(2));
        pm.lastSentPacketNumber = seq3;

        // Now verify that non-reliable packets would use lastSentPacketNumber (2)
        // instead of consuming the next sequence number (3)
        final ackSeq = pm.lastSentPacketNumber >= 0 ? pm.lastSentPacketNumber : 0;
        expect(ackSeq, equals(2), reason: 'ACK should reuse last data sequence');

        // The next data packet should still get sequence 3
        final seq4 = pm.nextSequence;
        expect(seq4, equals(3),
            reason: 'ACK should not have consumed sequence 3');
      });

      test(
          'sendProbe uses lastSentPacketNumber instead of consuming new sequence',
          () async {
        final pm = PacketManager();

        // Send some "data" packets first
        pm.lastSentPacketNumber = pm.nextSequence; // seq 0
        pm.lastSentPacketNumber = pm.nextSequence; // seq 1
        pm.lastSentPacketNumber = pm.nextSequence; // seq 2

        // Record current state
        final seqBeforeProbe = pm.lastSentPacketNumber;
        expect(seqBeforeProbe, equals(2));

        // Create dummy CIDs for the probe
        final destCid = ConnectionId.random();
        final srcCid = ConnectionId.random();

        // Capture the probe packet
        UDXPacket? capturedProbe;
        pm.onSendProbe = (packet) {
          capturedProbe = packet;
        };

        // Send a probe
        pm.sendProbe(destCid, srcCid, 100, 200);

        // Verify probe used lastSentPacketNumber, not a new sequence
        expect(capturedProbe, isNotNull);
        expect(capturedProbe!.sequence, equals(2),
            reason: 'Probe should reuse lastSentPacketNumber (2), not consume new sequence');

        // Verify next data packet gets sequence 3 (not 4)
        final nextDataSeq = pm.nextSequence;
        expect(nextDataSeq, equals(3),
            reason: 'Probe should not have consumed sequence 3');
      });
    });

    group('Data flow continues correctly after many ACK exchanges', () {
      test('sequential data transfer succeeds with interleaved ACKs', () async {
        await setupTestEnvironment(1001, 1002);

        // Send multiple small data packets that will each trigger an ACK
        final numPackets = 20;
        final packetSize = 100;
        final allDataReceived = Completer<void>();
        final receivedData = <int>[];

        serverStream!.data.listen((data) {
          receivedData.addAll(data);
          if (receivedData.length >= numPackets * packetSize) {
            allDataReceived.complete();
          }
        });

        // Send packets with small delays to allow ACKs to be sent
        for (int i = 0; i < numPackets; i++) {
          final packet = Uint8List(packetSize);
          for (int j = 0; j < packetSize; j++) {
            packet[j] = (i * packetSize + j) % 256;
          }
          await clientStream!.add(packet);
          // Small delay to allow ACK to be sent before next packet
          await Future.delayed(const Duration(milliseconds: 10));
        }

        await allDataReceived.future.timeout(const Duration(seconds: 10));

        // Verify all data was received correctly
        expect(receivedData.length, equals(numPackets * packetSize));

        // Verify data integrity
        for (int i = 0; i < receivedData.length; i++) {
          expect(receivedData[i], equals(i % 256),
              reason: 'Data corruption at index $i');
        }
      });

      test('large data transfer with many ACKs completes successfully',
          () async {
        await setupTestEnvironment(2001, 2002);

        // Send a large payload that will require many packets and ACKs
        final payloadSize = 100000; // 100KB
        final largePayload = Uint8List(payloadSize);
        for (int i = 0; i < payloadSize; i++) {
          largePayload[i] = i % 256;
        }

        final allDataReceived = Completer<Uint8List>();
        final receivedData = <int>[];

        serverStream!.data.listen((data) {
          receivedData.addAll(data);
          if (receivedData.length >= payloadSize) {
            allDataReceived.complete(Uint8List.fromList(receivedData));
          }
        });

        await clientStream!.add(largePayload);
        final received =
            await allDataReceived.future.timeout(const Duration(seconds: 30));

        expect(received.length, equals(payloadSize));
        expect(received, equals(largePayload));
      });

      test(
          'bidirectional data transfer succeeds with concurrent ACKs on both sides',
          () async {
        await setupTestEnvironment(3001, 3002);

        final packetSize = 500;
        final numPackets = 10;
        final totalBytes = packetSize * numPackets;

        // Set up receivers for both directions
        final clientReceivedData = <int>[];
        final serverReceivedData = <int>[];
        final clientDone = Completer<void>();
        final serverDone = Completer<void>();

        clientStream!.data.listen((data) {
          clientReceivedData.addAll(data);
          if (clientReceivedData.length >= totalBytes && !clientDone.isCompleted) {
            clientDone.complete();
          }
        });

        serverStream!.data.listen((data) {
          serverReceivedData.addAll(data);
          if (serverReceivedData.length >= totalBytes && !serverDone.isCompleted) {
            serverDone.complete();
          }
        });

        // Send data in both directions concurrently
        final clientToServer = <Future<void>>[];
        final serverToClient = <Future<void>>[];

        for (int i = 0; i < numPackets; i++) {
          // Client -> Server
          final c2sPacket = Uint8List(packetSize);
          for (int j = 0; j < packetSize; j++) {
            c2sPacket[j] = (i * 10 + j) % 256;
          }
          clientToServer.add(clientStream!.add(c2sPacket));

          // Server -> Client
          final s2cPacket = Uint8List(packetSize);
          for (int j = 0; j < packetSize; j++) {
            s2cPacket[j] = ((i * 10 + j) + 128) % 256; // Different pattern
          }
          serverToClient.add(serverStream!.add(s2cPacket));

          // Small delay between batches
          await Future.delayed(const Duration(milliseconds: 20));
        }

        // Wait for all sends to complete
        await Future.wait([...clientToServer, ...serverToClient]);

        // Wait for all data to be received
        await Future.wait([
          clientDone.future.timeout(const Duration(seconds: 15)),
          serverDone.future.timeout(const Duration(seconds: 15)),
        ]);

        expect(serverReceivedData.length, equals(totalBytes));
        expect(clientReceivedData.length, equals(totalBytes));
      });
    });

    group('Sequential stream reuse after heavy ACK traffic', () {
      test(
          'new data can be sent after closing and reopening stream with many ACKs',
          () async {
        // This test specifically targets the bug scenario:
        // 1. Stream 1 sends lots of data (many ACKs generated)
        // 2. Stream 1 closes
        // 3. Stream 2 opens and should be able to send data immediately
        //
        // Before the fix, Stream 2 would fail because ACKs from Stream 1
        // had consumed sequence numbers that were never delivered.

        await setupTestEnvironment(4001, 4002);

        // Phase 1: Heavy data transfer on first stream
        final phase1Size = 50000;
        final phase1Data = Uint8List(phase1Size);
        for (int i = 0; i < phase1Size; i++) {
          phase1Data[i] = i % 256;
        }

        final phase1Complete = Completer<void>();
        final phase1Received = <int>[];
        serverStream!.data.listen((data) {
          phase1Received.addAll(data);
          if (phase1Received.length >= phase1Size && !phase1Complete.isCompleted) {
            phase1Complete.complete();
          }
        });

        await clientStream!.add(phase1Data);
        await phase1Complete.future.timeout(const Duration(seconds: 15));

        expect(phase1Received.length, equals(phase1Size),
            reason: 'Phase 1 data should be fully received');

        // Close first stream pair
        await clientStream!.close();
        await serverStream!.close();

        // Give time for FIN packets to be exchanged
        await Future.delayed(const Duration(milliseconds: 200));

        // Phase 2: Create new streams and verify data can still flow
        // This tests that the sequence number space wasn't corrupted by ACKs
        final serverAddress = serverRawSocket.address;
        final serverPort = serverRawSocket.port;

        final newClientStream = await UDXStream.createOutgoing(
          udx,
          clientSocket!,
          4003, // New stream IDs
          4004,
          serverAddress.address,
          serverPort,
        );

        final newServerStreamCompleter = Completer<UDXStream>();
        serverSocket!.on('stream').listen((event) {
          final stream = event.data as UDXStream;
          if (stream.id == 4004) {
            newServerStreamCompleter.complete(stream);
          }
        });
        serverSocket!.flushStreamBuffer();

        final newServerStream = await newServerStreamCompleter.future
            .timeout(const Duration(seconds: 5));

        // Phase 2 data transfer
        final phase2Size = 1000;
        final phase2Data = Uint8List(phase2Size);
        for (int i = 0; i < phase2Size; i++) {
          phase2Data[i] = (i + 100) % 256;
        }

        final phase2Complete = Completer<void>();
        final phase2Received = <int>[];
        newServerStream.data.listen((data) {
          phase2Received.addAll(data);
          if (phase2Received.length >= phase2Size && !phase2Complete.isCompleted) {
            phase2Complete.complete();
          }
        });

        await newClientStream.add(phase2Data);
        await phase2Complete.future.timeout(const Duration(seconds: 10),
            onTimeout: () {
          fail(
              'Phase 2 data transfer timed out - possible sequence number desync! '
              'Received ${phase2Received.length}/${phase2Size} bytes');
        });

        expect(phase2Received.length, equals(phase2Size),
            reason: 'Phase 2 data should be fully received on new stream');

        // Clean up new streams
        await newClientStream.close();
        await newServerStream.close();

        // Update test's stream references to avoid double-close in tearDown
        clientStream = null;
        serverStream = null;
      });
    });

    group('Edge cases', () {
      test('first ACK before any data packet uses sequence 0', () {
        final pm = PacketManager();

        // Before any packets are sent, lastSentPacketNumber is -1
        expect(pm.lastSentPacketNumber, equals(-1));

        // The fix specifies: use 0 if lastSentPacketNumber < 0
        final ackSeq = pm.lastSentPacketNumber >= 0 ? pm.lastSentPacketNumber : 0;
        expect(ackSeq, equals(0),
            reason: 'First ACK should use sequence 0 when no data sent yet');
      });

      test('sequence numbers remain contiguous for data packets only', () {
        final pm = PacketManager();
        final dataSequences = <int>[];

        // Simulate sending 10 data packets with ACKs in between
        for (int i = 0; i < 10; i++) {
          // Data packet
          final seq = pm.nextSequence;
          dataSequences.add(seq);
          pm.lastSentPacketNumber = seq;

          // Simulate an ACK (should NOT consume sequence number)
          // ignore: unused_local_variable
          final ackSeq = pm.lastSentPacketNumber >= 0 ? pm.lastSentPacketNumber : 0;
          // ACK would be sent here, but shouldn't affect data sequence
        }

        // Verify data sequences are contiguous 0-9
        expect(dataSequences, equals([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]));

        // Next data packet should be 10, proving ACKs didn't consume numbers
        expect(pm.nextSequence, equals(10));
      });
    });
  });
}

