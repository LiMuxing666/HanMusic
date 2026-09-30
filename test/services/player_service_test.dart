import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

import '../support/fake_audio_backend.dart';

void main() {
  late FakeAudioBackend backend;
  late PlayerService service;
  final song = Song(
    uri: Uri.file(r'D:\music\测试歌曲.mp3', windows: true),
    fileName: '测试歌曲.mp3',
  );

  setUp(() {
    backend = FakeAudioBackend();
    service = PlayerService(backend);
  });

  tearDown(() async => service.shutdown());

  test('loads, applies volume, and starts the selected audio', () async {
    await service.open(song);

    expect(backend.calls, ['pause', 'load', 'setVolume', 'play']);
    expect(backend.loadedUris, [song.uri]);
    expect(backend.volumes, [0.7]);
    expect(service.currentSong.value, same(song));
    expect(service.duration.value, const Duration(minutes: 3));
    expect(service.isLoading.value, isFalse);
    expect(service.canPlay, isTrue);
    expect(service.isPlaying.value, isTrue);
    expect(service.errorMessage.value, isNull);

    backend.emitPosition(const Duration(seconds: 35));
    backend.emitDuration(const Duration(minutes: 4));
    expect(service.position.value, const Duration(seconds: 35));
    expect(service.duration.value, const Duration(minutes: 4));
  });

  test(
    'a damaged file leaves playback disabled and reports an error',
    () async {
      backend.loadFailure = StateError('Decoder rejected damaged input');
      await service.open(song);

      expect(service.isLoading.value, isFalse);
      expect(service.canPlay, isFalse);
      expect(service.isPlaying.value, isFalse);
      expect(service.errorMessage.value, isNotEmpty);
      expect(backend.playCalls, 0);
      expect(backend.pauseCalls, 2);
      await service.togglePlayback();
      expect(backend.playCalls, 0);
    },
  );

  test('timer expiry during loading suppresses later autoplay', () async {
    backend.loadCompleter = Completer<Duration?>();
    var now = DateTime.utc(2026, 9, 29);
    final timer = TimerService(onExpired: service.pause, now: () => now);
    addTearDown(timer.onClose);

    final opening = service.open(song);
    await _flushCallbacks();
    expect(service.isLoading.value, isTrue);
    expect(backend.loadedUris, [song.uri]);

    timer.start(const Duration(seconds: 10));
    now = now.add(const Duration(minutes: 1));
    timer.checkDeadline();
    await _flushCallbacks();
    expect(backend.pauseCalls, 2);

    backend.loadCompleter!.complete(const Duration(minutes: 3));
    await opening;
    expect(service.canPlay, isTrue);
    expect(service.isPlaying.value, isFalse);
    expect(backend.playCalls, 0);
    expect(timer.remaining.value, isNull);
  });

  test(
    'replaying completed audio seeks to zero before requesting play',
    () async {
      await service.open(song);
      backend.emitPosition(const Duration(minutes: 3));
      backend.emitState(playing: true, completed: true);
      expect(service.isPlaying.value, isFalse);

      await service.togglePlayback();
      expect(backend.calls.sublist(4), ['seek', 'play']);
      expect(backend.seekPositions, [Duration.zero]);
      expect(service.position.value, Duration.zero);
      expect(service.isPlaying.value, isTrue);
    },
  );

  test('repeated toggle during restart seek requests playback once', () async {
    final successor = Song(
      uri: Uri.file('D:/music/successor.mp3', windows: true),
      fileName: 'successor.mp3',
    );
    await service.open(song);
    backend.emitState(playing: false, completed: true);
    await _flushCallbacks();
    service.addToQueue([successor]);
    backend.seekCompleter = Completer<void>();

    final firstToggle = service.togglePlayback();
    await service.togglePlayback();
    backend.emitState(playing: false, completed: true);
    await _flushCallbacks();
    expect(backend.seekPositions, [Duration.zero]);
    expect(backend.playCalls, 1);
    expect(service.currentSong.value?.id, song.id);
    expect(backend.loadedUris, [song.uri]);

    backend.seekCompleter!.complete();
    await firstToggle;
    expect(backend.playCalls, 2);
    expect(service.position.value, Duration.zero);
    expect(service.isPlaying.value, isTrue);

    backend.emitState(playing: false, completed: true);
    await _flushCallbacks();
    expect(service.currentSong.value?.id, successor.id);
    expect(backend.loadedUris, [song.uri, successor.uri]);
    expect(backend.playCalls, 3);
    expect(service.isPlaying.value, isTrue);
  });

  test(
    'pause during restart seek invalidates the pending play intent',
    () async {
      await service.open(song);
      backend.emitState(playing: false, completed: true);
      backend.seekCompleter = Completer<void>();

      final restarting = service.togglePlayback();
      await service.pause();
      backend.seekCompleter!.complete();
      await restarting;

      expect(backend.playCalls, 1);
      expect(service.isPlaying.value, isFalse);
    },
  );

  test(
    'obsolete restart failure cannot stop or skip a newly playing song',
    () async {
      final replacement = Song(
        uri: Uri.file('D:/music/replacement.mp3', windows: true),
        fileName: 'replacement.mp3',
      );
      final successor = Song(
        uri: Uri.file('D:/music/successor.mp3', windows: true),
        fileName: 'successor.mp3',
      );
      await service.open(song);
      backend.emitState(playing: false, completed: true);
      final gate = backend.seekCompleter = Completer<void>();
      final restarting = service.togglePlayback();
      expect(backend.seekPositions, [Duration.zero]);

      await service.playQueue([replacement, successor]);
      expect(service.currentSong.value?.id, replacement.id);
      expect(service.isPlaying.value, isTrue);
      final pauses = backend.pauseCalls;
      gate.completeError(StateError('Obsolete restart seek failed'));
      await restarting;
      await _flushCallbacks();

      expect(service.currentSong.value?.id, replacement.id);
      expect(service.isPlaying.value, isTrue);
      expect(service.canPlay, isTrue);
      expect(service.errorMessage.value, isNull);
      expect(backend.pauseCalls, pauses);
      expect(backend.loadedUris, [song.uri, replacement.uri]);
      expect(backend.playCalls, 2);
    },
  );

  test(
    'obsolete restart failure after pause leaves the same song usable',
    () async {
      await service.open(song);
      backend.emitState(playing: false, completed: true);
      final gate = backend.seekCompleter = Completer<void>();
      final restarting = service.togglePlayback();
      await service.pause();
      final pauses = backend.pauseCalls;
      gate.completeError(StateError('Paused restart seek failed'));
      await restarting;
      await _flushCallbacks();

      expect(service.currentSong.value?.id, song.id);
      expect(service.isPlaying.value, isFalse);
      expect(service.canPlay, isTrue);
      expect(service.errorMessage.value, isNull);
      expect(backend.pauseCalls, pauses);
      expect(backend.loadedUris, [song.uri]);
      expect(backend.playCalls, 1);

      backend.seekCompleter = null;
      await service.togglePlayback();
      expect(backend.seekPositions, [Duration.zero, Duration.zero]);
      expect(backend.playCalls, 2);
      expect(service.position.value, Duration.zero);
      expect(service.isPlaying.value, isTrue);
      expect(service.errorMessage.value, isNull);
    },
  );

  test(
    'obsolete restart success cannot overwrite a newer paused seek',
    () async {
      await service.shutdown();
      final controlled = _ControlledRestartSeekBackend();
      backend = controlled;
      service = PlayerService(backend);
      await service.open(song);
      backend.emitState(playing: false, completed: true);
      final gate = controlled.returnGate = Completer<void>();
      final restarting = service.togglePlayback();
      await service.pause();
      controlled.returnGate = null;
      await service.seek(const Duration(seconds: 42));
      expect(service.position.value, const Duration(seconds: 42));
      gate.complete();
      await restarting;

      expect(service.position.value, const Duration(seconds: 42));
      expect(service.isPlaying.value, isFalse);
      expect(service.canPlay, isTrue);
      expect(service.errorMessage.value, isNull);
      expect(backend.playCalls, 1);
    },
  );

  for (final skip in [false, true]) {
    test(
      'current restart failure preserves skip-on-error=$skip behavior',
      () async {
        final successor = Song(
          uri: Uri.file('D:/music/successor.mp3', windows: true),
          fileName: 'successor.mp3',
        );
        final messages = <String?>[];
        final subscription = service.errorMessage.listen(messages.add);
        addTearDown(subscription.cancel);
        service.skipOnError.value = skip;
        await service.open(song);
        backend.emitState(playing: false, completed: true);
        service.addToQueue([successor]);
        final gate = backend.seekCompleter = Completer<void>();
        final restarting = service.togglePlayback();
        expect(backend.seekPositions, [Duration.zero]);
        gate.completeError(StateError('Current restart seek failed'));
        await restarting;
        await _flushCallbacks();

        expect(
          messages.whereType<String>().where((value) => value.isNotEmpty),
          isNotEmpty,
        );
        if (skip) {
          expect(service.currentSong.value?.id, successor.id);
          expect(service.isPlaying.value, isTrue);
          expect(service.canPlay, isTrue);
          expect(service.errorMessage.value, isNull);
          expect(backend.loadedUris, [song.uri, successor.uri]);
          expect(backend.playCalls, 2);
        } else {
          expect(service.currentSong.value?.id, song.id);
          expect(service.isPlaying.value, isFalse);
          expect(service.canPlay, isFalse);
          expect(service.errorMessage.value, isNotEmpty);
          expect(backend.loadedUris, [song.uri]);
          expect(backend.playCalls, 1);
        }
      },
    );
  }

  test(
    'seek clamps to the known duration and accepts valid positions',
    () async {
      await service.open(song);
      await service.seek(const Duration(seconds: -10));
      await service.seek(const Duration(minutes: 10));
      await service.seek(const Duration(seconds: 42));

      expect(backend.seekPositions, [
        Duration.zero,
        const Duration(minutes: 3),
        const Duration(seconds: 42),
      ]);
      expect(service.position.value, const Duration(seconds: 42));
    },
  );

  test(
    'seek is ignored before load and when the duration is unknown',
    () async {
      await service.seek(const Duration(seconds: 5));
      backend.loadDuration = null;
      await service.open(song);
      await service.seek(const Duration(seconds: 5));
      expect(backend.seekPositions, isEmpty);
      expect(service.duration.value, Duration.zero);
    },
  );

  test('a backend error disables playback until a new file loads', () async {
    await service.open(song);
    backend.emitError(StateError('Native device failed'));
    expect(service.isPlaying.value, isFalse);
    expect(service.canPlay, isFalse);
    expect(service.errorMessage.value, isNotEmpty);
    expect(backend.pauseCalls, 2);

    await service.togglePlayback();
    await service.seek(const Duration(seconds: 5));
    expect(backend.playCalls, 1);
    expect(backend.seekPositions, isEmpty);

    await service.open(song);
    expect(service.canPlay, isTrue);
    expect(service.errorMessage.value, isNull);
    expect(backend.playCalls, 2);
  });

  test(
    'a failed error pause is contained and gives a stop-audio hint',
    () async {
      await service.shutdown();
      final controlled = _ControlledPauseBackend();
      backend = controlled;
      service = PlayerService(backend);
      await service.open(song);
      controlled.pauseFailure = StateError('Native pause failed');

      backend.emitError(StateError('Native decoder failed'));
      await _flushCallbacks();
      expect(backend.pauseCalls, 2);
      expect(service.canPlay, isFalse);
      expect(service.errorMessage.value, contains('关闭应用以停止音频'));

      controlled.pauseFailure = null;
      await service.open(song);
      expect(service.isPlaying.value, isTrue);
      expect(service.errorMessage.value, isNull);
    },
  );

  for (final pauseFails in [false, true]) {
    test(
      'reimport waits for a previous error pause (failure=$pauseFails)',
      () async {
        await service.shutdown();
        final controlled = _ControlledPauseBackend();
        backend = controlled;
        service = PlayerService(backend);
        await service.open(song);
        final stop = Completer<void>();
        controlled.pauseGate = stop;
        if (pauseFails) {
          controlled.pauseFailure = StateError('Delayed pause failed');
        }

        backend.emitError(StateError('Native decoder failed'));
        final reopening = service.open(song);
        await _flushCallbacks();
        expect(backend.pauseCalls, 2);
        expect(backend.loadedUris, [song.uri]);
        expect(backend.playCalls, 1);
        expect(service.isLoading.value, isTrue);

        controlled.pauseGate = null;
        controlled.pauseFailure = null;
        stop.complete();
        await reopening;
        expect(backend.calls.sublist(4), [
          'pause',
          'pause',
          'load',
          'setVolume',
          'play',
        ]);
        expect(service.isPlaying.value, isTrue);
        expect(service.canPlay, isTrue);
        expect(service.errorMessage.value, isNull);
      },
    );
  }

  test('repeated error events share one in-flight native pause', () async {
    await service.shutdown();
    final controlled = _ControlledPauseBackend();
    backend = controlled;
    service = PlayerService(backend);
    await service.open(song);
    final stop = Completer<void>();
    controlled.pauseGate = stop;
    backend.emitError(StateError('Decoder failed'));
    backend.emitError(StateError('Pause also emitted an error'));
    backend.emitError(StateError('Repeated backend error'));
    expect(backend.pauseCalls, 2);

    controlled.pauseGate = null;
    stop.complete();
    await _flushCallbacks();
    expect(service.canPlay, isFalse);
    await service.open(song);
    expect(service.isPlaying.value, isTrue);
  });

  test(
    'a stream error during load cannot be cleared by its late result',
    () async {
      backend.loadCompleter = Completer<Duration?>();
      final opening = service.open(song);
      await _flushCallbacks();
      backend.emitError(StateError('Native decoder failed during load'));
      backend.loadCompleter!.complete(const Duration(minutes: 3));
      await opening;

      expect(service.canPlay, isFalse);
      expect(service.isPlaying.value, isFalse);
      expect(service.errorMessage.value, isNotEmpty);
      expect(backend.playCalls, 0);
    },
  );

  test(
    'immediate shutdown prevents starting a load after initial pause',
    () async {
      final opening = service.open(song);
      final shuttingDown = service.shutdown();
      await Future.wait([opening, shuttingDown]);

      expect(backend.loadedUris, isEmpty);
      expect(backend.playCalls, 0);
      expect(backend.disposed, isTrue);
    },
  );

  test(
    'shutdown during load prevents completion from resuming audio',
    () async {
      backend.loadCompleter = Completer<Duration?>();
      final opening = service.open(song);
      await _flushCallbacks();
      await service.shutdown();

      backend.loadCompleter!.complete(const Duration(minutes: 3));
      await opening;
      await service.togglePlayback();
      await service.open(song);
      await service.shutdown();

      expect(backend.disposed, isTrue);
      expect(backend.playCalls, 0);
      expect(backend.volumes, isEmpty);
      expect(backend.loadedUris, [song.uri]);
      expect(backend.calls.where((call) => call == 'dispose'), hasLength(1));
      expect(service.canPlay, isFalse);
    },
  );
}

Future<void> _flushCallbacks() => Future<void>.delayed(Duration.zero);

class _ControlledRestartSeekBackend extends FakeAudioBackend {
  Completer<void>? returnGate;

  @override
  Future<void> seek(Duration position) async {
    final gate = returnGate;
    if (gate == null) return super.seek(position);
    calls.add('seek');
    seekPositions.add(position);
    // just_audio publishes the requested position before awaiting its platform
    // seek. Delay only the Future result, without inventing a late stream event.
    emitPosition(position);
    await gate.future;
  }
}

class _ControlledPauseBackend extends FakeAudioBackend {
  Completer<void>? pauseGate;
  Object? pauseFailure;

  @override
  Future<void> pause() async {
    final gate = pauseGate;
    final failure = pauseFailure;
    if (gate == null && failure == null) return super.pause();
    calls.add('pause');
    if (gate != null) await gate.future;
    if (failure != null) throw failure;
    emitState(playing: false);
  }
}
