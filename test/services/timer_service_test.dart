import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/services/timer_service.dart';

void main() {
  late DateTime now;
  late TimerService service;
  late int expirations;

  setUp(() {
    now = DateTime.utc(2026, 9, 29, 12);
    expirations = 0;
    service = TimerService(
      now: () => now,
      onExpired: () async => expirations++,
    );
  });

  tearDown(() => service.onClose());

  test('starts with an absolute deadline and rejects invalid durations', () {
    expect(service.remaining.value, isNull);
    expect(service.deadline.value, isNull);

    service.start(const Duration(minutes: 5));
    final initialDeadline = now.add(const Duration(minutes: 5));
    expect(service.deadline.value, initialDeadline);
    expect(service.remaining.value, const Duration(minutes: 5));

    expect(() => service.start(Duration.zero), throwsArgumentError);
    expect(
      () => service.start(const Duration(seconds: -1)),
      throwsArgumentError,
    );
    expect(service.deadline.value, initialDeadline);
  });

  test('uses elapsed clock time even when ticks are delayed or skipped', () {
    service.start(const Duration(minutes: 1));
    now = now.add(const Duration(seconds: 17, milliseconds: 250));
    service.checkDeadline();
    expect(
      service.remaining.value,
      const Duration(seconds: 42, milliseconds: 750),
    );

    now = now.add(const Duration(seconds: 32, milliseconds: 750));
    service.checkDeadline();
    expect(service.remaining.value, const Duration(seconds: 10));
    expect(expirations, 0);
  });

  test('replacing a timer expires only at the replacement deadline', () async {
    service.start(const Duration(seconds: 10));
    now = now.add(const Duration(seconds: 5));
    service.start(const Duration(seconds: 30));

    now = now.add(const Duration(seconds: 5));
    service.checkDeadline();
    await _flushCallbacks();
    expect(service.remaining.value, const Duration(seconds: 25));
    expect(expirations, 0);

    now = now.add(const Duration(seconds: 25));
    service.checkDeadline();
    await _flushCallbacks();
    expect(expirations, 1);
  });

  test('cancel clears state and prevents expiration', () async {
    service.start(const Duration(seconds: 10));
    service.cancel();
    now = now.add(const Duration(hours: 1));
    service.checkDeadline();
    await _flushCallbacks();

    expect(service.deadline.value, isNull);
    expect(service.remaining.value, isNull);
    expect(expirations, 0);
  });

  test('resume beyond the deadline expires exactly once', () async {
    service.start(const Duration(minutes: 5));
    now = now.add(const Duration(hours: 2));
    service.checkDeadline();
    service.checkDeadline();
    expect(service.deadline.value, isNull);
    expect(service.remaining.value, isNull);

    await _flushCallbacks();
    service.checkDeadline();
    await _flushCallbacks();
    expect(expirations, 1);
  });

  test('cancel invalidates an expiration awaiting notification', () async {
    service.start(const Duration(seconds: 1));
    now = now.add(const Duration(seconds: 1));
    service.checkDeadline();
    service.cancel();
    await _flushCallbacks();
    expect(expirations, 0);
  });

  test('replacement invalidates an expiration awaiting notification', () async {
    service.start(const Duration(seconds: 1));
    now = now.add(const Duration(seconds: 1));
    service.checkDeadline();
    service.start(const Duration(minutes: 2));
    await _flushCallbacks();

    expect(expirations, 0);
    expect(service.remaining.value, const Duration(minutes: 2));
    now = now.add(const Duration(minutes: 2));
    service.checkDeadline();
    await _flushCallbacks();
    expect(expirations, 1);
  });

  test('close prevents pending expiration and further scheduling', () async {
    service.start(const Duration(seconds: 1));
    now = now.add(const Duration(seconds: 1));
    service.checkDeadline();
    service.onClose();
    service.checkDeadline();
    await _flushCallbacks();

    expect(service.remaining.value, isNull);
    expect(service.deadline.value, isNull);
    expect(expirations, 0);
    expect(() => service.start(const Duration(seconds: 1)), throwsStateError);
  });

  test('close cancels an active timer before its deadline', () async {
    service.start(const Duration(seconds: 1));
    service.onClose();
    now = now.add(const Duration(hours: 1));
    service.checkDeadline();
    await _flushCallbacks();
    expect(expirations, 0);
  });

  test('asynchronous callback errors are handled once', () async {
    service.onClose();
    final failure = StateError('Audio pause failed');
    final reportedErrors = <Object>[];
    service = TimerService(
      now: () => now,
      onExpired: () async {
        await Future<void>.value();
        throw failure;
      },
      onError: (error, stackTrace) {
        reportedErrors.add(error);
        expect(stackTrace, isNotNull);
      },
    );
    service.start(const Duration(seconds: 1));
    now = now.add(const Duration(seconds: 1));
    service.checkDeadline();
    await _flushCallbacks();
    service.checkDeadline();
    await _flushCallbacks();

    expect(reportedErrors, [same(failure)]);
    expect(service.remaining.value, isNull);
    expect(service.deadline.value, isNull);
  });

  test('errors are contained when no error callback was supplied', () async {
    service.onClose();
    service = TimerService(
      now: () => now,
      onExpired: () async => throw StateError('Expected callback failure'),
    );
    service.start(const Duration(seconds: 1));
    now = now.add(const Duration(seconds: 1));
    service.checkDeadline();
    await _flushCallbacks();
    expect(service.deadline.value, isNull);
  });
}

/// Flushes microtasks without waiting for any real timer interval.
Future<void> _flushCallbacks() => Future<void>.delayed(Duration.zero);
