import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/services/app_shutdown_coordinator.dart';

void main() {
  test('awaits final save and shares repeated close requests', () async {
    final calls = <String>[];
    final save = Completer<bool>();
    final coordinator = _coordinator(calls, flush: () => save.future);
    final first = coordinator.shutdown();
    expect(identical(first, coordinator.shutdown()), isTrue);
    await _turn();
    expect(calls, ['cancelImport', 'pause', 'save']);
    save.complete(true);
    expect(await first, isTrue);
    expect(calls, [..._beforeSave, ..._cleanup]);
    expect(identical(first, coordinator.shutdown()), isTrue);
    expect(coordinator.failedSteps, isEmpty);
  });

  test('cancel preserves services and the next close can save again', () async {
    final calls = <String>[];
    var saves = 0;
    final coordinator = _coordinator(
      calls,
      flush: () async => ++saves > 1,
      confirm: () async => false,
    );
    final first = coordinator.shutdown();
    expect(await first, isFalse);
    expect(calls, [..._beforeSave, 'confirm']);
    expect(coordinator.failedSteps, ['save']);
    final second = coordinator.shutdown();
    expect(identical(first, second), isFalse);
    expect(await second, isTrue);
    expect(calls, [..._beforeSave, 'confirm', ..._beforeSave, ..._cleanup]);
    expect(coordinator.failedSteps, isEmpty);
  });

  test('save exception requires explicit discard before cleanup', () async {
    final calls = <String>[];
    final decision = Completer<bool>();
    final coordinator = _coordinator(
      calls,
      flush: () async => throw StateError('disk unavailable'),
      confirm: () => decision.future,
    );
    final closing = coordinator.shutdown();
    await _turn();
    expect(calls, [..._beforeSave, 'confirm']);
    decision.complete(true);
    expect(await closing, isTrue);
    expect(calls, [..._beforeSave, 'confirm', ..._cleanup]);
    expect(coordinator.failedSteps, ['save']);
  });

  test('pause failure still saves and releases every service', () async {
    final calls = <String>[];
    final coordinator = _coordinator(
      calls,
      pause: () => throw StateError('native pause failed'),
    );
    expect(await coordinator.shutdown(), isTrue);
    expect(calls, [..._beforeSave, ..._cleanup]);
    expect(coordinator.failedSteps, ['pause']);
  });

  test('hanging pause is bounded and a late failure is consumed', () async {
    final calls = <String>[];
    final pause = Completer<void>();
    final coordinator = _coordinator(calls, pause: () => pause.future);
    expect(await coordinator.shutdown(), isTrue);
    expect(calls, [..._beforeSave, ..._cleanup]);
    expect(coordinator.failedSteps, ['pause']);
    pause.completeError(StateError('late native error'));
    await _turn();
  });

  test(
    'timed out disk save cancels before disposal and may finish later',
    () async {
      final calls = <String>[];
      final save = Completer<bool>();
      final coordinator = _coordinator(
        calls,
        flush: () => save.future,
        confirm: () async => false,
      );
      expect(await coordinator.shutdown(), isFalse);
      expect(calls, [..._beforeSave, 'confirm']);
      expect(coordinator.failedSteps, ['save']);
      save.complete(true);
      await _turn();
      expect(calls, [..._beforeSave, 'confirm']);
    },
  );

  test('each failed or hung cleanup still allows subsequent steps', () async {
    final calls = <String>[];
    final hung = Completer<void>();
    final coordinator = _coordinator(
      calls,
      cleanup: {
        'powerEvents': () => throw StateError('power failure'),
        'timers': () => hung.future,
        'persistence': () => throw StateError('listener failure'),
        'player': () => hung.future,
        'online': () => throw StateError('source write failure'),
        'library': () => hung.future,
      },
    );
    expect(await coordinator.shutdown(), isTrue);
    expect(calls, [..._beforeSave, ..._cleanup]);
    expect(coordinator.failedSteps, _cleanup);
    hung.complete();
    await _turn();
    expect(await coordinator.shutdown(), isTrue);
    expect(calls, [..._beforeSave, ..._cleanup]);
  });

  test('forced disposal tries saving but never opens confirmation', () async {
    final calls = <String>[];
    final coordinator = _coordinator(calls, flush: () async => false);
    expect(await coordinator.shutdown(force: true), isTrue);
    expect(calls, [..._beforeSave, ..._cleanup]);
  });

  test(
    'force promotes the same pending confirmation and cleans up once',
    () async {
      final calls = <String>[];
      final decision = Completer<bool>();
      final coordinator = _coordinator(
        calls,
        flush: () async => false,
        confirm: () => decision.future,
      );
      final ordinary = coordinator.shutdown();
      await _turn();
      expect(calls, [..._beforeSave, 'confirm']);
      final forced = coordinator.shutdown(force: true);
      expect(identical(ordinary, forced), isTrue);
      expect(await forced, isTrue);
      decision.complete(false);
      await _turn();
      expect(calls, [..._beforeSave, 'confirm', ..._cleanup]);
    },
  );

  test('confirmation exception cancels instead of losing state', () async {
    final calls = <String>[];
    final coordinator = _coordinator(
      calls,
      flush: () async => false,
      confirm: () async => throw StateError('dialog unavailable'),
    );
    expect(await coordinator.shutdown(), isFalse);
    expect(calls, [..._beforeSave, 'confirm']);
    expect(coordinator.failedSteps, ['save', 'confirmation']);
  });

  test(
    'optional confirmation deadline cancels without disposing services',
    () async {
      final calls = <String>[];
      final decision = Completer<bool>();
      final coordinator = _coordinator(
        calls,
        flush: () async => false,
        confirm: () => decision.future,
        confirmationTimeout: const Duration(milliseconds: 25),
      );
      expect(await coordinator.shutdown(), isFalse);
      expect(calls, [..._beforeSave, 'confirm']);
      decision.complete(true);
      await _turn();
      expect(calls, [..._beforeSave, 'confirm']);
    },
  );
}

const _beforeSave = ['cancelImport', 'pause', 'save'];
const _cleanup = [
  'powerEvents',
  'timers',
  'persistence',
  'player',
  'online',
  'library',
];

Future<void> _turn() => Future<void>.delayed(Duration.zero);

AppShutdownCoordinator _coordinator(
  List<String> calls, {
  FutureOr<void> Function()? pause,
  Future<bool> Function()? flush,
  Future<bool> Function()? confirm,
  Map<String, FutureOr<void> Function()> cleanup = const {},
  Duration? confirmationTimeout,
}) {
  Future<void> close(String name) async {
    calls.add(name);
    await cleanup[name]?.call();
  }

  return AppShutdownCoordinator(
    cancelImport: () => calls.add('cancelImport'),
    pause: () {
      calls.add('pause');
      return pause?.call();
    },
    flush: () async {
      calls.add('save');
      return await flush?.call() ?? true;
    },
    confirmExitWithoutSaving: () async {
      calls.add('confirm');
      return await confirm?.call() ?? false;
    },
    disposePowerEvents: () => close('powerEvents'),
    closeTimers: () => close('timers'),
    closePersistence: () => close('persistence'),
    closePlayer: () => close('player'),
    closeOnline: () => close('online'),
    closeLibrary: () => close('library'),
    stepTimeout: const Duration(milliseconds: 25),
    saveTimeout: const Duration(milliseconds: 25),
    confirmationTimeout: confirmationTimeout,
  );
}
