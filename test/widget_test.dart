import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/core/theme/app_theme.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/models/sleep_timer_mode.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/modules/player/view.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';
import 'package:han_music/app/services/sleep_timer_coordinator.dart';

import 'support/fake_audio_backend.dart';

final _song = Song(
  uri: Uri.file(r'D:\音乐\测试歌曲 空格与中文.flac', windows: true),
  fileName: '测试歌曲 空格与中文.flac',
);

void main() {
  testWidgets(
    'custom sleep timer rejects oversized integers and accepts 24 hours',
    (tester) async {
      await _withPlayer(
        tester,
        withLibrary: true,
        run: (fixture) async {
          fixture.controller.startSleepTimer(const Duration(minutes: 15));
          await tester.pumpAndSettle();
          await tester.tap(_timerButton);
          await tester.pumpAndSettle();
          final input = find.byKey(const Key('sleep-timer-minutes'));
          final confirm = find.byKey(const Key('sleep-timer-confirm'));
          for (final value in [
            '1441',
            '9223372036854775807',
            '999999999999999999999999999999999999',
          ]) {
            await tester.ensureVisible(input);
            await tester.enterText(input, value);
            await tester.tap(confirm);
            await tester.pumpAndSettle();
            expect(find.text('请输入 1–1440 的整数分钟'), findsOneWidget);
            expect(fixture.timer.remaining.value, const Duration(minutes: 15));
            expect(tester.takeException(), isNull);
          }
          await tester.enterText(input, '1440');
          await tester.tap(confirm);
          await tester.pumpAndSettle();
          expect(fixture.timer.remaining.value, const Duration(hours: 24));
          expect(find.byType(AlertDialog), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets(
    'sleep timer modes, extension and cancellation fit compact large text',
    (tester) async {
      await _withPlayer(
        tester,
        withLibrary: true,
        size: const Size(800, 600),
        textScale: 1.5,
        run: (fixture) async {
          await tester.tap(_timerButton);
          await tester.pumpAndSettle();
          final endTrack = find.byKey(const Key('sleep-timer-end-track'));
          expect(tester.widget<ChoiceChip>(endTrack).onSelected, isNull);
          await tester.tap(find.text('暂不设置'));
          await tester.pumpAndSettle();
          fixture.library!.replaceAll(_librarySongs(2));
          await fixture.controller.playLibrarySong(
            fixture.library!.songs.first,
          );
          await tester.pumpAndSettle();
          await tester.tap(_timerButton);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('90 分钟'));
          await tester.tap(find.text('90 分钟'));
          await tester.tap(find.byKey(const Key('sleep-timer-confirm')));
          await tester.pumpAndSettle();
          expect(fixture.timer.remaining.value, const Duration(minutes: 90));
          expect(find.text('1:30:00'), findsOneWidget);
          expect(tester.getRect(_timerButton).bottom, lessThan(600));

          await tester.tap(_timerButton);
          await tester.pumpAndSettle();
          final extend = find.byKey(const Key('sleep-timer-dialog-extend'));
          await tester.ensureVisible(extend);
          await tester.tap(extend);
          await tester.pumpAndSettle();
          expect(fixture.timer.remaining.value, const Duration(minutes: 100));
          await tester.ensureVisible(endTrack);
          await tester.tap(endTrack);
          await tester.tap(find.byKey(const Key('sleep-timer-confirm')));
          await tester.pumpAndSettle();
          expect(fixture.timer.mode.value, SleepTimerMode.endOfTrack);
          expect(fixture.timer.remaining.value, isNull);
          expect(find.text('本曲结束'), findsOneWidget);
          expect(find.text('1:40:00'), findsNothing);
          expect(tester.takeException(), isNull);

          await tester.tap(_timerButton);
          await tester.pumpAndSettle();
          expect(extend, findsNothing);
          final cancel = find.byKey(const Key('sleep-timer-dialog-cancel'));
          await tester.ensureVisible(cancel);
          await tester.tap(cancel);
          await tester.pumpAndSettle();
          expect(fixture.timer.mode.value, SleepTimerMode.off);
          expect(find.byType(AlertDialog), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets('expired timer shows completion and cannot be extended', (
    tester,
  ) async {
    await _withPlayer(
      tester,
      withLibrary: true,
      run: (fixture) async {
        await fixture.player.open(_song);
        fixture.controller.startSleepTimer(const Duration(minutes: 1));
        fixture.now = fixture.now.add(const Duration(minutes: 2));
        fixture.controller.didChangeAppLifecycleState(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(fixture.player.isPlaying.value, isFalse);
        await tester.tap(_timerButton);
        await tester.pumpAndSettle();
        expect(find.text('定时已停止播放'), findsOneWidget);
        expect(
          find.byKey(const Key('sleep-timer-dialog-extend')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  });

  for (final configuration in [
    (size: const Size(1280, 720), scale: 1.0),
    (size: const Size(800, 600), scale: 1.0),
    (size: const Size(800, 600), scale: 1.5),
    (size: const Size(1280, 720), scale: 2.0),
    (size: const Size(800, 600), scale: 2.0),
  ]) {
    testWidgets(
      'library, queue and fixed controls fit ${configuration.size} scale ${configuration.scale}',
      (tester) async {
        await _withPlayer(
          tester,
          withLibrary: true,
          size: configuration.size,
          textScale: configuration.scale,
          run: (fixture) async {
            expect(find.text('把喜欢的音乐收进曲库'), findsOneWidget);
            expect(tester.takeException(), isNull);
            fixture.library!.replaceAll(_librarySongs(12));
            await tester.pumpAndSettle();
            await tester.tap(find.text('测试曲目 00000'));
            await tester.pumpAndSettle();
            expect(fixture.player.queue, hasLength(12));
            expect(fixture.player.isPlaying.value, isTrue);
            final playRect = tester.getRect(_playButton);
            expect(playRect.bottom, lessThan(configuration.size.height));
            expect(tester.takeException(), isNull);
            await tester.tap(find.byKey(const Key('nav-2')));
            await tester.pumpAndSettle();
            expect(find.byKey(const Key('queue-list')), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.tap(find.byKey(const Key('nav-1')));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
        );
      },
    );
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'long jumps bound materialized rows and preserve extent at $scale',
      (tester) async {
        await _withPlayer(
          tester,
          withLibrary: true,
          textScale: scale,
          run: (fixture) async {
            fixture.library!.replaceAll(_librarySongs(10000));
            await tester.pumpAndSettle();
            final list = find.byKey(const Key('library-list'));
            final scrollable = find.descendant(
              of: list,
              matching: find.byType(Scrollable),
            );
            final position = tester.state<ScrollableState>(scrollable).position;
            final extent = tester.widget<ListView>(list).itemExtent!;
            final visibleRows = (position.viewportDimension / extent).ceil();
            final rows = find.byWidgetPredicate(
              (widget) =>
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'library-song-',
                  ),
            );
            for (final fraction in [.9, .1, .8, .2, 1.0, 0.0]) {
              position.jumpTo(position.maxScrollExtent * fraction);
              await tester.pumpAndSettle();
              // Keep construction bounded to the viewport and a few edge rows.
              expect(
                rows.evaluate().length,
                lessThanOrEqualTo(visibleRows + 4),
              );
              final built = rows
                  .evaluate()
                  .take(2)
                  .map((element) => find.byWidget(element.widget))
                  .toList();
              expect(
                (tester.getRect(built[1]).top - tester.getRect(built[0]).top)
                    .abs(),
                closeTo(extent, .01),
              );
              expect(_playButton.hitTestable(), findsOneWidget);
              expect(tester.takeException(), isNull);
            }
            await tester.tap(find.byTooltip('测试曲目 00000的操作'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('加入播放队列'));
            await tester.pumpAndSettle();
            expect(
              fixture.player.queue.single.id,
              fixture.library!.songs.first.id,
            );
            expect(tester.takeException(), isNull);
          },
        );
      },
    );
  }

  testWidgets(
    'library row right click opens the same actions at the pointer',
    (tester) async {
      await _withPlayer(
        tester,
        withLibrary: true,
        run: (fixture) async {
          final songs = _librarySongs(2);
          songs[1] = songs[1].copyWith(isMissing: true);
          fixture.library!.replaceAll(songs);
          await tester.pumpAndSettle();

          final point = tester.getCenter(find.text(songs[0].title));
          await tester.tapAt(
            point,
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          final queueAction = find.text('加入播放队列');
          expect(queueAction, findsOneWidget);
          expect(
            (tester.getTopLeft(queueAction).dx - point.dx).abs(),
            lessThan(96),
          );
          expect(fixture.backend.playCalls, 0);
          await tester.tap(queueAction);
          await tester.pumpAndSettle();
          expect(fixture.player.queue.map((song) => song.id), [songs[0].id]);
          expect(fixture.backend.playCalls, 0);

          await tester.tapAt(
            tester.getCenter(find.text(songs[1].title)),
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          final disabledQueue = tester.widget<PopupMenuItem<String>>(
            find.ancestor(
              of: find.text('加入播放队列'),
              matching: find.byType(PopupMenuItem<String>),
            ),
          );
          expect(disabledQueue.enabled, isFalse);
          await tester.tap(find.text('从曲库移除（保留文件）'));
          await tester.pumpAndSettle();
          expect(find.text('从曲库移除？'), findsOneWidget);
          await tester.tap(find.text('保留'));
          await tester.pumpAndSettle();
          expect(fixture.library!.songs, hasLength(2));

          await tester.tap(find.byTooltip('${songs[0].title}的操作'));
          await tester.pumpAndSettle();
          expect(find.text('加入播放队列'), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          final menu = find.byTooltip('${songs[0].title}的操作');
          for (var step = 0; step < 100 && !_primaryFocusWithin(menu); step++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pumpAndSettle();
          }
          expect(_primaryFocusWithin(menu), isTrue);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.text('加入播放队列'), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: find.byKey(ValueKey('library-song-${songs[0].id}')),
              matching: find.text(songs[0].title),
            ),
          );
          await tester.pumpAndSettle();
          expect(fixture.backend.playCalls, 1);
          expect(tester.takeException(), isNull);
        },
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  for (final configuration in [
    (size: const Size(1280, 720), scale: 1.0),
    (size: const Size(800, 600), scale: 2.0),
  ]) {
    testWidgets(
      'library artwork and accessible actions survive wheel recycling at ${configuration.size} scale ${configuration.scale}',
      (tester) async {
        final captureKey = GlobalKey();
        final artwork = (await tester.runAsync(() async {
          final base = Directory(r'D:\dev\tmp\hanmusic-widget-artwork');
          await base.create(recursive: true);
          final directory = await base.createTemp('paint-');
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawColor(const Color(0xFFBE3456), BlendMode.src);
          final picture = recorder.endRecording();
          final image = await picture.toImage(8, 8);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final valid = File('${directory.path}/valid.png');
            final invalid = File('${directory.path}/invalid.png');
            await valid.writeAsBytes(bytes!.buffer.asUint8List());
            await invalid.writeAsBytes([0, 1, 2, 3]);
            return (directory: directory, valid: valid, invalid: invalid);
          } finally {
            image.dispose();
            picture.dispose();
          }
        }))!;
        final semantics = tester.ensureSemantics();
        try {
          await _withPlayer(
            tester,
            withLibrary: true,
            size: configuration.size,
            textScale: configuration.scale,
            captureKey: captureKey,
            run: (fixture) async {
              final songs = _librarySongs(20);
              songs[0] = songs[0].copyWith(artworkPath: artwork.valid.path);
              songs[1] = songs[1].copyWith(artworkPath: artwork.invalid.path);
              songs[2] = songs[2].copyWith(isMissing: true);
              // Start real FileImage IO outside FakeAsync; waiting on a stream
              // whose File.open began in the fake zone cannot drain that IO.
              await tester.runAsync(() async {
                fixture.library!.replaceAll(songs);
                await tester.pump();
              });
              await tester.pumpAndSettle();
              final list = find.byKey(const Key('library-list'));
              final position = tester
                  .state<ScrollableState>(
                    find.descendant(
                      of: list,
                      matching: find.byType(Scrollable),
                    ),
                  )
                  .position;
              final extent = tester.widget<ListView>(list).itemExtent!;
              Finder row(int index) =>
                  find.byKey(ValueKey('library-song-${songs[index].id}'));

              Future<void> wheelTo(int index) async {
                final target = extent * index;
                for (
                  var step = 0;
                  step < 60 && (position.pixels - target).abs() > .01;
                  step++
                ) {
                  final delta = (target - position.pixels).clamp(
                    -extent / 3,
                    extent / 3,
                  );
                  await tester.runAsync(() async {
                    await tester.sendEventToBinding(
                      PointerScrollEvent(
                        position: tester.getCenter(list),
                        scrollDelta: Offset(0, delta),
                      ),
                    );
                    await tester.pump();
                  });
                  await tester.pumpAndSettle();
                }
                expect(position.pixels, closeTo(target, .01));
              }

              Future<void> checkCover(int index) async {
                await wheelTo(index);
                final image = find.descendant(
                  of: row(index),
                  matching: find.byType(Image),
                );
                expect(await _waitForArtwork(tester, image), index == 0);
                await tester.pumpAndSettle();
                final bounds = tester.getRect(image);
                final pixels = await _capturePagePixels(tester, captureKey);
                // Sample inside the cover, away from its rounded edge and the
                // fallback music glyph. This checks actual image/fallback paint.
                expect(
                  pixels.colorAt(Offset(bounds.left + 4, bounds.center.dy)),
                  index == 0
                      ? const Color(0xFFBE3456)
                      : const Color(0xFFE0EAD6),
                );
                expect(tester.takeException(), isNull);
              }

              await checkCover(0);
              await checkCover(1);
              await wheelTo(5);
              expect(row(0), findsNothing);
              expect(row(1), findsNothing);
              await checkCover(0);
              await checkCover(1);
              await wheelTo(0);

              final titleNode = tester.getSemantics(find.text(songs[0].title));
              expect(
                titleNode.getSemanticsData().label,
                contains(songs[0].title),
              );
              expect(
                titleNode.getSemanticsData().hasAction(ui.SemanticsAction.tap),
                isTrue,
              );
              final menu = find.byTooltip('${songs[0].title}的操作');
              final menuNode = tester.getSemantics(menu);
              expect(menuNode.flagsCollection.isButton, isTrue);
              menuNode.owner!.performAction(
                menuNode.id,
                ui.SemanticsAction.tap,
              );
              await tester.pumpAndSettle();
              final queueNode = tester.getSemantics(find.text('加入播放队列'));
              queueNode.owner!.performAction(
                queueNode.id,
                ui.SemanticsAction.tap,
              );
              await tester.pumpAndSettle();
              expect(fixture.player.queue.map((song) => song.id), [
                songs[0].id,
              ]);
              expect(fixture.backend.playCalls, 0);

              await wheelTo(2);
              await tester.tap(find.text(songs[2].title));
              await tester.pumpAndSettle();
              expect(fixture.backend.playCalls, 0);
              await tester.tap(find.byTooltip('${songs[2].title}的操作'));
              await tester.pumpAndSettle();
              final unavailable = tester.getSemantics(find.text('加入播放队列'));
              expect(
                unavailable.flagsCollection.isEnabled,
                ui.Tristate.isFalse,
              );
              final remove = tester.getSemantics(find.text('从曲库移除（保留文件）'));
              expect(
                remove.getSemanticsData().hasAction(ui.SemanticsAction.tap),
                isTrue,
              );
              remove.owner!.performAction(remove.id, ui.SemanticsAction.tap);
              await tester.pumpAndSettle();
              expect(find.text('从曲库移除？'), findsOneWidget);
              await tester.tap(find.text('保留'));
              await tester.pumpAndSettle();
              expect(fixture.library!.songs, hasLength(20));
              expect(_playButton.hitTestable(), findsOneWidget);
              expect(tester.takeException(), isNull);
            },
          );
        } finally {
          semantics.dispose();
          await tester.runAsync(() async {
            for (final file in [artwork.valid, artwork.invalid]) {
              await ResizeImage.resizeIfNeeded(
                44,
                null,
                FileImage(file),
              ).evict();
            }
            await artwork.directory.delete(recursive: true);
          });
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'library missing recovery preserves artwork focus and semantics at ${configuration.size} scale ${configuration.scale}',
      (tester) async {
        final captureKey = GlobalKey();
        const coverColor = Color(0xFFBE3456);
        final artwork = (await tester.runAsync(() async {
          final base = Directory(r'D:\dev\tmp\hanmusic-widget-artwork');
          await base.create(recursive: true);
          final directory = await base.createTemp('missing-transition-');
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawColor(coverColor, BlendMode.src);
          final picture = recorder.endRecording();
          final image = await picture.toImage(8, 8);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File('${directory.path}/cover.png');
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            return (directory: directory, file: file);
          } finally {
            image.dispose();
            picture.dispose();
          }
        }))!;
        final semantics = tester.ensureSemantics();
        try {
          await _withPlayer(
            tester,
            withLibrary: true,
            size: configuration.size,
            textScale: configuration.scale,
            captureKey: captureKey,
            run: (fixture) async {
              final songs = _librarySongs(10);
              songs[0] = songs[0].copyWith(artworkPath: artwork.file.path);
              final target = songs.first;
              final row = find.byKey(ValueKey('library-song-${target.id}'));
              final neighbor = find.byKey(
                ValueKey('library-song-${songs[1].id}'),
              );
              final title = find.descendant(
                of: row,
                matching: find.text(target.title),
              );
              final cover = find.descendant(
                of: row,
                matching: find.byType(Image),
              );
              final menu = find.byTooltip('${target.title}的操作');
              Future<void> setMissing(bool missing) async {
                // Exercise the real service update; no filesystem/picker claim.
                await tester.runAsync(() async {
                  fixture.library!.replaceAll([
                    target.copyWith(isMissing: missing),
                    ...songs.skip(1),
                  ]);
                  await tester.pump();
                });
                expect(await _waitForArtwork(tester, cover), isTrue);
                await tester.pumpAndSettle();
              }

              await setMissing(false);
              for (var step = 0; step < 100; step++) {
                await tester.sendKeyEvent(LogicalKeyboardKey.tab);
                await tester.pumpAndSettle();
                if (_primaryFocusWithin(menu)) break;
              }
              expect(_primaryFocusWithin(menu), isTrue);
              // The menu remains enabled when playback becomes unavailable.
              final focus = FocusManager.instance.primaryFocus;
              final rowBounds = tester.getRect(row);
              final neighborBounds = tester.getRect(neighbor);
              final coverPoint = tester.getCenter(cover);
              final titleBounds = tester.getRect(title);
              final normal = await _capturePagePixels(tester, captureKey);
              expect(normal.colorAt(coverPoint), coverColor);
              expect(
                tester
                    .getSemantics(title)
                    .getSemanticsData()
                    .hasAction(ui.SemanticsAction.tap),
                isTrue,
              );

              await setMissing(true);
              expect(FocusManager.instance.primaryFocus, same(focus));
              expect(_primaryFocusWithin(menu), isTrue);
              expect(tester.getRect(row), rowBounds);
              expect(tester.getRect(neighbor), neighborBounds);
              expect(find.text('文件缺失 · 可检查或移除索引'), findsOneWidget);
              final missing = await _capturePagePixels(tester, captureKey);
              expect(missing.colorAt(coverPoint), isNot(coverColor));
              expect(
                normal.changedPixels(missing, titleBounds),
                greaterThan(0),
              );
              expect(
                tester
                    .getSemantics(title)
                    .getSemanticsData()
                    .hasAction(ui.SemanticsAction.tap),
                isFalse,
              );
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await tester.pumpAndSettle();
              expect(
                tester
                    .getSemantics(find.text('加入播放队列'))
                    .flagsCollection
                    .isEnabled,
                ui.Tristate.isFalse,
              );
              expect(
                tester
                    .getSemantics(find.text('从曲库移除（保留文件）'))
                    .getSemanticsData()
                    .hasAction(ui.SemanticsAction.tap),
                isTrue,
              );
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await tester.pumpAndSettle();
              expect(FocusManager.instance.primaryFocus, same(focus));
              expect(fixture.backend.playCalls, 0);

              await setMissing(false);
              expect(FocusManager.instance.primaryFocus, same(focus));
              expect(_primaryFocusWithin(menu), isTrue);
              expect(tester.getRect(row), rowBounds);
              expect(tester.getRect(neighbor), neighborBounds);
              final restored = await _capturePagePixels(tester, captureKey);
              expect(restored.colorAt(coverPoint), coverColor);
              expect(normal.changedPixels(restored, titleBounds), 0);
              final restoredTitle = tester.getSemantics(title);
              expect(
                restoredTitle.getSemanticsData().label,
                contains(target.title),
              );
              expect(
                restoredTitle.getSemanticsData().hasAction(
                  ui.SemanticsAction.tap,
                ),
                isTrue,
              );

              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await tester.pumpAndSettle();
              final queueAction = tester.getSemantics(find.text('加入播放队列'));
              expect(queueAction.flagsCollection.isEnabled, ui.Tristate.isTrue);
              queueAction.owner!.performAction(
                queueAction.id,
                ui.SemanticsAction.tap,
              );
              await tester.pumpAndSettle();
              expect(fixture.player.queue.map((song) => song.id), [target.id]);
              expect(fixture.backend.playCalls, 0);
              final playAction = tester.getSemantics(title);
              playAction.owner!.performAction(
                playAction.id,
                ui.SemanticsAction.tap,
              );
              await tester.pumpAndSettle();
              expect(fixture.backend.loadedUris, [target.uri]);
              expect(fixture.player.currentSong.value?.id, target.id);
              expect(tester.takeException(), isNull);
            },
          );
        } finally {
          semantics.dispose();
          await tester.runAsync(() async {
            await ResizeImage.resizeIfNeeded(
              44,
              null,
              FileImage(artwork.file),
            ).evict();
            final resolvedBase = await Directory(
              r'D:\dev\tmp\hanmusic-widget-artwork',
            ).resolveSymbolicLinks();
            final resolvedDirectory = Directory(
              await artwork.directory.resolveSymbolicLinks(),
            );
            if (resolvedDirectory.parent.path.toLowerCase() !=
                resolvedBase.toLowerCase()) {
              throw StateError('Artwork cleanup escaped its temporary base.');
            }
            await resolvedDirectory.delete(recursive: true);
          });
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'small wheel steps and reverse scrolling preserve row actions at ${configuration.size} scale ${configuration.scale}',
      (tester) async {
        await _withPlayer(
          tester,
          withLibrary: true,
          size: configuration.size,
          textScale: configuration.scale,
          run: (fixture) async {
            final songs = _librarySongs(40);
            fixture.library!.replaceAll(songs);
            await tester.pumpAndSettle();
            final list = find.byKey(const Key('library-list'));
            final scrollable = find.descendant(
              of: list,
              matching: find.byType(Scrollable),
            );
            final position = tester.state<ScrollableState>(scrollable).position;
            final extent = tester.widget<ListView>(list).itemExtent!;

            Future<void> wheelSteps(double direction) async {
              for (var step = 0; step < 12; step++) {
                final before = position.pixels;
                await tester.sendEventToBinding(
                  PointerScrollEvent(
                    position: tester.getCenter(list),
                    scrollDelta: Offset(0, direction * extent / 3),
                  ),
                );
                await tester.pumpAndSettle();
                expect(
                  position.pixels - before,
                  closeTo(direction * extent / 3, .01),
                );
                expect(_playButton.hitTestable(), findsOneWidget);
                expect(tester.takeException(), isNull);
              }
            }

            await wheelSteps(1);
            expect(position.pixels, closeTo(extent * 4, .01));
            final fourthMenu = find.byTooltip('${songs[4].title}的操作');
            expect(fourthMenu.hitTestable(), findsOneWidget);
            await tester.tap(fourthMenu);
            await tester.pumpAndSettle();
            await tester.tap(find.text('加入播放队列'));
            await tester.pumpAndSettle();
            expect(fixture.player.queue.map((song) => song.id), [songs[4].id]);

            await wheelSteps(-1);
            expect(position.pixels, closeTo(0, .01));
            final firstMenu = find.byTooltip('${songs.first.title}的操作');
            expect(firstMenu.hitTestable(), findsOneWidget);
            await tester.tap(firstMenu);
            await tester.pumpAndSettle();
            await tester.tap(find.text('加入播放队列'));
            await tester.pumpAndSettle();
            expect(fixture.player.queue.map((song) => song.id), [
              songs[4].id,
              songs.first.id,
            ]);
            expect(tester.takeException(), isNull);
          },
        );
      },
    );
  }

  for (final configuration in [
    (size: const Size(1280, 720), scale: 1.0),
    (size: const Size(800, 600), scale: 2.0),
  ]) {
    for (final offscreen in [false, true]) {
      testWidgets(
        'library identity preserves ${offscreen ? "offscreen" : "visible"} keyboard focus through index changes at ${configuration.size} scale ${configuration.scale}',
        (tester) async {
          await _withPlayer(
            tester,
            withLibrary: true,
            size: configuration.size,
            textScale: configuration.scale,
            run: (fixture) async {
              final songs = _librarySongs(40);
              // Two preceding songs make deletion and filtering independently
              // move the retained target: original index 2 -> 1 -> 0.
              final target = songs[2];
              fixture.library!.replaceAll(songs);
              await tester.pumpAndSettle();
              final list = find.byKey(const Key('library-list'));
              final extent = tester.widget<ListView>(list).itemExtent!;
              // Materialize B before keyboard traversal, including the compact
              // viewport where the third row initially sits below the fold.
              await tester.sendEventToBinding(
                PointerScrollEvent(
                  position: tester.getCenter(list),
                  scrollDelta: Offset(0, extent * 2),
                ),
              );
              await tester.pumpAndSettle();
              final targetRow = find.byKey(
                ValueKey('library-song-${target.id}'),
                skipOffstage: false,
              );
              for (var step = 0; step < 100; step++) {
                await tester.sendKeyEvent(LogicalKeyboardKey.tab);
                await tester.pumpAndSettle();
                if (_primaryFocusWithin(targetRow)) break;
              }
              expect(_primaryFocusWithin(targetRow), isTrue);
              final targetFocus = FocusManager.instance.primaryFocus;
              if (offscreen) {
                for (var page = 0; page < 4; page++) {
                  await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
                  await tester.pumpAndSettle();
                }
                final position = tester
                    .state<ScrollableState>(
                      find.descendant(
                        of: list,
                        matching: find.byType(Scrollable),
                      ),
                    )
                    .position;
                expect(
                  position.pixels,
                  greaterThan(position.viewportDimension),
                );
                expect(_primaryFocusWithin(targetRow), isTrue);
              }

              // Controller-driven mutations exercise framework state updates;
              // they do not stand in for a native dialog or keyboard workflow.
              await fixture.controller.removeFromLibrary(songs.first);
              await tester.pumpAndSettle();
              expect(
                FocusManager.instance.primaryFocus,
                same(targetFocus),
                reason: 'Removing an earlier song must not replace B\'s focus.',
              );
              expect(_primaryFocusWithin(targetRow), isTrue);

              fixture.controller.setSearchQuery(target.title);
              await tester.pumpAndSettle();
              expect(fixture.controller.visibleSongs.single.id, target.id);
              expect(FocusManager.instance.primaryFocus, same(targetFocus));
              expect(_primaryFocusWithin(targetRow), isTrue);
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await tester.pumpAndSettle();
              expect(fixture.player.currentSong.value?.id, target.id);
              expect(fixture.player.queue.single.id, target.id);

              fixture.controller.setSearchQuery('');
              await tester.pumpAndSettle();
              expect(FocusManager.instance.primaryFocus, same(targetFocus));
              await fixture.controller.removeFromLibrary(target);
              await tester.pumpAndSettle();
              expect(targetRow, findsNothing);
              expect(
                FocusManager.instance.primaryFocus,
                isNot(same(targetFocus)),
              );
              final played = fixture.backend.playCalls;
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await tester.pumpAndSettle();
              expect(
                fixture.backend.playCalls,
                played,
                reason: 'Removing B must not transfer its activation to C.',
              );
              expect(fixture.player.currentSong.value, isNull);
              expect(tester.takeException(), isNull);
            },
          );
        },
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
      );
    }

    testWidgets(
      'Windows keyboard paging retains focus without retaining the library at ${configuration.size} scale ${configuration.scale}',
      (tester) async {
        await _withPlayer(
          tester,
          withLibrary: true,
          size: configuration.size,
          textScale: configuration.scale,
          run: (fixture) async {
            final songs = _librarySongs(10000);
            fixture.library!.replaceAll(songs);
            await fixture.player.open(songs.first);
            await tester.pumpAndSettle();
            final list = find.byKey(const Key('library-list'));
            final scrollable = find.descendant(
              of: list,
              matching: find.byType(Scrollable),
            );
            final position = tester.state<ScrollableState>(scrollable).position;
            final extent = tester.widget<ListView>(list).itemExtent!;
            final viewportRows = (position.viewportDimension / extent).ceil();
            final firstRow = find.byKey(
              ValueKey('library-song-${songs.first.id}'),
              skipOffstage: false,
            );
            final rows = find.byWidgetPredicate(
              (widget) =>
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'library-song-',
                  ),
              skipOffstage: false,
            );

            Future<void> tabTo(Finder target) async {
              for (var step = 0; step < 100; step++) {
                await tester.sendKeyEvent(LogicalKeyboardKey.tab);
                await tester.pumpAndSettle();
                if (_primaryFocusWithin(target)) return;
              }
              fail('Keyboard traversal did not reach $target');
            }

            await tabTo(firstRow);
            final rowFocus = FocusManager.instance.primaryFocus;
            for (final key in [
              ...List.filled(4, LogicalKeyboardKey.pageDown),
              ...List.filled(2, LogicalKeyboardKey.pageUp),
            ]) {
              final before = position.pixels;
              await tester.sendKeyEvent(key);
              await tester.pumpAndSettle();
              expect(
                position.pixels,
                key == LogicalKeyboardKey.pageDown
                    ? greaterThan(before)
                    : lessThan(before),
              );
              expect(FocusManager.instance.primaryFocus, same(rowFocus));
              expect(firstRow, findsOneWidget);
              // Visible rows, at most one partial edge row and the focused row.
              expect(
                rows.evaluate().length,
                lessThanOrEqualTo(viewportRows + 2),
              );
              expect(tester.takeException(), isNull);
            }
            expect(position.pixels, greaterThan(position.viewportDimension));

            await tabTo(_playButton);
            expect(_playButton.hitTestable(), findsOneWidget);
            // Once focus leaves, scrolling away must release the old row rather
            // than retaining every song that keyboard traversal has visited.
            position.jumpTo(position.viewportDimension * 8);
            await tester.pumpAndSettle();
            expect(firstRow, findsNothing);
            expect(_primaryFocusWithin(_playButton), isTrue);
            expect(rows.evaluate().length, lessThanOrEqualTo(viewportRows + 1));
            await tester.sendKeyEvent(LogicalKeyboardKey.space);
            await tester.pumpAndSettle();
            expect(fixture.player.isPlaying.value, isFalse);
            expect(tester.takeException(), isNull);
          },
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  for (final configuration in [
    (size: const Size(1280, 720), scale: 1.0),
    (size: const Size(800, 600), scale: 2.0),
  ]) {
    testWidgets(
      'library background pixels follow scrolling and current song at ${configuration.size} scale ${configuration.scale}',
      (tester) async {
        final captureKey = GlobalKey();
        await _withPlayer(
          tester,
          withLibrary: true,
          size: configuration.size,
          textScale: configuration.scale,
          captureKey: captureKey,
          run: (fixture) async {
            final songs = _librarySongs(20);
            fixture.library!.replaceAll(songs);
            await fixture.player.open(songs.first);
            await tester.pumpAndSettle();
            final list = find.byKey(const Key('library-list'));
            final viewport = tester.getRect(list);
            final position = tester
                .state<ScrollableState>(
                  find.descendant(of: list, matching: find.byType(Scrollable)),
                )
                .position;
            final extent = tester.widget<ListView>(list).itemExtent!;
            final firstRow = find.byKey(
              ValueKey('library-song-${songs.first.id}'),
            );
            final firstBounds = tester.getRect(firstRow);
            // Points lie in padding, away from text, artwork and menu icons.
            final oldSelectedPoint = Offset(
              firstBounds.left + 6,
              firstBounds.bottom - 16,
            );
            final initial = await _capturePagePixels(tester, captureKey);
            const selected = Color(0xFFE7F0E2);
            final theme = HanMusicTheme.light;
            expect(initial.colorAt(oldSelectedPoint), selected);
            expect(
              initial.colorAt(firstBounds.topLeft + const Offset(1, 1)),
              theme.scaffoldBackgroundColor,
              reason: 'The rounded corner must leave the page visible.',
            );
            expect(
              initial.colorAt(
                Offset(firstBounds.center.dx, firstBounds.bottom + 3),
              ),
              theme.scaffoldBackgroundColor,
              reason: 'The gap between rows must retain the page background.',
            );

            position.jumpTo(extent / 2);
            await tester.pumpAndSettle();
            final scrolled = await _capturePagePixels(tester, captureKey);
            expect(
              scrolled.colorAt(oldSelectedPoint),
              theme.colorScheme.surface,
              reason: 'The old position now belongs to the next ordinary row.',
            );
            expect(
              scrolled.colorAt(Offset(viewport.left + 6, viewport.top + 8)),
              selected,
              reason:
                  'The remaining visible part of the current row stays green.',
            );
            final shiftedBounds = tester.getRect(firstRow);
            expect(
              scrolled.colorAt(
                Offset(shiftedBounds.center.dx, shiftedBounds.bottom + 3),
              ),
              theme.scaffoldBackgroundColor,
            );

            position.jumpTo(0);
            await tester.pumpAndSettle();
            final returned = await _capturePagePixels(tester, captureKey);
            expect(returned.colorAt(oldSelectedPoint), selected);
            await fixture.player.open(songs[1]);
            await tester.pumpAndSettle();
            final changed = await _capturePagePixels(tester, captureKey);
            expect(
              changed.colorAt(oldSelectedPoint),
              theme.colorScheme.surface,
            );
            position.jumpTo(extent);
            await tester.pumpAndSettle();
            final next = await _capturePagePixels(tester, captureKey);
            expect(
              next.colorAt(oldSelectedPoint),
              selected,
              reason:
                  'The newly selected song carries its background into view.',
            );
            expect(tester.takeException(), isNull);
          },
        );
      },
    );

    testWidgets(
      'library hover and focused ink stay inside the viewport at ${configuration.size} scale ${configuration.scale}',
      (tester) async {
        final captureKey = GlobalKey();
        await _withPlayer(
          tester,
          withLibrary: true,
          size: configuration.size,
          textScale: configuration.scale,
          captureKey: captureKey,
          run: (fixture) async {
            final songs = _librarySongs(20);
            fixture.library!.replaceAll(songs);
            await tester.pumpAndSettle();
            final list = find.byKey(const Key('library-list'));
            final viewport = tester.getRect(list);
            final position = tester
                .state<ScrollableState>(
                  find.descendant(of: list, matching: find.byType(Scrollable)),
                )
                .position;
            final extent = tester.widget<ListView>(list).itemExtent!;
            final firstRow = find.byKey(
              ValueKey('library-song-${songs.first.id}'),
              skipOffstage: false,
            );
            final bounds = tester.getRect(firstRow);
            final hoverPoint = Offset(bounds.left + 6, bounds.top + 20);
            final outsideBands = [
              Rect.fromLTRB(
                viewport.left,
                viewport.top - 6,
                viewport.right,
                viewport.top,
              ),
              Rect.fromLTRB(
                viewport.left,
                viewport.bottom,
                viewport.right,
                viewport.bottom + 6,
              ),
            ];
            final neutral = await _capturePagePixels(tester, captureKey);
            expect(
              neutral.colorAt(hoverPoint),
              HanMusicTheme.light.colorScheme.surface,
            );

            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await mouse.addPointer(location: const Offset(1, 1));
            try {
              await mouse.moveTo(hoverPoint);
              await tester.pumpAndSettle();
              final hovered = await _capturePagePixels(tester, captureKey);
              expect(
                hovered.colorAt(hoverPoint),
                isNot(neutral.colorAt(hoverPoint)),
                reason: 'Pointer hover must produce visible feedback.',
              );
              position.jumpTo(extent / 2);
              await tester.pumpAndSettle();
              final movedHover = await _capturePagePixels(tester, captureKey);
              expect(
                movedHover.colorAt(Offset(viewport.left + 6, viewport.top + 8)),
                hovered.colorAt(hoverPoint),
                reason:
                    'Hover feedback must move with the partially visible row.',
              );
              expect(
                movedHover.colorAt(Offset(bounds.left + 6, bounds.bottom - 16)),
                HanMusicTheme.light.colorScheme.surface,
                reason:
                    'Hover must not remain painted on the next ordinary row.',
              );
              for (final band in outsideBands) {
                expect(movedHover.changedPixels(hovered, band), 0);
              }
              position.jumpTo(0);
              await tester.pumpAndSettle();
              final returned = await _capturePagePixels(tester, captureKey);
              expect(returned.colorAt(hoverPoint), hovered.colorAt(hoverPoint));
              await mouse.moveTo(const Offset(1, 1));
              await tester.pumpAndSettle();

              for (var step = 0; step < 100; step++) {
                await tester.sendKeyEvent(LogicalKeyboardKey.tab);
                await tester.pumpAndSettle();
                if (_primaryFocusWithin(firstRow)) break;
              }
              expect(_primaryFocusWithin(firstRow), isTrue);
              final focused = await _capturePagePixels(tester, captureKey);
              expect(
                focused.colorAt(hoverPoint),
                isNot(neutral.colorAt(hoverPoint)),
                reason: 'Keyboard focus must remain visible without the mouse.',
              );
              for (final offset in [extent / 2, extent * 3, 0.0]) {
                position.jumpTo(offset);
                await tester.pumpAndSettle();
                expect(_primaryFocusWithin(firstRow), isTrue);
                final scrolled = await _capturePagePixels(tester, captureKey);
                for (final band in outsideBands) {
                  expect(
                    scrolled.changedPixels(focused, band),
                    0,
                    reason: 'Row ink must not repaint outside the viewport.',
                  );
                }
              }
              FocusManager.instance.primaryFocus!.unfocus();
              await tester.pumpAndSettle();
              final released = await _capturePagePixels(tester, captureKey);
              expect(released.colorAt(hoverPoint), neutral.colorAt(hoverPoint));
              expect(fixture.backend.playCalls, 0);
              expect(tester.takeException(), isNull);
            } finally {
              await mouse.removePointer();
            }
          },
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets(
    'library search supports find clear external updates and modal focus',
    (tester) async {
      await _withPlayer(
        tester,
        withLibrary: true,
        run: (fixture) async {
          fixture.library!.replaceAll(_librarySongs(3));
          fixture.controller.searchQuery.value = '专辑 00001';
          await tester.pumpAndSettle();
          final search = find.byKey(const Key('library-search'));
          final editable = find.descendant(
            of: search,
            matching: find.byType(EditableText),
          );
          final input = tester.widget<EditableText>(editable);
          expect(input.controller.text, '专辑 00001');
          expect(find.text('测试曲目 00001'), findsOneWidget);
          expect(find.text('测试曲目 00000'), findsNothing);

          // Ctrl+F also works before any input has been focused.
          await _sendFindShortcut(tester);
          expect(input.focusNode.hasFocus, isTrue);
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pump();
          await _sendFindShortcut(tester);
          expect(input.focusNode.hasFocus, isTrue);
          expect(
            input.controller.selection,
            const TextSelection(baseOffset: 0, extentOffset: 8),
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(fixture.controller.searchQuery.value, isEmpty);
          expect(input.controller.text, isEmpty);
          expect(find.text('测试曲目 00000'), findsOneWidget);

          await tester.enterText(search, '00002');
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('library-search-clear')));
          await tester.pumpAndSettle();
          expect(fixture.controller.searchQuery.value, isEmpty);
          expect(input.controller.text, isEmpty);
          expect(find.byKey(const Key('library-search-clear')), findsNothing);

          fixture.controller.setSearchQuery('00001');
          await tester.pumpAndSettle();
          expect(input.controller.text, '00001');
          await _tabToQueueControl(tester, _timerButton);
          await _sendFindShortcut(tester);
          expect(input.focusNode.hasFocus, isTrue);
          expect(
            input.controller.selection,
            const TextSelection(baseOffset: 0, extentOffset: 5),
          );
          await tester.tap(_timerButton);
          await tester.pumpAndSettle();
          final minutes = find.byKey(const Key('sleep-timer-minutes'));
          await tester.ensureVisible(minutes);
          await tester.enterText(minutes, '17');
          final dialogInput = tester.widget<EditableText>(
            find.descendant(of: minutes, matching: find.byType(EditableText)),
          );
          await _sendFindShortcut(tester);
          expect(dialogInput.focusNode.hasFocus, isTrue);
          expect(input.focusNode.hasFocus, isFalse);
          expect(dialogInput.controller.text, '17');
          expect(fixture.controller.searchQuery.value, '00001');
          await tester.tap(find.text('暂不设置'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('ten thousand songs are virtualized and searchable by metadata', (
    tester,
  ) async {
    await _withPlayer(
      tester,
      withLibrary: true,
      run: (fixture) async {
        fixture.library!.replaceAll(_librarySongs(10000));
        await tester.pumpAndSettle();
        final rows = find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'library-song-',
              ),
        );
        expect(rows.evaluate().length, lessThan(25));
        expect(find.text('测试曲目 09999'), findsNothing);
        final scrollable = find.descendant(
          of: find.byKey(const Key('library-list')),
          matching: find.byType(Scrollable),
        );
        tester
            .state<ScrollableState>(scrollable)
            .position
            .jumpTo(
              tester
                  .state<ScrollableState>(scrollable)
                  .position
                  .maxScrollExtent,
            );
        await tester.pumpAndSettle();
        expect(find.text('测试曲目 09999'), findsOneWidget);
        expect(rows.evaluate().length, lessThan(25));
        expect(tester.getRect(_playButton).bottom, lessThan(720));
        await tester.enterText(
          find.byKey(const Key('library-search')),
          '专辑 09999',
        );
        await tester.pumpAndSettle();
        expect(find.text('测试曲目 09999'), findsOneWidget);
        await tester.tap(find.text('测试曲目 09999'));
        await tester.pumpAndSettle();
        expect(fixture.player.queue, hasLength(1));
        expect(fixture.player.currentSong.value!.title, '测试曲目 09999');
        expect(tester.takeException(), isNull);
      },
    );
  });

  for (final configuration in [
    (size: const Size(1280, 720), scale: 1.0),
    (size: const Size(800, 600), scale: 2.0),
  ]) {
    for (final interaction in ['hover', 'keyboard focus']) {
      testWidgets(
        'queue title $interaction is visible and Enter plays the focused song at ${configuration.size} scale ${configuration.scale}',
        (tester) async {
          final captureKey = GlobalKey();
          await _withPlayer(
            tester,
            withLibrary: true,
            size: configuration.size,
            textScale: configuration.scale,
            captureKey: captureKey,
            run: (fixture) async {
              final songs = _librarySongs(3);
              final target = songs[1];
              fixture.player.addToQueue(songs);
              await tester.tap(find.byKey(const Key('nav-2')));
              await tester.pumpAndSettle();
              final row = find.byKey(ValueKey('queue-song-${target.id}'));
              final title = find.ancestor(
                of: find.descendant(of: row, matching: find.text(target.title)),
                matching: find.byType(InkWell),
              );
              expect(title, findsOneWidget);
              final bounds = tester.getRect(title);
              // This lies inside the title's hit area but above its glyphs.
              final feedbackPoint = Offset(bounds.right - 4, bounds.top + 2);
              final neutral = await _capturePagePixels(tester, captureKey);
              expect(
                neutral.colorAt(feedbackPoint),
                HanMusicTheme.light.colorScheme.surface,
              );

              Future<void> focusTitle() async {
                for (var step = 0; step < 100; step++) {
                  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
                  await tester.pumpAndSettle();
                  if (_primaryFocusWithin(title)) return;
                }
                fail('Keyboard traversal did not reach the queue title.');
              }

              if (interaction == 'hover') {
                final mouse = await tester.createGesture(
                  kind: PointerDeviceKind.mouse,
                );
                await mouse.addPointer(location: const Offset(1, 1));
                try {
                  await mouse.moveTo(feedbackPoint);
                  await tester.pumpAndSettle();
                  final hovered = await _capturePagePixels(tester, captureKey);
                  expect(
                    hovered.colorAt(feedbackPoint),
                    isNot(neutral.colorAt(feedbackPoint)),
                    reason:
                        'Queue title hover must be visible above its row background.',
                  );
                } finally {
                  await mouse.removePointer();
                  await tester.pumpAndSettle();
                }
              }

              await focusTitle();
              final focused = await _capturePagePixels(tester, captureKey);
              expect(
                focused.colorAt(feedbackPoint),
                isNot(neutral.colorAt(feedbackPoint)),
                reason:
                    'Queue title keyboard focus must be visible above its row background.',
              );
              expect(fixture.backend.playCalls, 0);
              if (interaction == 'keyboard focus') {
                final focus = FocusManager.instance.primaryFocus;
                fixture.controller.reorderQueue(1, 0);
                await tester.pumpAndSettle();
                expect(fixture.player.queue.first.id, target.id);
                expect(FocusManager.instance.primaryFocus, same(focus));
                expect(_primaryFocusWithin(title), isTrue);
              }
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await tester.pumpAndSettle();
              expect(fixture.player.currentSong.value?.id, target.id);
              expect(fixture.backend.loadedUris, [target.uri]);
              expect(fixture.backend.playCalls, 1);
              expect(tester.takeException(), isNull);
            },
          );
        },
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
      );
    }
  }

  for (final configuration in [
    (size: const Size(1280, 720), scale: 1.0, direction: 1.0),
    (size: const Size(800, 600), scale: 2.0, direction: -1.0),
  ]) {
    testWidgets(
      'queue drag rejects stale drop after keyboard reorder at ${configuration.size} scale ${configuration.scale}',
      (tester) async {
        await _withPlayer(
          tester,
          withLibrary: true,
          size: configuration.size,
          textScale: configuration.scale,
          run: (fixture) async {
            final songs = _librarySongs(3);
            fixture.player.addToQueue(songs);
            await tester.tap(find.byKey(const Key('nav-2')));
            await tester.pumpAndSettle();
            final down = find.descendant(
              of: _queueRow(songs[0]),
              matching: find.byTooltip('下移'),
            );
            await _tabToQueueControl(tester, down);
            final focus = FocusManager.instance.primaryFocus;
            final drag = await _dragQueueRow(
              tester,
              songs[1],
              direction: configuration.direction,
            );
            try {
              expect(FocusManager.instance.primaryFocus, same(focus));
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await tester.pumpAndSettle();
              expect(fixture.player.queue.map((song) => song.id), [
                songs[1].id,
                songs[0].id,
                songs[2].id,
              ]);
              expect(FocusManager.instance.primaryFocus, same(focus));
              await drag.up();
              await tester.pumpAndSettle();
              expect(
                fixture.player.queue.map((song) => song.id),
                [songs[1].id, songs[0].id, songs[2].id],
                reason: 'The old B drag must not move the new item at index 1.',
              );
              expect(tester.takeException(), isNull);
            } finally {
              await drag.removePointer();
            }
          },
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  for (final mutation in [
    'delete dragged song',
    'replace same length',
    'leave page',
  ]) {
    testWidgets(
      'queue drag cancels safely on $mutation',
      (tester) async {
        await _withPlayer(
          tester,
          withLibrary: true,
          run: (fixture) async {
            final songs = _librarySongs(4);
            fixture.player.addToQueue(songs.take(3).toList());
            await tester.tap(find.byKey(const Key('nav-2')));
            await tester.pumpAndSettle();
            final drag = await _dragQueueRow(tester, songs[1]);
            try {
              switch (mutation) {
                case 'delete dragged song':
                  await fixture.controller.removeFromQueue(songs[1].id);
                case 'replace same length':
                  await fixture.player.restoreQueue([
                    songs[0],
                    songs[3],
                    songs[2],
                  ]);
                case 'leave page':
                  await tester.tap(find.byKey(const Key('nav-0')));
              }
              final expected = fixture.player.queue
                  .map((song) => song.id)
                  .toList();
              await tester.pumpAndSettle();
              await drag.moveBy(const Offset(0, 5));
              await drag.up();
              await tester.pumpAndSettle();
              expect(fixture.player.queue.map((song) => song.id), expected);
              if (mutation == 'leave page') {
                await tester.tap(find.byKey(const Key('nav-2')));
                await tester.pumpAndSettle();
              }
              // No invisible dragged row or orphaned proxy survives cancellation.
              for (final song in fixture.player.queue) {
                expect(_queueRow(song), findsOneWidget);
                expect(
                  find.descendant(
                    of: _queueRow(song),
                    matching: find.text(song.title),
                  ),
                  findsOneWidget,
                );
              }
              expect(tester.takeException(), isNull);
            } finally {
              await drag.removePointer();
            }
          },
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  for (final down in [true, false]) {
    testWidgets(
      'queue repeated keyboard moves target the same song without a frame: down $down',
      (tester) async {
        await _withPlayer(
          tester,
          withLibrary: true,
          run: (fixture) async {
            final songs = _librarySongs(3);
            fixture.player.addToQueue(songs);
            await tester.tap(find.byKey(const Key('nav-2')));
            await tester.pumpAndSettle();
            final target = down ? songs.first : songs.last;
            final button = find.descendant(
              of: _queueRow(target),
              matching: find.byTooltip(down ? '下移' : '上移'),
            );
            await _tabToQueueControl(tester, button);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(
              fixture.player.queue.map((song) => song.id),
              down
                  ? [songs[1].id, songs[2].id, songs[0].id]
                  : [songs[2].id, songs[0].id, songs[1].id],
            );
            expect(tester.takeException(), isNull);
          },
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  for (final updateMetadata in [false, true]) {
    testWidgets(
      'queue drag completes normally with metadata update $updateMetadata',
      (tester) async {
        await _withPlayer(
          tester,
          withLibrary: true,
          run: (fixture) async {
            final songs = _librarySongs(3);
            await fixture.player.playQueue(songs, startIndex: 1);
            fixture.backend.emitPosition(const Duration(seconds: 37));
            await tester.tap(find.byKey(const Key('nav-2')));
            await tester.pumpAndSettle();
            final backendCalls = List<String>.of(fixture.backend.calls);
            final drag = await _dragQueueRow(tester, songs[1]);
            try {
              if (updateMetadata) {
                fixture.player.updateSongs([
                  songs[1].copyWith(trackTitle: '更新后的歌曲标题'),
                ]);
                await tester.pumpAndSettle();
              }
              await drag.up();
              await tester.pumpAndSettle();
              expect(fixture.player.queue.map((song) => song.id), [
                songs[0].id,
                songs[2].id,
                songs[1].id,
              ]);
              expect(
                fixture.player.queue.last.title,
                updateMetadata ? '更新后的歌曲标题' : songs[1].title,
              );
              expect(fixture.player.currentSong.value?.id, songs[1].id);
              expect(
                fixture.player.position.value,
                const Duration(seconds: 37),
              );
              expect(fixture.player.isPlaying.value, isTrue);
              expect(fixture.backend.calls, backendCalls);
              expect(tester.takeException(), isNull);
            } finally {
              await drag.removePointer();
            }
          },
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  for (final title in [false, true]) {
    testWidgets(
      'queue playback keeps song identity before a rebuild: title $title',
      (tester) async {
        await _withPlayer(
          tester,
          withLibrary: true,
          run: (fixture) async {
            final songs = _librarySongs(3);
            fixture.player.addToQueue(songs);
            await tester.tap(find.byKey(const Key('nav-2')));
            await tester.pumpAndSettle();
            final target = title
                ? find.ancestor(
                    of: find.descendant(
                      of: _queueRow(songs[0]),
                      matching: find.text(songs[0].title),
                    ),
                    matching: find.byType(InkWell),
                  )
                : find.byTooltip('播放${songs[0].title}');
            await _tabToQueueControl(tester, target);
            fixture.controller.reorderQueue(0, 3);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(fixture.player.currentSong.value?.id, songs[0].id);
            expect(fixture.backend.loadedUris, [songs[0].uri]);
            expect(tester.takeException(), isNull);
          },
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets(
    'queue stale semantics reorder cannot move its former neighbor',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await _withPlayer(
          tester,
          withLibrary: true,
          run: (fixture) async {
            final songs = _librarySongs(3);
            fixture.player.addToQueue(songs);
            await tester.tap(find.byKey(const Key('nav-2')));
            await tester.pumpAndSettle();
            final node = tester.getSemantics(_queueRow(songs[0]));
            final label = WidgetsLocalizations.of(
              tester.element(_queueRow(songs[0])),
            ).reorderItemDown;
            final action = node
                .getSemanticsData()
                .customSemanticsActionIds!
                .singleWhere(
                  (id) => CustomSemanticsAction.getAction(id)!.label == label,
                );
            node.owner!.performAction(
              node.id,
              ui.SemanticsAction.customAction,
              action,
            );
            node.owner!.performAction(
              node.id,
              ui.SemanticsAction.customAction,
              action,
            );
            await tester.pumpAndSettle();
            expect(fixture.player.queue.map((song) => song.id), [
              songs[1].id,
              songs[0].id,
              songs[2].id,
            ]);
            expect(tester.takeException(), isNull);
          },
        );
      } finally {
        semantics.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  for (final released in [false, true]) {
    testWidgets(
      'queue drag respects a semantics reorder with pointer released $released',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await _withPlayer(
            tester,
            withLibrary: true,
            run: (fixture) async {
              final songs = _librarySongs(3);
              fixture.player.addToQueue(songs);
              await tester.tap(find.byKey(const Key('nav-2')));
              await tester.pumpAndSettle();
              final drag = await _dragQueueRow(tester, songs[1]);
              try {
                if (released) {
                  await drag.up();
                  await tester.pump(const Duration(milliseconds: 30));
                }
                final node = tester.getSemantics(_queueRow(songs[0]));
                final label = WidgetsLocalizations.of(
                  tester.element(_queueRow(songs[0])),
                ).reorderItemDown;
                final action = node
                    .getSemanticsData()
                    .customSemanticsActionIds!
                    .singleWhere(
                      (id) =>
                          CustomSemanticsAction.getAction(id)!.label == label,
                    );
                node.owner!.performAction(
                  node.id,
                  ui.SemanticsAction.customAction,
                  action,
                );
                // Do not pump between the action and pointer release: the guard
                // must invalidate the old drop even before another frame builds.
                if (!released) await drag.up();
                await tester.pumpAndSettle();
                expect(fixture.player.queue.map((song) => song.id), [
                  songs[1].id,
                  songs[0].id,
                  songs[2].id,
                ]);
                expect(tester.takeException(), isNull);
              } finally {
                await drag.removePointer();
              }
            },
          );
        } finally {
          semantics.dispose();
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets(
    'library removal explains source files stay and queue order can change',
    (tester) async {
      await _withPlayer(
        tester,
        withLibrary: true,
        run: (fixture) async {
          final songs = _librarySongs(3);
          fixture.library!.replaceAll(songs);
          await tester.pumpAndSettle();
          await tester.tap(find.text(songs.first.title));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('nav-2')));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('下移').first);
          await tester.pumpAndSettle();
          expect(fixture.player.queue[1].id, songs.first.id);
          await tester.tap(find.byTooltip('从队列移除').first);
          await tester.pumpAndSettle();
          expect(fixture.player.queue, hasLength(2));
          expect(fixture.library!.songs, hasLength(3));
          await tester.tap(find.byKey(const Key('nav-0')));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('${songs.first.title}的操作'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('从曲库移除（保留文件）'));
          await tester.pumpAndSettle();
          expect(find.textContaining('电脑上的音乐文件会保留'), findsOneWidget);
          await tester.tap(find.byKey(const Key('confirm-remove-song')));
          await tester.pumpAndSettle();
          expect(fixture.library!.songs, hasLength(2));
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  for (final configuration in [
    (size: const Size(1280, 720), scale: 1.0),
    (size: const Size(800, 600), scale: 1.0),
    (size: const Size(800, 600), scale: 1.5),
    (size: const Size(1280, 720), scale: 2.0),
    (size: const Size(800, 600), scale: 2.0),
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
          expect(find.text('请输入 1–1440 的整数分钟'), findsOneWidget);
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

  for (final scenario in [
    (
      label: 'release while disabled',
      releaseWhileDisabled: true,
      switchSong: false,
      observeDisabled: true,
    ),
    (
      label: 'release after same-song reload',
      releaseWhileDisabled: false,
      switchSong: false,
      observeDisabled: true,
    ),
    (
      label: 'release after changing songs',
      releaseWhileDisabled: false,
      switchSong: true,
      observeDisabled: true,
    ),
    (
      label: 'same-frame same-song reload',
      releaseWhileDisabled: false,
      switchSong: false,
      observeDisabled: false,
    ),
  ]) {
    testWidgets(
      'seek invalidates an interrupted drag: ${scenario.label}',
      (tester) async {
        await _withPlayer(
          tester,
          withLibrary: true,
          size: const Size(800, 600),
          run: (fixture) async {
            await fixture.player.open(_song);
            fixture.backend.emitPosition(const Duration(seconds: 20));
            await tester.pumpAndSettle();
            final slider = find.byKey(const Key('seek-slider'));
            final bounds = tester.getRect(slider);
            final gesture = await tester.startGesture(
              Offset(bounds.left + bounds.width * .25, bounds.center.dy),
            );
            var released = false;
            await gesture.moveTo(
              Offset(bounds.left + bounds.width * .7, bounds.center.dy),
            );
            await tester.pump();
            expect(tester.widget<Slider>(slider).value, greaterThan(20000));
            expect(fixture.backend.seekPositions, isEmpty);

            final selected = scenario.switchSong
                ? _song.copyWith(
                    uri: Uri.file('D:/music/replacement.flac', windows: true),
                    fileName: 'replacement.flac',
                  )
                : _song;
            final gate = fixture.backend.loadCompleter =
                scenario.observeDisabled ? Completer<Duration?>() : null;
            final loading = fixture.player.playQueue([selected]);
            try {
              if (scenario.observeDisabled) {
                await tester.pump();
                expect(fixture.player.isLoading.value, isTrue);
                expect(tester.widget<Slider>(slider).onChanged, isNull);
              }
              if (scenario.releaseWhileDisabled) {
                await gesture.up();
                released = true;
                await tester.pump();
              }
              gate?.complete(const Duration(minutes: 3));
              await loading;
              await tester.pumpAndSettle();
              fixture.backend.emitPosition(const Duration(seconds: 12));
              await tester.pump();
              if (!released) {
                // Continuing the original pointer must not reactivate a drag
                // invalidated by loading, even though the slider is ready again.
                await gesture.moveBy(Offset(bounds.width * .05, 0));
                await tester.pump();
                await gesture.up();
                released = true;
                await tester.pumpAndSettle();
              }
              expect(
                fixture.backend.seekPositions,
                isEmpty,
                reason: 'The old pointer must not seek the newly loaded audio.',
              );
              expect(
                tester.widget<Slider>(slider).value,
                12000,
                reason:
                    'An interrupted preview must stop masking live position.',
              );
              expect(find.text('00:12'), findsOneWidget);

              final freshBounds = tester.getRect(slider);
              final freshGesture = await tester.startGesture(
                Offset(
                  freshBounds.left + freshBounds.width * .25,
                  freshBounds.center.dy,
                ),
              );
              await freshGesture.moveBy(Offset(freshBounds.width * .25, 0));
              await tester.pump();
              expect(fixture.backend.seekPositions, isEmpty);
              await freshGesture.up();
              await tester.pumpAndSettle();
              expect(fixture.backend.seekPositions, hasLength(1));
              final seeked = fixture.backend.seekPositions.single;
              expect(seeked, greaterThan(const Duration(seconds: 12)));
              expect(
                tester.widget<Slider>(slider).value,
                seeked.inMilliseconds,
              );

              for (
                var step = 0;
                !_primaryFocusWithin(slider) && step < 100;
                step++
              ) {
                await tester.sendKeyEvent(LogicalKeyboardKey.tab);
                await tester.pumpAndSettle();
              }
              expect(_primaryFocusWithin(slider), isTrue);
              await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
              await tester.pumpAndSettle();
              expect(fixture.backend.seekPositions, hasLength(2));
              expect(fixture.backend.seekPositions.last, greaterThan(seeked));
              final semantics = tester.ensureSemantics();
              try {
                await tester.pump();
                final node = tester.getSemantics(slider);
                node.owner!.performAction(node.id, ui.SemanticsAction.increase);
                await tester.pumpAndSettle();
                expect(fixture.backend.seekPositions, hasLength(3));
                expect(
                  fixture.backend.seekPositions.last,
                  greaterThan(fixture.backend.seekPositions[1]),
                );
              } finally {
                semantics.dispose();
              }
              expect(tester.takeException(), isNull);
            } finally {
              if (gate != null && !gate.isCompleted) {
                gate.complete(const Duration(minutes: 3));
              }
              await loading;
              if (!released) await gesture.up();
              fixture.backend.loadCompleter = null;
            }
          },
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

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

bool _primaryFocusWithin(Finder finder) {
  final candidates = finder.evaluate().toSet();
  final context = FocusManager.instance.primaryFocus?.context;
  if (context is! Element) return false;
  var found = candidates.contains(context);
  context.visitAncestorElements((element) {
    found = found || candidates.contains(element);
    return !found;
  });
  return found;
}

Finder _queueRow(Song song) => find.byKey(ValueKey('queue-song-${song.id}'));

Future<void> _tabToQueueControl(WidgetTester tester, Finder target) async {
  for (var step = 0; step < 100; step++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    if (_primaryFocusWithin(target)) return;
  }
  fail('Keyboard traversal did not reach the queue control.');
}

Future<TestGesture> _dragQueueRow(
  WidgetTester tester,
  Song song, {
  double direction = 1,
}) async {
  final row = _queueRow(song);
  final handle = find.descendant(
    of: row,
    matching: find.byType(ReorderableDragStartListener),
  );
  final origin = tester.getCenter(handle);
  final extent = tester
      .widget<ReorderableListView>(find.byKey(const Key('queue-list')))
      .itemExtent!;
  final drag = await tester.startGesture(origin, kind: PointerDeviceKind.mouse);
  await drag.moveBy(Offset(0, 10 * direction));
  await tester.pump();
  await drag.moveTo(origin + Offset(0, extent * .75 * direction));
  await tester.pump(const Duration(milliseconds: 300));
  expect(
    (tester.getCenter(handle).dy - origin.dy) * direction,
    greaterThan(extent / 2),
  );
  return drag;
}

Future<_PagePixels> _capturePagePixels(
  WidgetTester tester,
  GlobalKey key,
) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final origin = boundary.localToGlobal(Offset.zero);
  // Rasterization completes outside the test's fake clock. Capture the page,
  // including ancestor ink, rather than a row's own repaint boundary.
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return _PagePixels(data!, image.width, image.height, origin);
    } finally {
      image.dispose();
    }
  }))!;
}

Future<bool> _waitForArtwork(WidgetTester tester, Finder finder) async {
  final image = tester.widget<Image>(finder);
  return (await tester.runAsync(() async {
    final result = Completer<bool>();
    final stream = image.image.resolve(
      createLocalImageConfiguration(tester.element(finder)),
    );
    final listener = ImageStreamListener(
      (info, _) {
        info.dispose();
        if (!result.isCompleted) result.complete(true);
      },
      onError: (_, _) {
        if (!result.isCompleted) result.complete(false);
      },
    );
    stream.addListener(listener);
    try {
      return await result.future.timeout(const Duration(seconds: 5));
    } finally {
      stream.removeListener(listener);
    }
  }))!;
}

class _PagePixels {
  const _PagePixels(this.data, this.width, this.height, this.origin);

  final ByteData data;
  final int width;
  final int height;
  final Offset origin;

  Color colorAt(Offset point) {
    final x = (point.dx - origin.dx).floor();
    final y = (point.dy - origin.dy).floor();
    assert(x >= 0 && x < width && y >= 0 && y < height);
    final offset = (y * width + x) * 4;
    return Color.fromARGB(
      data.getUint8(offset + 3),
      data.getUint8(offset),
      data.getUint8(offset + 1),
      data.getUint8(offset + 2),
    );
  }

  int changedPixels(_PagePixels other, Rect region) {
    var changed = 0;
    for (var y = region.top.ceil(); y < region.bottom.floor(); y++) {
      for (var x = region.left.ceil(); x < region.right.floor(); x++) {
        final point = Offset(x + .5, y + .5);
        if (colorAt(point) != other.colorAt(point)) changed++;
      }
    }
    return changed;
  }
}

Future<void> _sendFindShortcut(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

Future<void> _withPlayer(
  WidgetTester tester, {
  required Future<void> Function(_Fixture fixture) run,
  Size size = const Size(1280, 720),
  double textScale = 1,
  bool withLibrary = false,
  GlobalKey? captureKey,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final fixture = _Fixture(withLibrary: withLibrary);
  fixture.controller.onInit();
  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: HanMusicTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: captureKey == null
              ? child!
              : RepaintBoundary(key: captureKey, child: child!),
        ),
        home: PlayerPage(controller: fixture.controller),
      ),
    );
    await tester.pumpAndSettle();
    await run(fixture);
  } finally {
    fixture.coordinator.dispose();
    fixture.timer.onClose();
    fixture.controller.onClose();
    fixture.library?.onClose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.player.shutdown);
    await tester.pump();
  }
}

class _Fixture {
  _Fixture({bool withLibrary = false}) {
    player = PlayerService(backend);
    timer = TimerService(onExpired: player.pause, now: () => now);
    coordinator = SleepTimerCoordinator(player: player, timer: timer);
    if (withLibrary) {
      library = LibraryService(
        repository: LocalLibraryRepository(
          artworkDirectory: Directory(r'D:\dev\tmp\hanmusic-widget-artwork'),
        ),
      );
    }
    controller = PlayerController(
      player: player,
      timer: timer,
      picker: picker,
      library: library,
      libraryPicker: _EmptyLibraryPicker(),
    );
  }

  final backend = FakeAudioBackend();
  final picker = _FakeSongPicker();
  late final PlayerService player;
  late final TimerService timer;
  late final PlayerController controller;
  late final SleepTimerCoordinator coordinator;
  DateTime now = DateTime(2026, 9, 29, 20);
  LibraryService? library;
}

class _EmptyLibraryPicker implements LibraryPicker {
  @override
  Future<List<String>> pickFiles() async => [];
  @override
  Future<String?> pickDirectory() async => null;
}

List<Song> _librarySongs(int count) => List.generate(count, (index) {
  final number = index.toString().padLeft(5, '0');
  return Song(
    uri: Uri.file('D:/音乐/track-$number.flac', windows: true),
    fileName: 'track-$number.flac',
    trackTitle: '测试曲目 $number',
    artist: '测试歌手',
    album: '专辑 $number',
    duration: const Duration(minutes: 3),
  );
});

class _FakeSongPicker implements SongPicker {
  Song? next;
  int calls = 0;

  @override
  Future<Song?> pick() async {
    calls++;
    return next;
  }
}
