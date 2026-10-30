import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/sources/audio_backend.dart';
import 'package:han_music/app/data/sources/media_kit_audio_backend.dart';

void main() {
  late MediaKitAudioBackend backend;
  late List<_Session> sessions;
  final uri = Uri.file('D:/音乐 & samples/曲目 (UTF8).wav', windows: true);

  setUp(() {
    sessions = [];
    backend = MediaKitAudioBackend(
      createSession: () {
        final session = _Session();
        sessions.add(session);
        return session;
      },
    );
  });
  tearDown(() async {
    await backend.dispose();
    for (final session in sessions) {
      await session.closeStreams();
    }
  });

  test(
    'disables subtitle discovery before opening audio and keeps lyrics path literal',
    () async {
      final configured = Completer<void>();
      final session = _Session()..configureGate = configured;
      sessions.add(session);
      await backend.dispose();
      backend = MediaKitAudioBackend(createSession: () => session);
      await backend.setVolume(0);
      final loading = backend.load(uri);
      await _settle();
      expect(session.calls, ['property:sub-auto=no']);
      configured.complete();
      expect(await loading, const Duration(minutes: 3));
      expect(session.calls, ['property:sub-auto=no', 'volume:0.0', 'open']);
      expect(session.opened, uri);
      expect(session.state.playing, isFalse);
    },
  );

  test(
    'reload owns a new decoder and retired errors and position cannot leak',
    () async {
      final errors = <Object>[];
      final positions = <Duration>[];
      backend.errors.listen(errors.add);
      backend.positions.listen(positions.add);
      await backend.load(uri);
      final first = sessions.single;
      await backend.load(Uri.file('D:/second.wav', windows: true));
      expect(sessions, hasLength(2));
      expect(first.disposeCalls, 1);
      first.errorEvents.add(StateError('old decoder'));
      first.positionEvents.add(const Duration(seconds: 99));
      final genuine = StateError('current decoder failure');
      sessions.last.errorEvents.add(genuine);
      sessions.last.positionEvents.add(const Duration(seconds: 7));
      await _settle();
      expect(errors, [genuine]);
      expect(positions, [const Duration(seconds: 7)]);
    },
  );

  test('real decoder errors fail pending loads and remain visible', () async {
    final session = _Session()..autoReady = false;
    sessions.add(session);
    await backend.dispose();
    backend = MediaKitAudioBackend(createSession: () => session);
    final errors = <Object>[];
    backend.errors.listen(errors.add);
    final loading = backend.load(uri);
    final failure = StateError('Failed to decode audio stream');
    final assertion = expectLater(loading, throwsA(same(failure)));
    await _settle();
    session.errorEvents.add(failure);
    await assertion;
    await _settle();
    expect(errors, [failure]);
    expect(session.disposeCalls, 1);
  });

  for (final stage in ['configuration', 'open']) {
    test(
      'decoder error interrupts stalled $stage without becoming a timeout',
      () async {
        final gate = Completer<void>();
        final session = _Session();
        if (stage == 'configuration') {
          session.configureGate = gate;
        } else {
          session.openGate = gate;
        }
        sessions.add(session);
        await backend.dispose();
        backend = MediaKitAudioBackend(createSession: () => session);
        final loading = backend.load(uri);
        final failure = StateError('decoder rejected media during $stage');
        final assertion = expectLater(
          loading.timeout(const Duration(seconds: 1)),
          throwsA(same(failure)),
        );
        await _settle();
        session.errorEvents.add(failure);
        await assertion;
        expect(session.disposeCalls, 1);
        gate.complete();
        await _settle();
        expect(session.calls.where((call) => call == 'play'), isEmpty);
      },
    );
  }

  test(
    'new load cancels old pending open and ignores late completion',
    () async {
      final gate = Completer<void>();
      final first = _Session()..openGate = gate;
      sessions.add(first);
      await backend.dispose();
      var calls = 0;
      backend = MediaKitAudioBackend(
        createSession: () {
          if (calls++ == 0) return first;
          final next = _Session();
          sessions.add(next);
          return next;
        },
      );
      final old = backend.load(uri);
      final canceled = expectLater(old, throwsStateError);
      await _settle();
      final next = backend.load(Uri.file('D:/next.wav', windows: true));
      await canceled;
      expect(await next, const Duration(minutes: 3));
      expect(first.disposeCalls, 1);
      gate.complete();
      await _settle();
      expect(sessions.last.disposeCalls, 0);
      expect(first.calls.where((call) => call == 'play'), isEmpty);
    },
  );

  test(
    'load timeout covers stalled native operations and releases the decoder',
    () async {
      final gate = Completer<void>();
      final session = _Session()..openGate = gate;
      sessions.add(session);
      await backend.dispose();
      backend = MediaKitAudioBackend(
        createSession: () => session,
        loadTimeout: const Duration(milliseconds: 25),
      );
      await expectLater(backend.load(uri), throwsA(isA<TimeoutException>()));
      expect(session.disposeCalls, 1);
      gate.complete();
      await _settle();
    },
  );

  test(
    'dispose cancels pending decode, awaits release and closes once',
    () async {
      final session = _Session()..autoReady = false;
      sessions.add(session);
      await backend.dispose();
      backend = MediaKitAudioBackend(createSession: () => session);
      final loading = backend.load(uri);
      final canceled = expectLater(loading, throwsStateError);
      await _settle();
      await backend.dispose();
      await canceled;
      await backend.dispose();
      expect(session.disposeCalls, 1);
      session.errorEvents.add(StateError('late shutdown error'));
      await expectLater(backend.load(uri), throwsStateError);
    },
  );

  test(
    'volume maps to native percentages, playback commands complete and EOF is forwarded',
    () async {
      final states = <BackendPlaybackState>[];
      backend.states.listen(states.add);
      await backend.setVolume(.35);
      await backend.load(uri);
      final session = sessions.single;
      expect(session.calls, contains('volume:35.0'));
      await backend.setVolume(-1);
      await backend.setVolume(2);
      await backend.setVolume(double.nan);
      expect(session.calls.where((c) => c.startsWith('volume:')), [
        'volume:35.0',
        'volume:0.0',
        'volume:100.0',
      ]);
      await backend.play();
      await backend.seek(const Duration(seconds: 11));
      await backend.pause();
      session.state = const BackendPlaybackState(
        playing: true,
        completed: true,
      );
      session.stateEvents.add(session.state);
      await _settle();
      expect(
        session.calls,
        containsAllInOrder(['play', 'seek:11000', 'pause']),
      );
      expect(states.last.completed, isTrue);
      expect(states.last.playing, isFalse);
      expect(states.last.loading, isFalse);
    },
  );

  test(
    'native configuration failure is not ignored and does not open media',
    () async {
      final failure = StateError('sub-auto property rejected');
      final session = _Session()..configureError = failure;
      sessions.add(session);
      await backend.dispose();
      backend = MediaKitAudioBackend(createSession: () => session);
      await expectLater(backend.load(uri), throwsA(same(failure)));
      expect(session.opened, isNull);
      expect(session.disposeCalls, 1);
    },
  );
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

class _Session implements MediaKitAudioSession {
  final calls = <String>[];
  final stateEvents = StreamController<BackendPlaybackState>.broadcast(
    sync: true,
  );
  final positionEvents = StreamController<Duration>.broadcast(sync: true);
  final durationEvents = StreamController<Duration>.broadcast(sync: true);
  final errorEvents = StreamController<Object>.broadcast(sync: true);
  final readyEvents = StreamController<bool>.broadcast(sync: true);
  bool autoReady = true;
  Completer<void>? configureGate;
  Completer<void>? openGate;
  Object? configureError;
  int disposeCalls = 0;
  Uri? opened;
  @override
  bool isAudioReady = false;
  @override
  BackendPlaybackState state = const BackendPlaybackState(playing: false);
  @override
  Duration? get duration => isAudioReady ? const Duration(minutes: 3) : null;
  @override
  Stream<BackendPlaybackState> get states => stateEvents.stream;
  @override
  Stream<Duration> get positions => positionEvents.stream;
  @override
  Stream<Duration> get durations => durationEvents.stream;
  @override
  Stream<Object> get errors => errorEvents.stream;
  @override
  Stream<bool> get audioReady => readyEvents.stream;
  @override
  Future<void> setProperty(String name, String value) async {
    calls.add('property:$name=$value');
    if (configureError case final error?) throw error;
    await configureGate?.future;
  }

  @override
  Future<void> open(Uri uri) async {
    calls.add('open');
    opened = uri;
    await openGate?.future;
    isAudioReady = autoReady;
    readyEvents.add(autoReady);
  }

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> seek(Duration position) async =>
      calls.add('seek:${position.inMilliseconds}');
  @override
  Future<void> setVolume(double volume) async => calls.add('volume:$volume');
  @override
  Future<void> dispose() async => disposeCalls++;
  Future<void> closeStreams() => Future.wait([
    stateEvents.close(),
    positionEvents.close(),
    durationEvents.close(),
    errorEvents.close(),
    readyEvents.close(),
  ]);
}
