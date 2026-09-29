import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/core/theme/app_theme.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/modules/player/view.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

import 'support/fake_audio_backend.dart';

final _song = Song(
  uri: Uri.file(r'D:\音乐\测试歌曲 空格与中文.flac', windows: true),
  fileName: '测试歌曲 空格与中文.flac',
);

void main() {
  for (final configuration in [
    (size: const Size(1280, 720), scale: 1.0),
    (size: const Size(800, 600), scale: 1.0),
    (size: const Size(800, 600), scale: 1.5),
  ]) {
    testWidgets(
      'empty and loaded layout ${configuration.size} at ${configuration.scale} text scale',
      (tester) async {
        await _withPlayer(
          tester,
          size: configuration.size,
          textScale: configuration.scale,
          run: (fixture) async {
            expect(find.text('从一首歌开始'), findsOneWidget);
            expect(tester.widget<IconButton>(_playButton).onPressed, isNull);
            expect(tester.takeException(), isNull);

            await fixture.player.open(_song);
            await tester.pumpAndSettle();
            expect(find.text(_song.title), findsOneWidget);
            expect(tester.widget<IconButton>(_playButton).onPressed, isNotNull);
            expect(tester.takeException(), isNull);

            await tester.ensureVisible(_timerButton);
            await tester.pumpAndSettle();
            expect(find.text('睡眠定时'), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      },
    );
  }

  testWidgets(
    'cancelled import preserves empty state, import enables playback',
    (tester) async {
      await _withPlayer(
        tester,
        run: (fixture) async {
          await tester.tap(_importButton);
          await tester.pumpAndSettle();
          expect(fixture.picker.calls, 1);
          expect(fixture.player.currentSong.value, isNull);
          expect(find.text('从一首歌开始'), findsOneWidget);

          fixture.picker.next = _song;
          await tester.tap(_importButton);
          await tester.pumpAndSettle();
          expect(fixture.picker.calls, 2);
          expect(fixture.player.currentSong.value, _song);
          expect(fixture.player.isPlaying.value, isTrue);

          await tester.ensureVisible(_playButton);
          await tester.tap(_playButton);
          await tester.pumpAndSettle();
          expect(fixture.player.isPlaying.value, isFalse);
          expect(tester.widget<IconButton>(_playButton).tooltip, '播放');

          await tester.tap(_playButton);
          await tester.pumpAndSettle();
          expect(fixture.player.isPlaying.value, isTrue);
          expect(tester.widget<IconButton>(_playButton).tooltip, '暂停');
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets(
    'custom sleep timer validates input, starts, and can be cancelled',
    (tester) async {
      await _withPlayer(
        tester,
        run: (fixture) async {
          await tester.ensureVisible(_timerButton);
          await tester.tap(_timerButton);
          await tester.pumpAndSettle();
          final input = find.byKey(const Key('sleep-timer-minutes'));
          final confirm = find.byKey(const Key('sleep-timer-confirm'));

          await tester.enterText(input, '0');
          await tester.tap(confirm);
          await tester.pumpAndSettle();
          expect(find.text('请输入大于 0 的整数分钟'), findsOneWidget);
          expect(fixture.timer.remaining.value, isNull);

          await tester.enterText(input, '7');
          await tester.tap(confirm);
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(fixture.timer.remaining.value, const Duration(minutes: 7));
          expect(find.text('07:00 后停止播放'), findsOneWidget);

          // File selection and loading must never lock the timer cancellation.
          fixture.controller.isImporting.value = true;
          fixture.player.isLoading.value = true;
          await tester.pump();
          final cancel = find.byKey(const Key('sleep-timer-cancel'));
          await tester.ensureVisible(cancel);
          await tester.tap(cancel);
          await tester.pump();
          expect(fixture.timer.remaining.value, isNull);
          expect(cancel, findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets('preset timer can be started and dismissed without changes', (
    tester,
  ) async {
    await _withPlayer(
      tester,
      run: (fixture) async {
        await tester.ensureVisible(_timerButton);
        await tester.tap(_timerButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('15 分钟'));
        await tester.tap(find.byKey(const Key('sleep-timer-confirm')));
        await tester.pumpAndSettle();
        expect(fixture.timer.remaining.value, const Duration(minutes: 15));

        await tester.tap(_timerButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('暂不设置'));
        await tester.pumpAndSettle();
        expect(fixture.timer.remaining.value, const Duration(minutes: 15));
        expect(tester.takeException(), isNull);
      },
    );
  });

  testWidgets('error notice can be dismissed', (tester) async {
    await _withPlayer(
      tester,
      run: (fixture) async {
        const message = '无法播放此文件，请检查文件是否损坏或已被移动。';
        fixture.player.errorMessage.value = message;
        await tester.pumpAndSettle();
        expect(find.text(message), findsOneWidget);
        await tester.tap(find.byTooltip('关闭提示'));
        await tester.pumpAndSettle();
        expect(fixture.player.errorMessage.value, isNull);
        expect(find.text(message), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  testWidgets('loading state disables import, playback, and seeking', (
    tester,
  ) async {
    await _withPlayer(
      tester,
      size: const Size(800, 600),
      run: (fixture) async {
        final gate = Completer<Duration?>();
        fixture.backend.loadCompleter = gate;
        final loading = fixture.player.open(_song);
        try {
          await tester.pump();
          expect(find.text('正在准备音乐…'), findsOneWidget);
          expect(tester.widget<FilledButton>(_importButton).onPressed, isNull);
          expect(tester.widget<IconButton>(_playButton).onPressed, isNull);
          expect(
            tester
                .widget<Slider>(find.byKey(const Key('seek-slider')))
                .onChanged,
            isNull,
          );
          expect(tester.takeException(), isNull);
        } finally {
          gate.complete(const Duration(minutes: 3));
          await loading;
        }
      },
    );
  });

  testWidgets('seek previews while dragging and commits only on release', (
    tester,
  ) async {
    await _withPlayer(
      tester,
      run: (fixture) async {
        await fixture.player.open(_song);
        await tester.pumpAndSettle();
        final slider = find.byKey(const Key('seek-slider'));
        await tester.ensureVisible(slider);
        final bounds = tester.getRect(slider);
        final gesture = await tester.startGesture(
          Offset(bounds.left + bounds.width * .25, bounds.center.dy),
        );
        await gesture.moveBy(Offset(bounds.width * .25, 0));
        await tester.pump();
        expect(fixture.backend.seekPositions, isEmpty);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(fixture.backend.seekPositions, hasLength(1));
        expect(
          fixture.backend.seekPositions.single,
          greaterThan(Duration.zero),
        );
        expect(tester.takeException(), isNull);
      },
    );
  });
}

final _importButton = find.byKey(const Key('import-file'));
final _playButton = find.byKey(const Key('toggle-playback'));
final _timerButton = find.byKey(const Key('sleep-timer-open'));

Future<void> _withPlayer(
  WidgetTester tester, {
  required Future<void> Function(_Fixture fixture) run,
  Size size = const Size(1280, 720),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final fixture = _Fixture();
  fixture.controller.onInit();
  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: HanMusicTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: PlayerPage(controller: fixture.controller),
      ),
    );
    await tester.pumpAndSettle();
    await run(fixture);
  } finally {
    fixture.timer.onClose();
    fixture.controller.onClose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.player.shutdown);
    await tester.pump();
  }
}

class _Fixture {
  _Fixture() {
    player = PlayerService(backend);
    timer = TimerService(
      onExpired: player.pause,
      now: () => DateTime(2026, 9, 29, 20),
    );
    controller = PlayerController(player: player, timer: timer, picker: picker);
  }

  final backend = FakeAudioBackend();
  final picker = _FakeSongPicker();
  late final PlayerService player;
  late final TimerService timer;
  late final PlayerController controller;
}

class _FakeSongPicker implements SongPicker {
  Song? next;
  int calls = 0;

  @override
  Future<Song?> pick() async {
    calls++;
    return next;
  }
}
