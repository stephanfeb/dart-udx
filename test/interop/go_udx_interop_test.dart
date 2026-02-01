import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_udx/src/packet.dart';
import 'package:dart_udx/src/cid.dart';
import 'package:test/test.dart';

void main() {
  group('Go UDX Interop', () {
    test('Dart → Go echo round-trip', () async {
      // Build the Go interop server
      final goUdxDir = '../go-udx';
      final buildResult = await Process.run(
        'go',
        ['build', '-o', 'interop-server', './cmd/interop-server/'],
        workingDirectory: goUdxDir,
      );
      if (buildResult.exitCode != 0) {
        fail('Go build failed: ${buildResult.stderr}');
      }

      // Start the Go interop server
      final goServer = await Process.start(
        '$goUdxDir/interop-server',
        [],
      );

      // Wait for READY <port>
      final portCompleter = Completer<int>();
      goServer.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        print('[go-server] $line');
        if (line.startsWith('READY ')) {
          final port = int.tryParse(line.substring(6));
          if (port != null && !portCompleter.isCompleted) {
            portCompleter.complete(port);
          }
        }
      });

      final serverPort = await portCompleter.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          goServer.kill();
          throw TimeoutException('Go server did not become ready');
        },
      );

      print('Go server ready on port $serverPort');

      try {
        // Create UDP client
        final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);

        // Build a UDX v2 packet with a STREAM frame
        final dcid = ConnectionId(Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]));
        final scid = ConnectionId(Uint8List.fromList([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18]));

        final testData = Uint8List.fromList('Hello from Dart to Go!'.codeUnits);

        final pkt = UDXPacket(
          destinationCid: dcid,
          sourceCid: scid,
          sequence: 42,
          destinationStreamId: 1,
          sourceStreamId: 2,
          frames: [
            StreamFrame(data: testData),
          ],
        );

        final pktBytes = pkt.toBytes();
        print('Sending ${pktBytes.length} byte packet to Go server');

        socket.send(pktBytes, InternetAddress.loopbackIPv4, serverPort);

        // Read response
        final responseCompleter = Completer<Datagram>();
        final sub = socket.listen((event) {
          if (event == RawSocketEvent.read) {
            final datagram = socket.receive();
            if (datagram != null && !responseCompleter.isCompleted) {
              responseCompleter.complete(datagram);
            }
          }
        });

        final response = await responseCompleter.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('No response from Go server'),
        );

        await sub.cancel();
        socket.close();

        print('Received ${response.data.length} byte response from Go server');

        // Parse response
        final resp = UDXPacket.fromBytes(response.data);

        // Verify
        expect(resp.version, equals(0x00000002)); // VersionV2
        expect(resp.destinationCid, equals(scid));
        expect(resp.sourceCid, equals(dcid));
        expect(resp.sequence, equals(43));
        expect(resp.destinationStreamId, equals(2));
        expect(resp.sourceStreamId, equals(1));
        expect(resp.frames.length, equals(1));
        expect(resp.frames[0], isA<StreamFrame>());
        final sf = resp.frames[0] as StreamFrame;
        expect(sf.data, equals(testData));

        print('Dart → Go interop test PASSED');
      } finally {
        goServer.kill();
        await goServer.exitCode;
        // Clean up binary
        try {
          File('../go-udx/interop-server').deleteSync();
        } catch (_) {}
      }
    });
  });
}
