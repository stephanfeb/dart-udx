import 'package:dart_udx/src/events.dart';
import 'package:test/test.dart';
import 'dart:async';

class TestEmitter with UDXEventEmitter {}

void main() {
  group('UDXEventEmitter', () {
    late TestEmitter emitter;

    setUp(() {
      emitter = TestEmitter();
    });

    tearDown(() {
      emitter.close();
    });

    test('emits and listens for a simple event', () async {
      final completer = Completer<UDXEvent>();
      emitter.on('test_event').listen(completer.complete);

      emitter.emit('test_event', 'test_data');

      final event = await completer.future.timeout(const Duration(seconds: 1));
      expect(event.type, equals('test_event'));
      expect(event.data, equals('test_data'));
    });

    test('multiple listeners receive the same event', () async {
      final completer1 = Completer<UDXEvent>();
      final completer2 = Completer<UDXEvent>();

      emitter.on('shared_event').listen(completer1.complete);
      emitter.on('shared_event').listen(completer2.complete);

      emitter.emit('shared_event', 'shared_data');

      final results = await Future.wait([
        completer1.future,
        completer2.future,
      ]).timeout(const Duration(seconds: 1));

      expect(results[0].data, equals('shared_data'));
      expect(results[1].data, equals('shared_data'));
    });

    test('close stops all event listeners', () async {
      bool wasCalled = false;
      emitter.on('stale_event').listen((_) {
        wasCalled = true;
      });

      emitter.close();
      emitter.emit('stale_event');

      // Give it a moment to ensure the event is not processed
      await Future.delayed(const Duration(milliseconds: 50));

      expect(wasCalled, isFalse);
    });
  });
}
