import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/core/theme/app_theme.dart';
import 'package:han_music/app/data/models/music_recognition.dart';
import 'package:han_music/app/data/repositories/music_recognition_repository.dart';
import 'package:han_music/app/data/sources/music_capture.dart';
import 'package:han_music/app/modules/recognition/view.dart';
import 'package:han_music/app/services/music_recognition_service.dart';

void main() {
  testWidgets(
    'unavailable service has no setup fields and never samples or sends audio',
    (tester) async {
      await _withRecognition(
        tester,
        available: false,
        brightness: Brightness.dark,
        size: const Size(800, 600),
        scale: 2,
        run: (fixture) async {
          expect(fixture.service.isAvailable, isFalse);
          expect(find.text('识曲服务暂未开通'), findsOneWidget);
          expect(find.text('此版本暂不能使用听歌识曲，服务开通后即可直接使用。'), findsOneWidget);
          expect(find.byType(TextField), findsNothing);
          expect(find.textContaining('Token'), findsNothing);
          expect(
            find.byKey(const Key('recognition-token-input')),
            findsNothing,
          );
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('recognition-start')),
                )
                .onPressed,
            isNull,
          );
          expect(
            find.byKey(const Key('recognition-upload-disclosure')),
            findsOneWidget,
          );
          expect(
            tester
                .getTopLeft(
                  find.byKey(const Key('recognition-upload-disclosure')),
                )
                .dy,
            lessThan(
              tester.getTopLeft(find.byKey(const Key('recognition-start'))).dy,
            ),
          );
          await _tap(tester, find.byKey(const Key('recognition-start')));
          expect(fixture.capture.requests, isEmpty);
          expect(fixture.repository.calls, 0);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets(
    'explicit microphone start shows countdown, upload phase and cancellation',
    (tester) async {
      await _withRecognition(
        tester,
        run: (fixture) async {
          expect(fixture.service.source.value, MusicCaptureSource.loopback);
          await _tap(
            tester,
            find.byKey(const Key('recognition-source-microphone')),
          );
          expect(fixture.capture.requests, isEmpty);
          await _tap(tester, find.byKey(const Key('recognition-start')));
          expect(fixture.capture.requests.single, (
            MusicCaptureSource.microphone,
            const Duration(seconds: 12),
          ));
          await tester.pump(const Duration(seconds: 3));
          expect(find.text('正在采样，还剩 9 秒…'), findsOneWidget);
          expect(
            tester
                .widget<ChoiceChip>(
                  find.byKey(const Key('recognition-source-loopback')),
                )
                .onSelected,
            isNull,
          );
          await _upload(tester, fixture);
          expect(find.text('正在发送至识曲服务并识别歌曲…'), findsOneWidget);
          expect(fixture.repository.calls, 1);
          await _tap(tester, find.byKey(const Key('recognition-cancel')));
          expect(fixture.repository.cancellation!.isCancelled, isTrue);
          expect(fixture.capture.cancelCalls, 1);
          expect(fixture.service.phase.value, RecognitionPhase.idle);
          expect(fixture.service.result.value, isNull);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets(
    'one click starts recognition, no match can retry and results only copy or search',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _withRecognition(
        tester,
        run: (fixture) async {
          expect(find.byType(TextField), findsNothing);
          expect(find.textContaining('Token'), findsNothing);
          expect(fixture.capture.requests, isEmpty);
          await _tap(tester, find.byKey(const Key('recognition-start')));
          expect(fixture.capture.requests.single, (
            MusicCaptureSource.loopback,
            const Duration(seconds: 12),
          ));
          await _upload(tester, fixture);
          fixture.repository.pending!.complete(null);
          await tester.pump();
          expect(find.byKey(const Key('recognition-no-match')), findsOneWidget);
          expect(find.text('再试一次'), findsOneWidget);
          await _tap(tester, find.byKey(const Key('recognition-start')));
          await _upload(tester, fixture);
          fixture.repository.pending!.complete(_match);
          await tester.pump();
          expect(
            tester
                .widget<SelectableText>(
                  find.byKey(const Key('recognition-title')),
                )
                .data,
            '夜航',
          );
          expect(
            tester
                .widget<SelectableText>(
                  find.byKey(const Key('recognition-artist')),
                )
                .data,
            '测试歌手',
          );
          expect(
            tester
                .widget<SelectableText>(
                  find.byKey(const Key('recognition-album')),
                )
                .data,
            '夜色专辑',
          );
          expect(
            tester
                .widget<SelectableText>(
                  find.byKey(const Key('recognition-date')),
                )
                .data,
            '2026-01-01',
          );
          await _tap(tester, find.byKey(const Key('recognition-copy-title')));
          expect(copied, '夜航');
          await _tap(
            tester,
            find.byKey(const Key('recognition-search-library')),
          );
          await _tap(
            tester,
            find.byKey(const Key('recognition-search-online')),
          );
          expect(fixture.libraryQueries, ['夜航']);
          expect(fixture.onlineQueries, ['夜航']);
          expect(fixture.capture.requests, hasLength(2));
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets(
    'capture failure is readable and host or service exit gates block stale actions',
    (tester) async {
      await _withRecognition(
        tester,
        run: (fixture) async {
          fixture.allowed = false;
          await _tap(tester, find.byKey(const Key('recognition-start')));
          expect(fixture.capture.requests, isEmpty);
          fixture.allowed = true;
          await fixture.service.beginExit();
          await _tap(tester, find.byKey(const Key('recognition-start')));
          expect(fixture.capture.requests, isEmpty);
          fixture.service.cancelExit();
          // Exit availability itself is observable; no unrelated action is
          // needed to make the controls usable again.
          await tester.pump();
          await tester.pump();
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('recognition-start')),
                )
                .onPressed,
            isNotNull,
          );
          await _tap(tester, find.byKey(const Key('recognition-start')));
          fixture.capture.pending!.completeError(
            const MusicRecognitionException('没有可用的麦克风。'),
          );
          await tester.pump();
          expect(find.text('没有可用的麦克风。'), findsOneWidget);
          expect(find.text('再试一次'), findsOneWidget);
          expect(fixture.repository.calls, 0);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  for (final uploading in [false, true]) {
    testWidgets(
      'leaving during ${uploading ? 'upload' : 'capture'} cancels and ignores late results',
      (tester) async {
        await _withRecognition(
          tester,
          run: (fixture) async {
            await _tap(tester, find.byKey(const Key('recognition-start')));
            if (uploading) await _upload(tester, fixture);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
            expect(fixture.capture.cancelCalls, 1);
            if (uploading) {
              expect(fixture.repository.cancellation!.isCancelled, isTrue);
              fixture.repository.pending!.complete(_match);
              await tester.pump();
            }
            expect(fixture.service.result.value, isNull);
            expect(fixture.service.isBusy, isFalse);
            expect(tester.takeException(), isNull);
          },
        );
      },
    );
  }

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
      '${brightness.name} recognition remains scrollable at 800x600 and 200 percent text',
      (tester) async {
        await _withRecognition(
          tester,
          brightness: brightness,
          size: const Size(800, 600),
          scale: 2,
          run: (fixture) async {
            await _tap(tester, find.byKey(const Key('recognition-start')));
            await _upload(tester, fixture);
            fixture.repository.pending!.complete(_match);
            await tester.pump();
            for (final key in [
              'recognition-title',
              'recognition-date',
              'recognition-copy-title',
              'recognition-search-library',
              'recognition-search-online',
            ]) {
              final finder = find.byKey(Key(key));
              await tester.ensureVisible(finder);
              await tester.pump();
              expect(finder.hitTestable(), findsOneWidget);
            }
            expect(tester.takeException(), isNull);
          },
        );
      },
    );
  }
}

final _match = MusicRecognitionResult(
  title: '夜航',
  artist: '测试歌手',
  album: '夜色专辑',
  releaseDate: '2026-01-01',
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _upload(WidgetTester tester, _Fixture fixture) async {
  fixture.capture.pending!.complete(Uint8List(44));
  await tester.pump();
  expect(fixture.service.phase.value, RecognitionPhase.recognizing);
  // The phase can settle in a microtask after the first frame's rebuild.
  await tester.pump();
}

Future<void> _withRecognition(
  WidgetTester tester, {
  required Future<void> Function(_Fixture) run,
  bool available = true,
  Brightness brightness = Brightness.light,
  Size size = const Size(1280, 800),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fixture = _Fixture(available: available);
  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.dark
            ? HanMusicTheme.dark
            : HanMusicTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: RecognitionPage(
            service: fixture.service,
            canOperate: () => fixture.allowed,
            onSearchLibrary: fixture.libraryQueries.add,
            onSearchOnline: fixture.onlineQueries.add,
          ),
        ),
      ),
    );
    await tester.pump();
    await run(fixture);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await fixture.service.close();
  }
}

class _Fixture {
  _Fixture({required bool available})
    : repository = _Repository(available: available);
  final capture = _Capture();
  final _Repository repository;
  late final service = MusicRecognitionService(
    capture: capture,
    repository: repository,
  );
  bool allowed = true;
  final libraryQueries = <String>[];
  final onlineQueries = <String>[];
}

class _Capture implements MusicCapture {
  final requests = <(MusicCaptureSource, Duration)>[];
  Completer<Uint8List>? pending;
  int cancelCalls = 0;

  @override
  Future<Uint8List> capture({
    required MusicCaptureSource source,
    required Duration duration,
  }) {
    requests.add((source, duration));
    pending = Completer<Uint8List>();
    return pending!.future;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    if (pending != null && !pending!.isCompleted) {
      pending!.completeError(
        const MusicRecognitionException('已取消识曲。', cancelled: true),
      );
    }
  }
}

class _Repository extends MusicRecognitionRepository {
  _Repository({this.available = true});
  final bool available;
  @override
  bool get isConfigured => available;
  int calls = 0;
  RecognitionCancellation? cancellation;
  Completer<MusicRecognitionResult?>? pending;

  @override
  Future<MusicRecognitionResult?> recognize({
    required Uint8List audio,
    required RecognitionCancellation cancellation,
  }) {
    calls++;
    this.cancellation = cancellation;
    pending = Completer<MusicRecognitionResult?>();
    return Future.any([
      pending!.future,
      cancellation.whenCancelled.then<MusicRecognitionResult?>(
        (_) => throw const MusicRecognitionException('已取消识曲。', cancelled: true),
      ),
    ]);
  }
}
