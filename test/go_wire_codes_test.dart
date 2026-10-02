import 'dart:typed_data';

import 'package:dart_udx/src/cid.dart';
import 'package:dart_udx/src/packet.dart';
import 'package:test/test.dart';

// Frame bytes produced by go-udx's encoder (go-udx 47894a1, via js-udx's
// tools/gen-vectors), with the 34-byte packet header removed. Each must
// encode to exactly these bytes here, and decode to the right frame.
Uint8List _hex(String s) => Uint8List.fromList(
    [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

Frame _decode(Uint8List bytes) => Frame.fromBytes(ByteData.sublistView(bytes), 0);

void main() {
  group('frame type codes match go-udx', () {
    test('every type byte', () {
      expect({for (final t in FrameType.values) t.name: t.code}, {
        'padding': 0x00,
        'ping': 0x01,
        'ack': 0x02,
        'stream': 0x03,
        'windowUpdate': 0x04,
        'maxData': 0x05,
        'resetStream': 0x06,
        'maxStreams': 0x07,
        'mtuProbe': 0x08,
        'pathChallenge': 0x09,
        'pathResponse': 0x0a,
        'connectionClose': 0x0b,
        'stopSending': 0x0d,
        'dataBlocked': 0x0e,
        'streamDataBlocked': 0x0f,
        'newConnectionId': 0x10,
        'retireConnectionId': 0x11,
      });
    });

    test('0x0c and codes past 0x11 are unknown', () {
      for (final code in [0x0c, 0x12, 0xff]) {
        expect(() => _decode(Uint8List.fromList([code, 0, 0, 0, 0, 0, 0, 0, 0])), throwsArgumentError);
      }
    });

    test('STOP_SENDING', () {
      final go = _hex('0d0000000100000009');
      expect(StopSendingFrame(streamId: 1, errorCode: 9).toBytes(), go);
      final f = _decode(go) as StopSendingFrame;
      expect([f.streamId, f.errorCode], [1, 9]);
    });

    test('DATA_BLOCKED', () {
      final go = _hex('0e0000000000100000');
      expect(DataBlockedFrame(maxData: 1 << 20).toBytes(), go);
      expect((_decode(go) as DataBlockedFrame).maxData, 1 << 20);
    });

    test('STREAM_DATA_BLOCKED', () {
      final go = _hex('0f000000010000000000010000');
      expect(StreamDataBlockedFrame(streamId: 1, maxStreamData: 65536).toBytes(), go);
      final f = _decode(go) as StreamDataBlockedFrame;
      expect([f.streamId, f.maxStreamData], [1, 65536]);
    });

    test('NEW_CONNECTION_ID', () {
      final go = _hex('1000000000000000010000000000000000084041424344454647a0a1a2a3a4a5a6a7a8a9aaabacadaeaf');
      final frame = NewConnectionIdFrame(
        sequenceNumber: 1,
        retirePriorTo: 0,
        connectionId: ConnectionId(_hex('4041424344454647')),
        resetToken: StatelessResetToken(_hex('a0a1a2a3a4a5a6a7a8a9aaabacadaeaf')),
      );
      expect(frame.toBytes(), go);
      final f = _decode(go) as NewConnectionIdFrame;
      expect(f.sequenceNumber, 1);
      expect(f.connectionId.bytes, _hex('4041424344454647'));
    });

    test('RETIRE_CONNECTION_ID', () {
      final go = _hex('110000000000000003');
      expect(RetireConnectionIdFrame(sequenceNumber: 3).toBytes(), go);
      expect((_decode(go) as RetireConnectionIdFrame).sequenceNumber, 3);
    });

    test('CONNECTION_CLOSE is unchanged', () {
      final go = _hex('0b00000004000000030009626164206672616d65');
      final f = _decode(go) as ConnectionCloseFrame;
      expect([f.errorCode, f.frameType, f.reasonPhrase], [4, 3, 'bad frame']);
    });
  });
}
