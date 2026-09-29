import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'audio_backend.dart';

void initializeAudioBackend() {
  if (Platform.isWindows) {
    JustAudioMediaKit.ensureInitialized(windows: true, linux: false);
    JustAudioMediaKit.title = 'HanMusic';
  }
}

class JustAudioBackend implements AudioBackend {
  JustAudioBackend() {
    _player = _audioZone.run(AudioPlayer.new);
    _errorSubscription = _player.errorStream.listen(_reportError);
  }

  // This bridge has no disabled MPV log level and prints decoder logs verbatim.
  // Keep error events, but prevent its console messages leaking signed URLs.
  final Zone _audioZone = Zone.current.fork(
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
  late final AudioPlayer _player;
  final StreamController<Object> _errors = StreamController<Object>.broadcast();
  late final StreamSubscription<PlayerException> _errorSubscription;
  Completer<Duration?>? _pendingLoad;
  bool _disposed = false;

  void _reportError(Object error) {
    if (_disposed) return;
    final pending = _pendingLoad;
    if (pending != null && !pending.isCompleted) pending.completeError(error);
    _errors.add(error);
  }

  @override
  Stream<BackendPlaybackState> get states => _player.playerStateStream.map(
    (state) => BackendPlaybackState(
      playing: state.playing,
      loading:
          state.processingState == ProcessingState.loading ||
          state.processingState == ProcessingState.buffering,
      completed: state.processingState == ProcessingState.completed,
    ),
  );

  @override
  Stream<Duration> get positions => _player.positionStream;
  @override
  Stream<Duration?> get durations => _player.durationStream;
  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Future<Duration?> load(Uri uri) async {
    if (_disposed) throw StateError('Audio backend is closed.');
    if (_pendingLoad != null) throw StateError('An audio load is in progress.');
    final pending = _pendingLoad = Completer<Duration?>();
    // The media-kit bridge reports decoder errors but can leave its native
    // load Future pending. Race that Future with errorStream and bound silence.
    final result = Future.any<Duration?>([
      pending.future,
      _audioZone.run(() => _player.setAudioSource(AudioSource.uri(uri))),
    ]);
    try {
      return await result.timeout(const Duration(seconds: 15));
    } catch (_) {
      // stop() deactivates/disposes the native player. The next source starts
      // a fresh native instance, so late events from a failed load cannot leak.
      if (!_disposed) await _audioZone.run(_player.stop);
      rethrow;
    } finally {
      _pendingLoad = null;
    }
  }

  @override
  Future<void> play() async {
    // just_audio's play Future lasts until pause/completion. Do not lock the UI
    // for the duration of a song, but still surface asynchronous native errors.
    unawaited(
      _audioZone
          .run(_player.play)
          .catchError((Object error) => _reportError(error)),
    );
  }

  @override
  Future<void> pause() => _audioZone.run(_player.pause);
  @override
  Future<void> seek(Duration position) =>
      _audioZone.run(() => _player.seek(position));
  @override
  Future<void> setVolume(double volume) =>
      _audioZone.run(() => _player.setVolume(volume));

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final pending = _pendingLoad;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('Audio backend is closed.'));
    }
    await _errorSubscription.cancel();
    await _audioZone.run(_player.dispose);
    await _errors.close();
  }
}
