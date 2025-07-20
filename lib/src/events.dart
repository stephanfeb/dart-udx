import 'dart:async';

import '../udx.dart';

/// Base class for all UDX events
class UDXEvent {
  /// The type of event
  final String type;
  
  /// The event data
  final dynamic data;

  /// Creates a new UDX event
  const UDXEvent(this.type, this.data);

  @override
  String toString() => 'UDXEvent(type: $type, data: $data)';
}

/// Custom error for when a stream is reset by a peer.
class StreamResetError extends Error {
  /// The error code sent by the peer.
  final int errorCode;

  StreamResetError(this.errorCode);

  @override
  String toString() {
    return 'Stream reset by peer with error code: $errorCode';
  }
}


/// Mixin that provides event emitting capabilities
mixin UDXEventEmitter {
  final Map<String, StreamController<UDXEvent>> _controllers = {};

  /// Returns a stream of events for the given type
  Stream<UDXEvent> on(String event) {
    return _controllers.putIfAbsent(
      event,
      () => StreamController<UDXEvent>.broadcast(),
    ).stream;
  }

  /// Emits an event of the given type with the given data
  void emit(String event, [dynamic data]) {
    final controller = _controllers[event];
    // //print('[UDXEventEmitter.emit] Emitter: ${this.hashCode}, Event: $event, Controller exists: ${controller != null}, Has listener: ${controller?.hasListener}');
    if (event == 'remoteConnectionWindowUpdate') {
      //print('[UDXEventEmitter.emit] Emitter: ${this.hashCode}, Event: $event, Controller exists: ${controller != null}, Has listener: ${controller?.hasListener}, Data: $data');
    }
    controller?.add(UDXEvent(event, data));
  }

  /// Closes all event streams
  void close() {
    for (final controller in _controllers.values) {
      controller.close();
    }
    _controllers.clear();
  }

  /// Flushes buffered events for a specific event type to a new listener.
  void flushBufferedStreams(String event, UDXEventCallback callback, List<dynamic> buffer) {
    if (event == 'stream') {
      final streamBuffer = List<UDXStream>.from(buffer);
      for (final stream in streamBuffer) {
        callback(UDXEvent('stream', stream));
      }
      buffer.clear();
    }
  }
}

/// A type definition for the event callback function.
typedef UDXEventCallback = void Function(UDXEvent event);
