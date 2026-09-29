import 'dart:async';

/// Coordinates a cancelable desktop exit without coupling it to widget state.
///
/// The host must block new playback/library edits while [shutdown] is pending,
/// and retain its data-directory lock until process termination: a timeout does
/// not cancel a native operation or an asynchronous disk write.
class AppShutdownCoordinator {
  AppShutdownCoordinator({
    required this.cancelImport,
    required this.pause,
    required this.flush,
    required this.confirmExitWithoutSaving,
    required this.disposePowerEvents,
    required this.closeTimers,
    required this.closePersistence,
    required this.closePlayer,
    required this.closeOnline,
    required this.closeLibrary,
    this.stepTimeout = const Duration(seconds: 3),
    this.saveTimeout = const Duration(seconds: 8),
    this.confirmationTimeout,
  }) : assert(stepTimeout > Duration.zero),
       assert(saveTimeout > Duration.zero),
       assert(
         confirmationTimeout == null || confirmationTimeout > Duration.zero,
       );

  final FutureOr<void> Function() cancelImport;
  final FutureOr<void> Function() pause;
  final Future<bool> Function() flush;

  /// true explicitly permits losing the latest unsaved state; false keeps the
  /// services open so the user can retry. Exceptions/timeouts cancel exit.
  final Future<bool> Function() confirmExitWithoutSaving;
  final FutureOr<void> Function() disposePowerEvents;
  final FutureOr<void> Function() closeTimers;

  /// Should stop persistence listeners without making a second save attempt.
  final FutureOr<void> Function() closePersistence;
  final FutureOr<void> Function() closePlayer;
  final FutureOr<void> Function() closeOnline;
  final FutureOr<void> Function() closeLibrary;
  final Duration stepTimeout;
  final Duration saveTimeout;
  // Human confirmation may remain open indefinitely. A test host may opt into
  // a deadline, but must then also dismiss its own confirmation UI.
  final Duration? confirmationTimeout;

  Future<bool>? _operation;
  bool _forceRequested = false;
  Completer<void>? _forceSignal;
  final List<String> _failedSteps = [];

  /// Safe step identifiers only, never raw backend errors or filesystem paths.
  List<String> get failedSteps => List.unmodifiable(_failedSteps);

  /// true allows the native window to close; false cancels this attempt.
  ///
  /// Repeated requests share an operation. A canceled attempt can be retried.
  /// [force] is for an already-disposing host: it skips UI confirmation, can
  /// promote an existing request, and still attempts a bounded save/cleanup.
  Future<bool> shutdown({bool force = false}) {
    if (_operation case final pending?) {
      if (force) {
        _forceRequested = true;
        final signal = _forceSignal;
        if (signal != null && !signal.isCompleted) signal.complete();
      }
      return pending;
    }
    _failedSteps.clear();
    _forceRequested = force;
    _forceSignal = Completer<void>();
    final completion = Completer<bool>();
    _operation = completion.future;
    unawaited(
      _run().then((exit) {
        if (!exit) _operation = null;
        completion.complete(exit);
      }),
    );
    return completion.future;
  }

  Future<bool> _run() async {
    await _step('cancelImport', cancelImport);
    await _step('pause', pause);
    final saved = await _save();
    if (!saved && !_forceRequested && !await _confirm()) return false;

    // Every cleanup gets its own error/timeout boundary. In particular, a
    // backend dispose failure must not skip source writes or library cleanup.
    for (final (name, action) in [
      ('powerEvents', disposePowerEvents),
      ('timers', closeTimers),
      ('persistence', closePersistence),
      ('player', closePlayer),
      ('online', closeOnline),
      ('library', closeLibrary),
    ]) {
      await _step(name, action);
    }
    return true;
  }

  Future<void> _step(String name, FutureOr<void> Function() action) async {
    try {
      await Future<void>.sync(action).timeout(stepTimeout);
    } catch (_) {
      _failedSteps.add(name);
    }
  }

  Future<bool> _save() async {
    try {
      if (await Future<bool>.sync(flush).timeout(saveTimeout)) return true;
    } catch (_) {
      // A late write remains owned by its store. Never unlock here.
    }
    _failedSteps.add('save');
    return false;
  }

  Future<bool> _confirm() async {
    try {
      final response = Future<bool>.sync(confirmExitWithoutSaving);
      final timeout = confirmationTimeout;
      final confirmed = await Future.any([
        if (timeout == null) response else response.timeout(timeout),
        _forceSignal!.future.then((_) => true),
      ]);
      return _forceRequested || confirmed;
    } catch (_) {
      _failedSteps.add('confirmation');
      return _forceRequested;
    }
  }
}
