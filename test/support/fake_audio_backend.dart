import 'dart:async';

import 'package:han_music/app/data/sources/audio_backend.dart';

/// In-memory backend with explicit gates for native operations under test.
class FakeAudioBackend implements AudioBackend {
  final _states = StreamController<BackendPlaybackState>.broadcast(sync: true);
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final _durations = StreamController<Duration?>.broadcast(sync: true);
  final _errors = StreamController<Object>.broadcast(sync: true);

  final calls = <String>[];
  final loadedUris = <Uri>[];
  final seekPositions = <Duration>[];
  final volumes = <double>[];
  Duration? loadDuration = const Duration(minutes: 3);
  Completer<Duration?>? loadCompleter;
  Completer<void>? seekCompleter;
  Object? loadFailure;
  Object? playFailure;
  Object? seekFailure;
  bool disposed = false;
  bool _playing = false;

  int get playCalls => calls.where((call) => call == 'play').length;
  int get pauseCalls => calls.where((call) => call == 'pause').length;

  @override
  Stream<BackendPlaybackState> get states => _states.stream;
  @override
  Stream<Duration> get positions => _positions.stream;
  @override
  Stream<Duration?> get durations => _durations.stream;
  @override
  Stream<Object> get errors => _errors.stream;

  void emitState({
    required bool playing,
    bool loading = false,
    bool completed = false,
  }) {
    if (disposed) return;
    _playing = playing;
    _states.add(
      BackendPlaybackState(
        playing: playing,
        loading: loading,
        completed: completed,
      ),
    );
  }

  void emitPosition(Duration position) {
    if (!disposed) _positions.add(position);
  }

  void emitDuration(Duration? duration) {
    if (!disposed) _durations.add(duration);
  }

  void emitError(Object error) {
    if (!disposed) _errors.add(error);
  }

  @override
  Future<Duration?> load(Uri uri) async {
    calls.add('load');
    loadedUris.add(uri);
    emitState(playing: false, loading: true);
    if (loadFailure case final failure?) throw failure;
    final length = loadCompleter == null
        ? loadDuration
        : await loadCompleter!.future;
    emitDuration(length);
    emitState(playing: false);
    return length;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    if (playFailure case final failure?) throw failure;
    emitState(playing: true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    emitState(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek');
    seekPositions.add(position);
    if (seekFailure case final failure?) throw failure;
    if (seekCompleter case final completer?) await completer.future;
    emitPosition(position);
    emitState(playing: _playing);
  }

  @override
  Future<void> setVolume(double volume) async {
    calls.add('setVolume');
    volumes.add(volume);
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    calls.add('dispose');
    disposed = true;
    await Future.wait([
      _states.close(),
      _positions.close(),
      _durations.close(),
      _errors.close(),
    ]);
  }
}
