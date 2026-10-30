import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/music_recognition.dart';
import 'package:han_music/app/data/repositories/music_recognition_repository.dart';
import 'package:han_music/app/data/sources/music_capture.dart';
import 'package:han_music/app/services/music_recognition_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Capture capture;
  late _Repository repository;
  late MusicRecognitionService service;

  setUp(() {
    capture = _Capture();
    repository = _Repository();
    service = MusicRecognitionService(capture: capture, repository: repository);
  });
  tearDown(() => service.close());

  test('an unconfigured service never starts capture or uploads', () async {
    repository.configured = false;
    await service.start();
    expect(capture.calls, 0);
    expect(repository.calls, 0);
    expect(service.isAvailable, isFalse);
    expect(service.errorMessage.value, '识曲服务暂未开通，请稍后重试。');
  });

  test(
    'single flight captures chosen source then uploads and clears audio',
    () async {
      service.setSource(MusicCaptureSource.microphone);
      final pending = service.start();
      await service.start();
      service.setSource(MusicCaptureSource.loopback);
      expect(capture.calls, 1);
      expect(capture.source, MusicCaptureSource.microphone);
      expect(capture.duration, const Duration(seconds: 12));
      expect(service.phase.value, RecognitionPhase.listening);
      final sample = Uint8List.fromList(List.filled(48, 7));
      capture.pending.complete(sample);
      await _settle();
      expect(service.phase.value, RecognitionPhase.recognizing);
      repository.pending.complete(_match());
      await pending;
      expect(service.result.value?.title, '测试歌曲');
      expect(service.phase.value, RecognitionPhase.success);
      expect(sample.every((byte) => byte == 0), isTrue);
    },
  );

  test('cancel during capture prevents any later upload', () async {
    final pending = service.start();
    await service.cancel();
    final sample = Uint8List.fromList(List.filled(48, 9));
    capture.pending.complete(sample);
    await pending;
    expect(repository.calls, 0);
    expect(capture.cancels, 1);
    expect(service.phase.value, RecognitionPhase.idle);
    expect(sample.every((byte) => byte == 0), isTrue);
  });

  test('late upload cannot overwrite the next recognition', () async {
    final first = service.start();
    capture.pending.complete(Uint8List(48));
    await _settle();
    final firstUpload = repository.pending;
    final firstCancellation = repository.cancellation!;
    await service.cancel();
    expect(firstCancellation.isCancelled, isTrue);
    capture.pending = Completer();
    repository.pending = Completer();
    final second = service.start();
    capture.pending.complete(Uint8List(48));
    await _settle();
    repository.pending.complete(null);
    await second;
    firstUpload.complete(_match());
    await first;
    expect(service.phase.value, RecognitionPhase.noMatch);
    expect(service.result.value, isNull);
  });

  test('start remains blocked until native cancellation completes', () async {
    final pending = service.start();
    capture.stopGate = Completer<void>();
    final stopping = service.cancel();
    await service.start();
    expect(capture.calls, 1);
    expect(service.phase.value, RecognitionPhase.cancelling);
    capture.stopGate!.complete();
    await stopping;
    capture.pending.completeError(const MusicRecognitionException('已取消。'));
    await pending;
    expect(service.errorMessage.value, isNull);
  });

  test(
    'exit cancels capture and a canceled exit permits a fresh request',
    () async {
      final pending = service.start();
      await service.beginExit();
      capture.pending.complete(Uint8List(48));
      await pending;
      await service.start();
      expect(capture.calls, 1);
      expect(service.acceptsCommands, isFalse);
      service.cancelExit();
      capture.pending = Completer();
      final next = service.start();
      capture.pending.completeError(const MusicRecognitionException('无音频设备。'));
      await next;
      expect(capture.calls, 2);
      expect(service.errorMessage.value, '无音频设备。');
      expect(service.phase.value, RecognitionPhase.error);
    },
  );

  test('close invalidates late results and closes repository', () async {
    final pending = service.start();
    await service.close();
    capture.pending.complete(Uint8List(48));
    await pending;
    service.cancelExit();
    await service.start();
    expect(service.acceptsCommands, isFalse);
    expect(repository.closed, isTrue);
    expect(repository.calls, 0);
    expect(capture.calls, 1);
  });

  test('unknown backend exceptions cannot leak internal error text', () async {
    final pending = service.start();
    capture.pending.completeError(StateError('private-secret-diagnostic'));
    await pending;
    expect(service.phase.value, RecognitionPhase.error);
    expect(service.errorMessage.value, isNot(contains('private-secret')));
  });

  group('Windows capture channel', () {
    const channel = MethodChannel('hanmusic/test_capture');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('uses explicit source and duration without a file path', () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return Uint8List(48);
      });
      final sample = await WindowsMusicCapture(channel: channel).capture(
        source: MusicCaptureSource.loopback,
        duration: const Duration(seconds: 12),
      );
      expect(received?.method, 'capture');
      expect(received?.arguments, {'source': 'loopback', 'durationMs': 12000});
      expect(sample.length, 48);
      sample.fillRange(0, sample.length, 1);
      expect(sample.every((byte) => byte == 1), isTrue);
    });

    test(
      'permission and missing plugin have actionable safe messages',
      () async {
        messenger.setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(
            code: 'permission_denied',
            message: 'private',
          );
        });
        final native = WindowsMusicCapture(channel: channel);
        await expectLater(
          native.capture(
            source: MusicCaptureSource.microphone,
            duration: const Duration(seconds: 12),
          ),
          throwsA(
            isA<MusicRecognitionException>().having(
              (e) => e.message,
              'message',
              allOf(contains('权限'), isNot(contains('private'))),
            ),
          ),
        );
        messenger.setMockMethodCallHandler(channel, null);
        await expectLater(
          native.capture(
            source: MusicCaptureSource.loopback,
            duration: const Duration(seconds: 12),
          ),
          throwsA(
            isA<MusicRecognitionException>().having(
              (e) => e.message,
              'message',
              contains('Windows'),
            ),
          ),
        );
        await native.cancel();
      },
    );
  });
}

MusicRecognitionResult _match() =>
    MusicRecognitionResult(title: '测试歌曲', artist: '测试歌手');
Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.value();
  }
}

class _Capture implements MusicCapture {
  Completer<Uint8List> pending = Completer();
  Completer<void>? stopGate;
  int calls = 0;
  int cancels = 0;
  MusicCaptureSource? source;
  Duration? duration;
  @override
  Future<Uint8List> capture({
    required MusicCaptureSource source,
    required Duration duration,
  }) {
    calls++;
    this.source = source;
    this.duration = duration;
    return pending.future;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    await stopGate?.future;
  }
}

class _Repository extends MusicRecognitionRepository {
  Completer<MusicRecognitionResult?> pending = Completer();
  int calls = 0;
  bool closed = false;
  bool configured = true;
  @override
  bool get isConfigured => configured;
  RecognitionCancellation? cancellation;
  @override
  Future<MusicRecognitionResult?> recognize({
    required Uint8List audio,
    required RecognitionCancellation cancellation,
  }) {
    calls++;
    this.cancellation = cancellation;
    return pending.future;
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}
