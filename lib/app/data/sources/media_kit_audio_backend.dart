import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'audio_backend.dart';

/// An isolated native decoder. The injectable boundary keeps lifecycle tests
/// independent of audio hardware while exercising the production load policy.
abstract interface class MediaKitAudioSession {
  Stream<BackendPlaybackState> get states;
  Stream<Duration> get positions;
  Stream<Duration> get durations;
  Stream<Object> get errors;
  Stream<bool> get audioReady;
  BackendPlaybackState get state;
  Duration? get duration;
  bool get isAudioReady;
  Future<void> setProperty(String name, String value);
  Future<void> open(Uri uri);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> dispose();
}

/// Windows audio adapter: lyrics belong to LyricsService, never mpv subtitles.
/// Each load owns a fresh decoder so old errors cannot contaminate a new song.
class MediaKitAudioBackend implements AudioBackend {
  MediaKitAudioBackend({
    MediaKitAudioSession Function()? createSession,
    this.loadTimeout = const Duration(seconds: 15),
    this.closeTimeout = const Duration(seconds: 5),
  }) : _createSession = createSession ?? _NativeAudioSession.new;

  final MediaKitAudioSession Function() _createSession;
  final Duration loadTimeout;
  final Duration closeTimeout;
  final _states = StreamController<BackendPlaybackState>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration?>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Future<void> _lifecycle = Future.value();
  Future<void>? _closing;
  _LoadRequest? _request;
  MediaKitAudioSession? _session;
  bool _disposed = false;
  bool _loading = false;
  double _volume = .7;

  @override
  Stream<BackendPlaybackState> get states => _states.stream;
  @override
  Stream<Duration> get positions => _positions.stream;
  @override
  Stream<Duration?> get durations => _durations.stream;
  @override
  Stream<Object> get errors => _errors.stream;

  bool _active(_LoadRequest request, MediaKitAudioSession session) =>
      !_disposed &&
      identical(_request, request) &&
      identical(_session, session);

  @override
  Future<Duration?> load(Uri uri) {
    if (_disposed) return Future.error(StateError('Audio backend is closed.'));
    _request?.cancel();
    final request = _request = _LoadRequest();
    final work = _lifecycle.then((_) => _load(request, uri));
    _lifecycle = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }

  Future<Duration?> _load(_LoadRequest request, Uri uri) async {
    if (_disposed || !identical(request, _request)) {
      throw StateError('Audio load was canceled.');
    }
    await _releaseSession();
    if (_disposed || !identical(request, _request)) {
      throw StateError('Audio load was canceled.');
    }
    final session = _session = _createSession();
    _loading = true;
    final ready = Completer<void>();
    final failure = Completer<void>();
    // Attach readiness/cancellation before any native operation starts.
    final settled = Future.any<void>([
      ready.future,
      request.canceled.future.then((_) {
        throw StateError('Audio load was canceled.');
      }),
    ]);
    // Cancellation may happen during an awaited native configuration operation.
    // Keep it handled until prepare awaits readiness.
    unawaited(settled.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    void emitState(BackendPlaybackState state) {
      if (!_active(request, session)) return;
      _states.add(
        BackendPlaybackState(
          playing: state.playing && !state.completed,
          loading: _loading || state.loading,
          completed: state.completed,
        ),
      );
    }

    _subscriptions.addAll([
      session.states.listen(emitState),
      session.positions.listen((value) {
        if (_active(request, session)) _positions.add(value);
      }),
      session.durations.listen((value) {
        if (_active(request, session)) _durations.add(value);
      }),
      session.audioReady.listen((value) {
        if (_active(request, session) && value && !ready.isCompleted) {
          ready.complete();
        }
      }),
      session.errors.listen((error) {
        if (!_active(request, session)) return;
        if (!failure.isCompleted) failure.completeError(error);
        _errors.add(error);
      }),
    ]);
    emitState(session.state);

    void checkActive() {
      if (!_active(request, session)) {
        throw StateError('Audio load was canceled.');
      }
    }

    Future<void> prepare() async {
      // Audio-only libmpv rejects auto-discovered LRC subtitles. Older bridge
      // versions promote that auxiliary cplayer error into a fatal load error.
      await session.setProperty('sub-auto', 'no');
      checkActive();
      await session.setVolume(_volume * 100);
      checkActive();
      await session.open(uri);
      checkActive();
      if (session.isAudioReady && !ready.isCompleted) ready.complete();
      await settled;
    }

    try {
      await Future.any<void>([
        prepare(),
        failure.future,
        request.canceled.future.then((_) {
          throw StateError('Audio load was canceled.');
        }),
      ]).timeout(loadTimeout);
      checkActive();
      _loading = false;
      emitState(session.state);
      return session.duration;
    } catch (_) {
      _loading = false;
      if (identical(_session, session)) await _releaseSession();
      rethrow;
    }
  }

  Future<void> _releaseSession() async {
    final session = _session;
    _session = null;
    final subscriptions = _subscriptions.toList();
    _subscriptions.clear();
    try {
      await Future.wait(
        subscriptions.map((subscription) => subscription.cancel()),
      );
    } finally {
      if (session != null) await session.dispose().timeout(closeTimeout);
    }
  }

  @override
  Future<void> play() async {
    final session = _session;
    if (!_disposed && !_loading && session != null) await session.play();
  }

  @override
  Future<void> pause() async {
    final session = _session;
    if (!_disposed && session != null) await session.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    final session = _session;
    if (!_disposed && !_loading && session != null) {
      await session.seek(position);
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed || !volume.isFinite) return;
    _volume = volume.clamp(0, 1);
    final session = _session;
    if (session != null) await session.setVolume(_volume * 100);
  }

  @override
  Future<void> dispose() => _closing ??= _close();

  Future<void> _close() async {
    _disposed = true;
    _request?.cancel();
    await _lifecycle;
    try {
      await _releaseSession();
    } finally {
      await Future.wait([
        _states.close(),
        _positions.close(),
        _durations.close(),
        _errors.close(),
      ]);
    }
  }
}

class _LoadRequest {
  final canceled = Completer<void>();
  void cancel() {
    if (!canceled.isCompleted) canceled.complete();
  }
}

class _NativeAudioSession implements MediaKitAudioSession {
  _NativeAudioSession() {
    _player = _zone.run(
      () => Player(
        configuration: const PlayerConfiguration(
          title: 'HanMusic',
          muted: true,
        ),
      ),
    );
    _subscriptions.addAll([
      _player.stream.playing.listen((_) => _states.add(state)),
      _player.stream.buffering.listen((_) => _states.add(state)),
      _player.stream.completed.listen((_) => _states.add(state)),
    ]);
  }

  final _zone = Zone.current.fork(
    specification: ZoneSpecification(
      print: (self, parent, zone, line) {
        if (!line.startsWith('MPV: ')) {
          parent.print(
            zone,
            line.replaceAll(RegExp(r'https?://[^\s]+'), '<stream-url>'),
          );
        }
      },
    ),
  );
  late final Player _player;
  final _states = StreamController<BackendPlaybackState>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];

  @override
  Stream<BackendPlaybackState> get states => _states.stream;
  @override
  Stream<Duration> get positions => _player.stream.position;
  @override
  Stream<Duration> get durations => _player.stream.duration;
  @override
  Stream<Object> get errors => _player.stream.error;
  @override
  Stream<bool> get audioReady =>
      _player.stream.audioParams.map((params) => params.sampleRate != null);
  @override
  bool get isAudioReady => _player.state.audioParams.sampleRate != null;
  @override
  Duration? get duration =>
      _player.state.duration > Duration.zero ? _player.state.duration : null;
  @override
  BackendPlaybackState get state => BackendPlaybackState(
    playing: _player.state.playing,
    loading: _player.state.buffering,
    completed: _player.state.completed,
  );

  @override
  Future<void> setProperty(String name, String value) => _zone.run(() async {
    final native = _player.platform;
    if (native is! NativePlayer) {
      throw StateError('A native audio player is required.');
    }
    await native.setProperty(name, value);
  });
  @override
  Future<void> open(Uri uri) =>
      _zone.run(() => _player.open(Media(uri.toString()), play: false));
  @override
  Future<void> play() => _zone.run(_player.play);
  @override
  Future<void> pause() => _zone.run(_player.pause);
  @override
  Future<void> seek(Duration position) =>
      _zone.run(() => _player.seek(position));
  @override
  Future<void> setVolume(double volume) =>
      _zone.run(() => _player.setVolume(volume));
  @override
  Future<void> dispose() async {
    await Future.wait(
      _subscriptions.map((subscription) => subscription.cancel()),
    );
    try {
      await _zone.run(_player.dispose);
    } finally {
      await _states.close();
    }
  }
}
