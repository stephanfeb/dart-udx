// Mocks generated by Mockito 5.4.4 from annotations
// in dart_udx/test/ack_handling_test.dart.
// Do not manually edit this file.

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'dart:async' as _i11;
import 'dart:io' as _i5;
import 'dart:typed_data' as _i12;

import 'package:dart_udx/src/cid.dart' as _i6;
import 'package:dart_udx/src/congestion.dart' as _i9;
import 'package:dart_udx/src/events.dart' as _i13;
import 'package:dart_udx/src/multiplexer.dart' as _i4;
import 'package:dart_udx/src/pacing.dart' as _i8;
import 'package:dart_udx/src/packet.dart' as _i7;
import 'package:dart_udx/src/socket.dart' as _i10;
import 'package:dart_udx/src/stream.dart' as _i2;
import 'package:dart_udx/src/udx.dart' as _i3;
import 'package:mockito/mockito.dart' as _i1;

// ignore_for_file: type=lint
// ignore_for_file: avoid_redundant_argument_values
// ignore_for_file: avoid_setters_without_getters
// ignore_for_file: comment_references
// ignore_for_file: deprecated_member_use
// ignore_for_file: deprecated_member_use_from_same_package
// ignore_for_file: implementation_imports
// ignore_for_file: invalid_use_of_visible_for_testing_member
// ignore_for_file: prefer_const_constructors
// ignore_for_file: unnecessary_parenthesis
// ignore_for_file: camel_case_types
// ignore_for_file: subtype_of_sealed_class

class _FakeUDXStream_0 extends _i1.SmartFake implements _i2.UDXStream {
  _FakeUDXStream_0(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakeUDX_1 extends _i1.SmartFake implements _i3.UDX {
  _FakeUDX_1(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakeUDXMultiplexer_2 extends _i1.SmartFake
    implements _i4.UDXMultiplexer {
  _FakeUDXMultiplexer_2(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakeInternetAddress_3 extends _i1.SmartFake
    implements _i5.InternetAddress {
  _FakeInternetAddress_3(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakeConnectionCids_4 extends _i1.SmartFake
    implements _i6.ConnectionCids {
  _FakeConnectionCids_4(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakePacketManager_5 extends _i1.SmartFake implements _i7.PacketManager {
  _FakePacketManager_5(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakePacingController_6 extends _i1.SmartFake
    implements _i8.PacingController {
  _FakePacingController_6(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakeDuration_7 extends _i1.SmartFake implements Duration {
  _FakeDuration_7(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakeCongestionController_8 extends _i1.SmartFake
    implements _i9.CongestionController {
  _FakeCongestionController_8(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

/// A class which mocks [UDX].
///
/// See the documentation for Mockito's code generation for more information.
class MockUDX extends _i1.Mock implements _i3.UDX {
  MockUDX() {
    _i1.throwOnMissingStub(this);
  }

  @override
  _i2.UDXStream createStream(
    int? id, {
    bool? framed = false,
    int? initialSeq = 0,
  }) =>
      (super.noSuchMethod(
        Invocation.method(
          #createStream,
          [id],
          {
            #framed: framed,
            #initialSeq: initialSeq,
          },
        ),
        returnValue: _FakeUDXStream_0(
          this,
          Invocation.method(
            #createStream,
            [id],
            {
              #framed: framed,
              #initialSeq: initialSeq,
            },
          ),
        ),
      ) as _i2.UDXStream);
}

/// A class which mocks [UDPSocket].
///
/// See the documentation for Mockito's code generation for more information.
class MockUDPSocket extends _i1.Mock implements _i10.UDPSocket {
  MockUDPSocket() {
    _i1.throwOnMissingStub(this);
  }

  @override
  _i3.UDX get udx => (super.noSuchMethod(
        Invocation.getter(#udx),
        returnValue: _FakeUDX_1(
          this,
          Invocation.getter(#udx),
        ),
      ) as _i3.UDX);

  @override
  _i4.UDXMultiplexer get multiplexer => (super.noSuchMethod(
        Invocation.getter(#multiplexer),
        returnValue: _FakeUDXMultiplexer_2(
          this,
          Invocation.getter(#multiplexer),
        ),
      ) as _i4.UDXMultiplexer);

  @override
  _i5.InternetAddress get remoteAddress => (super.noSuchMethod(
        Invocation.getter(#remoteAddress),
        returnValue: _FakeInternetAddress_3(
          this,
          Invocation.getter(#remoteAddress),
        ),
      ) as _i5.InternetAddress);

  @override
  set remoteAddress(_i5.InternetAddress? _remoteAddress) => super.noSuchMethod(
        Invocation.setter(
          #remoteAddress,
          _remoteAddress,
        ),
        returnValueForMissingStub: null,
      );

  @override
  int get remotePort => (super.noSuchMethod(
        Invocation.getter(#remotePort),
        returnValue: 0,
      ) as int);

  @override
  set remotePort(int? _remotePort) => super.noSuchMethod(
        Invocation.setter(
          #remotePort,
          _remotePort,
        ),
        returnValueForMissingStub: null,
      );

  @override
  _i6.ConnectionCids get cids => (super.noSuchMethod(
        Invocation.getter(#cids),
        returnValue: _FakeConnectionCids_4(
          this,
          Invocation.getter(#cids),
        ),
      ) as _i6.ConnectionCids);

  @override
  set cids(_i6.ConnectionCids? _cids) => super.noSuchMethod(
        Invocation.setter(
          #cids,
          _cids,
        ),
        returnValueForMissingStub: null,
      );

  @override
  _i11.Future<void> get handshakeComplete => (super.noSuchMethod(
        Invocation.getter(#handshakeComplete),
        returnValue: _i11.Future<void>.value(),
      ) as _i11.Future<void>);

  @override
  bool get closing => (super.noSuchMethod(
        Invocation.getter(#closing),
        returnValue: false,
      ) as bool);

  @override
  bool get idle => (super.noSuchMethod(
        Invocation.getter(#idle),
        returnValue: false,
      ) as bool);

  @override
  bool get busy => (super.noSuchMethod(
        Invocation.getter(#busy),
        returnValue: false,
      ) as bool);

  @override
  void handleIncomingDatagram(
    _i12.Uint8List? data,
    _i5.InternetAddress? fromAddress,
    int? fromPort,
  ) =>
      super.noSuchMethod(
        Invocation.method(
          #handleIncomingDatagram,
          [
            data,
            fromAddress,
            fromPort,
          ],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void send(_i12.Uint8List? data) => super.noSuchMethod(
        Invocation.method(
          #send,
          [data],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void setTTL(int? ttl) => super.noSuchMethod(
        Invocation.method(
          #setTTL,
          [ttl],
        ),
        returnValueForMissingStub: null,
      );

  @override
  int getRecvBufferSize() => (super.noSuchMethod(
        Invocation.method(
          #getRecvBufferSize,
          [],
        ),
        returnValue: 0,
      ) as int);

  @override
  void setRecvBufferSize(int? size) => super.noSuchMethod(
        Invocation.method(
          #setRecvBufferSize,
          [size],
        ),
        returnValueForMissingStub: null,
      );

  @override
  int getSendBufferSize() => (super.noSuchMethod(
        Invocation.method(
          #getSendBufferSize,
          [],
        ),
        returnValue: 0,
      ) as int);

  @override
  void setSendBufferSize(int? size) => super.noSuchMethod(
        Invocation.method(
          #setSendBufferSize,
          [size],
        ),
        returnValueForMissingStub: null,
      );

  @override
  _i11.Future<void> close() => (super.noSuchMethod(
        Invocation.method(
          #close,
          [],
        ),
        returnValue: _i11.Future<void>.value(),
        returnValueForMissingStub: _i11.Future<void>.value(),
      ) as _i11.Future<void>);

  @override
  void registerStream(_i2.UDXStream? stream) => super.noSuchMethod(
        Invocation.method(
          #registerStream,
          [stream],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void unregisterStream(int? streamId) => super.noSuchMethod(
        Invocation.method(
          #unregisterStream,
          [streamId],
        ),
        returnValueForMissingStub: null,
      );

  @override
  _i11.Future<void> sendMaxStreamsFrame() => (super.noSuchMethod(
        Invocation.method(
          #sendMaxStreamsFrame,
          [],
        ),
        returnValue: _i11.Future<void>.value(),
        returnValueForMissingStub: _i11.Future<void>.value(),
      ) as _i11.Future<void>);

  @override
  bool canCreateNewStream() => (super.noSuchMethod(
        Invocation.method(
          #canCreateNewStream,
          [],
        ),
        returnValue: false,
      ) as bool);

  @override
  void incrementOutgoingStreams() => super.noSuchMethod(
        Invocation.method(
          #incrementOutgoingStreams,
          [],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void setLocalMaxStreamsForTest(int? value) => super.noSuchMethod(
        Invocation.method(
          #setLocalMaxStreamsForTest,
          [value],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void setRemoteMaxStreamsForTest(int? value) => super.noSuchMethod(
        Invocation.method(
          #setRemoteMaxStreamsForTest,
          [value],
        ),
        returnValueForMissingStub: null,
      );

  @override
  int getRegisteredStreamsCount() => (super.noSuchMethod(
        Invocation.method(
          #getRegisteredStreamsCount,
          [],
        ),
        returnValue: 0,
      ) as int);

  @override
  _i12.Uint8List? popInitialPacket(int? streamId) =>
      (super.noSuchMethod(Invocation.method(
        #popInitialPacket,
        [streamId],
      )) as _i12.Uint8List?);

  @override
  _i11.Future<void> sendMaxDataFrame(
    int? localMaxData, {
    int? streamId = 0,
  }) =>
      (super.noSuchMethod(
        Invocation.method(
          #sendMaxDataFrame,
          [localMaxData],
          {#streamId: streamId},
        ),
        returnValue: _i11.Future<void>.value(),
        returnValueForMissingStub: _i11.Future<void>.value(),
      ) as _i11.Future<void>);

  @override
  void advertiseConnectionWindowUpdate() => super.noSuchMethod(
        Invocation.method(
          #advertiseConnectionWindowUpdate,
          [],
        ),
        returnValueForMissingStub: null,
      );

  @override
  int getAvailableConnectionSendWindow() => (super.noSuchMethod(
        Invocation.method(
          #getAvailableConnectionSendWindow,
          [],
        ),
        returnValue: 0,
      ) as int);

  @override
  void incrementConnectionBytesSent(int? bytes) => super.noSuchMethod(
        Invocation.method(
          #incrementConnectionBytesSent,
          [bytes],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void decrementConnectionBytesSent(int? bytes) => super.noSuchMethod(
        Invocation.method(
          #decrementConnectionBytesSent,
          [bytes],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void onStreamDataProcessed(int? bytesProcessed) => super.noSuchMethod(
        Invocation.method(
          #onStreamDataProcessed,
          [bytesProcessed],
        ),
        returnValueForMissingStub: null,
      );

  @override
  _i11.Stream<_i13.UDXEvent> on(String? event) => (super.noSuchMethod(
        Invocation.method(
          #on,
          [event],
        ),
        returnValue: _i11.Stream<_i13.UDXEvent>.empty(),
      ) as _i11.Stream<_i13.UDXEvent>);

  @override
  void emit(
    String? event, [
    dynamic data,
  ]) =>
      super.noSuchMethod(
        Invocation.method(
          #emit,
          [
            event,
            data,
          ],
        ),
        returnValueForMissingStub: null,
      );
}

/// A class which mocks [CongestionController].
///
/// See the documentation for Mockito's code generation for more information.
class MockCongestionController extends _i1.Mock
    implements _i9.CongestionController {
  MockCongestionController() {
    _i1.throwOnMissingStub(this);
  }

  @override
  _i7.PacketManager get packetManager => (super.noSuchMethod(
        Invocation.getter(#packetManager),
        returnValue: _FakePacketManager_5(
          this,
          Invocation.getter(#packetManager),
        ),
      ) as _i7.PacketManager);

  @override
  set onProbe(void Function()? _onProbe) => super.noSuchMethod(
        Invocation.setter(
          #onProbe,
          _onProbe,
        ),
        returnValueForMissingStub: null,
      );

  @override
  set onFastRetransmit(void Function(int)? _onFastRetransmit) =>
      super.noSuchMethod(
        Invocation.setter(
          #onFastRetransmit,
          _onFastRetransmit,
        ),
        returnValueForMissingStub: null,
      );

  @override
  _i8.PacingController get pacingController => (super.noSuchMethod(
        Invocation.getter(#pacingController),
        returnValue: _FakePacingController_6(
          this,
          Invocation.getter(#pacingController),
        ),
      ) as _i8.PacingController);

  @override
  int get cwnd => (super.noSuchMethod(
        Invocation.getter(#cwnd),
        returnValue: 0,
      ) as int);

  @override
  int get ssthresh => (super.noSuchMethod(
        Invocation.getter(#ssthresh),
        returnValue: 0,
      ) as int);

  @override
  Duration get smoothedRtt => (super.noSuchMethod(
        Invocation.getter(#smoothedRtt),
        returnValue: _FakeDuration_7(
          this,
          Invocation.getter(#smoothedRtt),
        ),
      ) as Duration);

  @override
  Duration get rttVar => (super.noSuchMethod(
        Invocation.getter(#rttVar),
        returnValue: _FakeDuration_7(
          this,
          Invocation.getter(#rttVar),
        ),
      ) as Duration);

  @override
  Duration get minRtt => (super.noSuchMethod(
        Invocation.getter(#minRtt),
        returnValue: _FakeDuration_7(
          this,
          Invocation.getter(#minRtt),
        ),
      ) as Duration);

  @override
  int get inflight => (super.noSuchMethod(
        Invocation.getter(#inflight),
        returnValue: 0,
      ) as int);

  @override
  bool get isInRecoveryForTest => (super.noSuchMethod(
        Invocation.getter(#isInRecoveryForTest),
        returnValue: false,
      ) as bool);

  @override
  Duration get pto => (super.noSuchMethod(
        Invocation.getter(#pto),
        returnValue: _FakeDuration_7(
          this,
          Invocation.getter(#pto),
        ),
      ) as Duration);

  @override
  void onPacketSent(int? bytes) => super.noSuchMethod(
        Invocation.method(
          #onPacketSent,
          [bytes],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void onPacketAcked(
    int? bytes,
    DateTime? sentTime,
    Duration? ackDelay,
    bool? isNewCumulativeAck,
    int? currentFrameLargestAcked,
  ) =>
      super.noSuchMethod(
        Invocation.method(
          #onPacketAcked,
          [
            bytes,
            sentTime,
            ackDelay,
            isNewCumulativeAck,
            currentFrameLargestAcked,
          ],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void setSmoothedRtt(Duration? rtt) => super.noSuchMethod(
        Invocation.method(
          #setSmoothedRtt,
          [rtt],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void setRttVar(Duration? rttVar) => super.noSuchMethod(
        Invocation.method(
          #setRttVar,
          [rttVar],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void onPacketLost(
    int? bytes,
    List<_i7.UDXPacket>? lostPackets,
  ) =>
      super.noSuchMethod(
        Invocation.method(
          #onPacketLost,
          [
            bytes,
            lostPackets,
          ],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void processDuplicateAck(int? frameLargestAcked) => super.noSuchMethod(
        Invocation.method(
          #processDuplicateAck,
          [frameLargestAcked],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void destroy() => super.noSuchMethod(
        Invocation.method(
          #destroy,
          [],
        ),
        returnValueForMissingStub: null,
      );
}

/// A class which mocks [PacketManager].
///
/// See the documentation for Mockito's code generation for more information.
class MockPacketManager extends _i1.Mock implements _i7.PacketManager {
  MockPacketManager() {
    _i1.throwOnMissingStub(this);
  }

  @override
  _i9.CongestionController get congestionController => (super.noSuchMethod(
        Invocation.getter(#congestionController),
        returnValue: _FakeCongestionController_8(
          this,
          Invocation.getter(#congestionController),
        ),
      ) as _i9.CongestionController);

  @override
  set congestionController(_i9.CongestionController? _congestionController) =>
      super.noSuchMethod(
        Invocation.setter(
          #congestionController,
          _congestionController,
        ),
        returnValueForMissingStub: null,
      );

  @override
  int get lastSentPacketNumber => (super.noSuchMethod(
        Invocation.getter(#lastSentPacketNumber),
        returnValue: 0,
      ) as int);

  @override
  set lastSentPacketNumber(int? _lastSentPacketNumber) => super.noSuchMethod(
        Invocation.setter(
          #lastSentPacketNumber,
          _lastSentPacketNumber,
        ),
        returnValueForMissingStub: null,
      );

  @override
  set onRetransmit(void Function(_i7.UDXPacket)? _onRetransmit) =>
      super.noSuchMethod(
        Invocation.setter(
          #onRetransmit,
          _onRetransmit,
        ),
        returnValueForMissingStub: null,
      );

  @override
  set onSendProbe(void Function(_i7.UDXPacket)? _onSendProbe) =>
      super.noSuchMethod(
        Invocation.setter(
          #onSendProbe,
          _onSendProbe,
        ),
        returnValueForMissingStub: null,
      );

  @override
  set onPacketPermanentlyLost(
          void Function(_i7.UDXPacket)? _onPacketPermanentlyLost) =>
      super.noSuchMethod(
        Invocation.setter(
          #onPacketPermanentlyLost,
          _onPacketPermanentlyLost,
        ),
        returnValueForMissingStub: null,
      );

  @override
  int get nextSequence => (super.noSuchMethod(
        Invocation.getter(#nextSequence),
        returnValue: 0,
      ) as int);

  @override
  List<_i7.UDXPacket> get sentPackets => (super.noSuchMethod(
        Invocation.getter(#sentPackets),
        returnValue: <_i7.UDXPacket>[],
      ) as List<_i7.UDXPacket>);

  @override
  int get retransmitTimeout => (super.noSuchMethod(
        Invocation.getter(#retransmitTimeout),
        returnValue: 0,
      ) as int);

  @override
  void sendPacket(_i7.UDXPacket? packet) => super.noSuchMethod(
        Invocation.method(
          #sendPacket,
          [packet],
        ),
        returnValueForMissingStub: null,
      );

  @override
  List<int> handleAckFrame(_i7.AckFrame? frame) => (super.noSuchMethod(
        Invocation.method(
          #handleAckFrame,
          [frame],
        ),
        returnValue: <int>[],
      ) as List<int>);

  @override
  void handleData(_i7.UDXPacket? packet) => super.noSuchMethod(
        Invocation.method(
          #handleData,
          [packet],
        ),
        returnValueForMissingStub: null,
      );

  @override
  _i7.UDXPacket? getPacket(int? sequence) =>
      (super.noSuchMethod(Invocation.method(
        #getPacket,
        [sequence],
      )) as _i7.UDXPacket?);

  @override
  void sendProbe(
    _i6.ConnectionId? destCid,
    _i6.ConnectionId? srcCid,
    int? destId,
    int? srcId,
  ) =>
      super.noSuchMethod(
        Invocation.method(
          #sendProbe,
          [
            destCid,
            srcCid,
            destId,
            srcId,
          ],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void retransmitPacket(int? sequence) => super.noSuchMethod(
        Invocation.method(
          #retransmitPacket,
          [sequence],
        ),
        returnValueForMissingStub: null,
      );

  @override
  void destroy() => super.noSuchMethod(
        Invocation.method(
          #destroy,
          [],
        ),
        returnValueForMissingStub: null,
      );

  @override
  Map<int, _i7.UDXPacket> getSentPacketsTestHook() => (super.noSuchMethod(
        Invocation.method(
          #getSentPacketsTestHook,
          [],
        ),
        returnValue: <int, _i7.UDXPacket>{},
      ) as Map<int, _i7.UDXPacket>);

  @override
  Map<int, _i11.Timer> getRetransmitTimersTestHook() => (super.noSuchMethod(
        Invocation.method(
          #getRetransmitTimersTestHook,
          [],
        ),
        returnValue: <int, _i11.Timer>{},
      ) as Map<int, _i11.Timer>);
}

/// A class which mocks [Timer].
///
/// See the documentation for Mockito's code generation for more information.
class MockTimer extends _i1.Mock implements _i11.Timer {
  MockTimer() {
    _i1.throwOnMissingStub(this);
  }

  @override
  int get tick => (super.noSuchMethod(
        Invocation.getter(#tick),
        returnValue: 0,
      ) as int);

  @override
  bool get isActive => (super.noSuchMethod(
        Invocation.getter(#isActive),
        returnValue: false,
      ) as bool);

  @override
  void cancel() => super.noSuchMethod(
        Invocation.method(
          #cancel,
          [],
        ),
        returnValueForMissingStub: null,
      );
}
