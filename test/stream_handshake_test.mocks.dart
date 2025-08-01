// Mocks generated by Mockito 5.4.4 from annotations
// in dart_udx/test/stream_handshake_test.dart.
// Do not manually edit this file.

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'dart:async' as _i7;
import 'dart:io' as _i4;
import 'dart:typed_data' as _i8;

import 'package:dart_udx/src/cid.dart' as _i5;
import 'package:dart_udx/src/events.dart' as _i10;
import 'package:dart_udx/src/multiplexer.dart' as _i3;
import 'package:dart_udx/src/socket.dart' as _i6;
import 'package:dart_udx/src/stream.dart' as _i9;
import 'package:dart_udx/src/udx.dart' as _i2;
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

class _FakeUDX_0 extends _i1.SmartFake implements _i2.UDX {
  _FakeUDX_0(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakeUDXMultiplexer_1 extends _i1.SmartFake
    implements _i3.UDXMultiplexer {
  _FakeUDXMultiplexer_1(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakeInternetAddress_2 extends _i1.SmartFake
    implements _i4.InternetAddress {
  _FakeInternetAddress_2(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

class _FakeConnectionCids_3 extends _i1.SmartFake
    implements _i5.ConnectionCids {
  _FakeConnectionCids_3(
    Object parent,
    Invocation parentInvocation,
  ) : super(
          parent,
          parentInvocation,
        );
}

/// A class which mocks [UDPSocket].
///
/// See the documentation for Mockito's code generation for more information.
class MockUDPSocket extends _i1.Mock implements _i6.UDPSocket {
  MockUDPSocket() {
    _i1.throwOnMissingStub(this);
  }

  @override
  _i2.UDX get udx => (super.noSuchMethod(
        Invocation.getter(#udx),
        returnValue: _FakeUDX_0(
          this,
          Invocation.getter(#udx),
        ),
      ) as _i2.UDX);

  @override
  _i3.UDXMultiplexer get multiplexer => (super.noSuchMethod(
        Invocation.getter(#multiplexer),
        returnValue: _FakeUDXMultiplexer_1(
          this,
          Invocation.getter(#multiplexer),
        ),
      ) as _i3.UDXMultiplexer);

  @override
  _i4.InternetAddress get remoteAddress => (super.noSuchMethod(
        Invocation.getter(#remoteAddress),
        returnValue: _FakeInternetAddress_2(
          this,
          Invocation.getter(#remoteAddress),
        ),
      ) as _i4.InternetAddress);

  @override
  set remoteAddress(_i4.InternetAddress? _remoteAddress) => super.noSuchMethod(
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
  _i5.ConnectionCids get cids => (super.noSuchMethod(
        Invocation.getter(#cids),
        returnValue: _FakeConnectionCids_3(
          this,
          Invocation.getter(#cids),
        ),
      ) as _i5.ConnectionCids);

  @override
  set cids(_i5.ConnectionCids? _cids) => super.noSuchMethod(
        Invocation.setter(
          #cids,
          _cids,
        ),
        returnValueForMissingStub: null,
      );

  @override
  _i7.Future<void> get handshakeComplete => (super.noSuchMethod(
        Invocation.getter(#handshakeComplete),
        returnValue: _i7.Future<void>.value(),
      ) as _i7.Future<void>);

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
    _i8.Uint8List? data,
    _i4.InternetAddress? fromAddress,
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
  void send(_i8.Uint8List? data) => super.noSuchMethod(
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
  _i7.Future<void> close() => (super.noSuchMethod(
        Invocation.method(
          #close,
          [],
        ),
        returnValue: _i7.Future<void>.value(),
        returnValueForMissingStub: _i7.Future<void>.value(),
      ) as _i7.Future<void>);

  @override
  void registerStream(_i9.UDXStream? stream) => super.noSuchMethod(
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
  _i7.Future<void> sendMaxStreamsFrame() => (super.noSuchMethod(
        Invocation.method(
          #sendMaxStreamsFrame,
          [],
        ),
        returnValue: _i7.Future<void>.value(),
        returnValueForMissingStub: _i7.Future<void>.value(),
      ) as _i7.Future<void>);

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
  _i8.Uint8List? popInitialPacket(int? streamId) =>
      (super.noSuchMethod(Invocation.method(
        #popInitialPacket,
        [streamId],
      )) as _i8.Uint8List?);

  @override
  _i7.Future<void> sendMaxDataFrame(
    int? localMaxData, {
    int? streamId = 0,
  }) =>
      (super.noSuchMethod(
        Invocation.method(
          #sendMaxDataFrame,
          [localMaxData],
          {#streamId: streamId},
        ),
        returnValue: _i7.Future<void>.value(),
        returnValueForMissingStub: _i7.Future<void>.value(),
      ) as _i7.Future<void>);

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
  _i7.Stream<_i10.UDXEvent> on(String? event) => (super.noSuchMethod(
        Invocation.method(
          #on,
          [event],
        ),
        returnValue: _i7.Stream<_i10.UDXEvent>.empty(),
      ) as _i7.Stream<_i10.UDXEvent>);

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
