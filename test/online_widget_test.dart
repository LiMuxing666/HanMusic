import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/core/theme/app_theme.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/data/repositories/online_music_repository.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/modules/player/view.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/online_music_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

import 'support/fake_audio_backend.dart';
import 'support/fake_online_music.dart';

void main() {
  for (final size in [const Size(1280, 720), const Size(800, 600)]) {
    testWidgets('200 percent online states and dialogs fit $size', (
      tester,
    ) async {
      await _withOnline(
        tester,
        size: size,
        scale: 2,
        run: (fixture) async {
          expect(_play.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          final gate = Completer<OnlineSearchPage>();
          fixture.repository.gates['加载状态'] = gate;
          await tester.enterText(find.byKey(const Key('online-query')), '加载状态');
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump();
          expect(find.text('正在搜索…'), findsOneWidget);
          expect(tester.takeException(), isNull);
          gate.complete(
            OnlineSearchPage(
              songs: [
                Song.online(
                  sourceId: 'demo',
                  trackId: 'loaded',
                  title: '200% 字号测试歌曲',
                  artist: '示例歌手',
                ),
              ],
              hasMore: false,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('200% 字号测试歌曲'));
          await tester.pumpAndSettle();
          expect(_play.hitTestable(), findsOneWidget);
          await tester.tap(find.byKey(const Key('sleep-timer-open')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('sleep-timer-confirm')).hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('暂不设置'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('online-add-source')));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const Key('online-test-query')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('online-source-save')).hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          fixture.repository.failure = '音乐源暂时不可用，请检查配置后重试。';
          await fixture.online.searchNow('错误状态');
          await tester.pumpAndSettle();
          expect(find.text('重试').hitTestable(), findsOneWidget);
          expect(_play.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    });
  }

  testWidgets(
    'source picker selects the requested source and refreshes result context',
    (tester) async {
      await _withOnline(
        tester,
        run: (fixture) async {
          await fixture.online.upsertSource(
            onlineTestSource(id: 'second', name: '第二音乐源'),
            testQuery: '连接检查',
          );
          await fixture.online.searchNow('当前搜索');
          await tester.pumpAndSettle();
          expect(fixture.online.results.single.sourceId, 'demo');
          await tester.tap(find.byKey(const Key('online-source-picker')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('第二音乐源').last);
          await tester.pumpAndSettle();
          expect(fixture.online.selectedSourceId.value, 'second');
          expect(fixture.online.results, isEmpty);
          await tester.tap(find.byKey(const Key('online-search')));
          await tester.pumpAndSettle();
          expect(fixture.online.results.single.sourceId, 'second');
          expect(fixture.repository.requests.last.sourceId, 'second');
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets(
    'compact large text keeps empty page, editor and transport reachable',
    (tester) async {
      await _withOnline(
        tester,
        empty: true,
        size: const Size(800, 600),
        scale: 1.5,
        run: (fixture) async {
          expect(find.text('连接你的音乐世界'), findsOneWidget);
          expect(_play.hitTestable(), findsOneWidget);
          await tester.tap(find.byKey(const Key('online-add-source')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('online-source-save')).hitTestable(),
            findsOneWidget,
          );
          final json = find.byKey(const Key('online-source-json'));
          await tester.enterText(json, '{invalid');
          await tester.tap(find.byKey(const Key('online-source-save')));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const Key('online-source-error')),
          );
          expect(find.textContaining('配置格式不正确'), findsOneWidget);
          expect(fixture.repository.requests, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(_play.hitTestable(), findsOneWidget);
        },
      );
    },
  );

  testWidgets(
    'source add edit test and delete use explicit keyword and preserve failure',
    (tester) async {
      await _withOnline(
        tester,
        empty: true,
        run: (fixture) async {
          await tester.tap(find.byKey(const Key('online-add-source')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('online-source-json')),
            jsonEncode(onlineTestSource().toJson()),
          );
          await tester.ensureVisible(
            find.byKey(const Key('online-test-query')),
          );
          await tester.enterText(
            find.byKey(const Key('online-test-query')),
            '明确测试',
          );
          fixture.repository.failure = '服务暂不可用';
          await tester.tap(find.byKey(const Key('online-source-save')));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(fixture.online.sources, isEmpty);
          expect(fixture.repository.requests.single.query, '明确测试');
          fixture.repository.failure = null;
          await tester.tap(find.byKey(const Key('online-source-save')));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(fixture.online.sources.single.name, '示例音乐源');

          await _sourceAction(tester, '编辑音乐源');
          await tester.enterText(
            find.byKey(const Key('online-source-json')),
            jsonEncode(onlineTestSource(name: '更新的音乐源').toJson()),
          );
          await tester.tap(find.byKey(const Key('online-source-save')));
          await tester.pumpAndSettle();
          expect(fixture.online.sources.single.name, '更新的音乐源');
          await _sourceAction(tester, '测试连接');
          await tester.enterText(
            find.byKey(const Key('online-test-query')),
            '单独连接测试',
          );
          await tester.tap(find.byKey(const Key('online-test-connection')));
          await tester.pumpAndSettle();
          expect(fixture.repository.requests.last.query, '单独连接测试');
          expect(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.textContaining('连接成功'),
            ),
            findsOneWidget,
          );
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
          await _sourceAction(tester, '删除音乐源');
          await tester.tap(find.byKey(const Key('online-source-delete')));
          await tester.pumpAndSettle();
          expect(fixture.online.sources, isEmpty);
          expect(fixture.store.snapshot.sources, isEmpty);
          expect(find.text('连接你的音乐世界'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets(
    'source save blocks in-flight edits and saves the submitted configuration',
    (tester) async {
      await _withOnline(
        tester,
        empty: true,
        run: (fixture) async {
          await tester.tap(find.byKey(const Key('online-add-source')));
          await tester.pumpAndSettle();
          final json = find.byKey(const Key('online-source-json'));
          final query = find.byKey(const Key('online-test-query'));
          final submitted = jsonEncode(
            onlineTestSource(name: '提交的配置').toJson(),
          );
          await tester.enterText(json, submitted);
          await tester.ensureVisible(query);
          await tester.enterText(query, '等待连接');
          final gate = Completer<OnlineSearchPage>();
          fixture.repository.gates['等待连接'] = gate;
          await tester.tap(find.byKey(const Key('online-source-save')));
          await tester.pump();
          String? visibleJson;
          String? visibleQuery;
          try {
            expect(fixture.repository.requests.single.query, '等待连接');
            visibleJson = await _trySourceFieldEdit(
              tester,
              json,
              jsonEncode(onlineTestSource(name: '不应接受的新配置').toJson()),
            );
            visibleQuery = await _trySourceFieldEdit(
              tester,
              query,
              '不应接受的新关键词',
            );
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(fixture.store.saves, 0);
          } finally {
            gate.complete(OnlineSearchPage(songs: [], hasMore: false));
            await tester.pumpAndSettle();
          }
          expect(find.byType(AlertDialog), findsNothing);
          expect(fixture.store.snapshot.sources.single.name, '提交的配置');
          expect(fixture.store.saves, 1);
          expect(fixture.repository.requests, hasLength(1));
          expect(
            visibleJson,
            submitted,
            reason:
                'Saving must not accept a draft that will be silently discarded.',
          );
          expect(visibleQuery, '等待连接');
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets(
    'source save failure preserves the draft and restores editing for retry',
    (tester) async {
      await _withOnline(
        tester,
        run: (fixture) async {
          await _sourceAction(tester, '编辑音乐源');
          final json = find.byKey(const Key('online-source-json'));
          final query = find.byKey(const Key('online-test-query'));
          final submitted = jsonEncode(
            onlineTestSource(name: '待保存的配置').toJson(),
          );
          await tester.enterText(json, submitted);
          await tester.ensureVisible(query);
          await tester.enterText(query, '稍后失败');
          final queryEditable = find.descendant(
            of: query,
            matching: find.byType(EditableText),
          );
          final queryFocus = tester
              .widget<EditableText>(queryEditable)
              .focusNode;
          final gate = Completer<OnlineSearchPage>();
          fixture.repository.gates['稍后失败'] = gate;
          await tester.tap(find.byKey(const Key('online-source-save')));
          await tester.pump();
          try {
            await _trySourceFieldEdit(tester, json, '{unsubmitted edit');
            await _trySourceFieldEdit(tester, query, '等待期间的输入');
          } finally {
            gate.completeError(const OnlineMusicException('连接测试失败，请重试。'));
            await tester.pumpAndSettle();
          }
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(fixture.store.snapshot.sources.single.name, '示例音乐源');
          expect(fixture.store.saves, 0);
          expect(
            tester.widget<EditableText>(queryEditable).focusNode,
            same(queryFocus),
          );
          expect(
            tester.widget<TextFormField>(json).controller!.text,
            submitted,
          );
          expect(tester.widget<TextFormField>(query).controller!.text, '稍后失败');
          final corrected = jsonEncode(
            onlineTestSource(name: '修正后的配置').toJson(),
          );
          await tester.ensureVisible(json);
          await tester.enterText(json, corrected);
          await tester.ensureVisible(query);
          await tester.enterText(query, '重试关键词');
          await tester.tap(find.byKey(const Key('online-source-save')));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(fixture.repository.requests.last.query, '重试关键词');
          expect(fixture.store.snapshot.sources.single.name, '修正后的配置');
          expect(fixture.store.saves, 1);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets(
    'search debounces 500 ms and stale response never replaces new results',
    (tester) async {
      await _withOnline(
        tester,
        run: (fixture) async {
          final gate = Completer<OnlineSearchPage>();
          fixture.repository.gates['旧查询'] = gate;
          final query = find.byKey(const Key('online-query'));
          await tester.enterText(query, '旧查询');
          await tester.pump(const Duration(milliseconds: 499));
          expect(fixture.repository.requests, isEmpty);
          await tester.pump(const Duration(milliseconds: 1));
          expect(fixture.repository.requests.single.query, '旧查询');
          await tester.enterText(query, '新查询');
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pumpAndSettle();
          expect(find.text('歌曲 新查询 1'), findsOneWidget);
          gate.complete(
            OnlineSearchPage(
              songs: [
                Song.online(
                  sourceId: 'demo',
                  trackId: 'old',
                  title: '不该显示的旧结果',
                ),
              ],
              hasMore: false,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('不该显示的旧结果'), findsNothing);
          expect(find.text('歌曲 新查询 1'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets(
    'compact results paginate, build current list queue, and show online source',
    (tester) async {
      await _withOnline(
        tester,
        size: const Size(800, 600),
        scale: 1.5,
        run: (fixture) async {
          fixture.repository.hasMore = true;
          await tester.enterText(find.byKey(const Key('online-query')), '夏天');
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pumpAndSettle();
          expect(find.text('歌曲 夏天 1'), findsOneWidget);
          expect(_play.hitTestable(), findsOneWidget);
          final more = find.byKey(const Key('online-load-more'));
          await tester.ensureVisible(more);
          await tester.pumpAndSettle();
          expect(more.hitTestable(), findsOneWidget);
          await tester.tap(more);
          await tester.pumpAndSettle();
          expect(fixture.online.results, hasLength(2));
          final song = fixture.online.results.last;
          final row = find.byKey(ValueKey('online-song-${song.id}'));
          await tester.ensureVisible(row);
          await tester.pumpAndSettle();
          await tester.tap(row);
          await tester.pumpAndSettle();
          expect(fixture.player.queue, fixture.online.results.toList());
          expect(fixture.player.currentSong.value?.id, song.id);
          expect(fixture.backend.loadedUris.single.scheme, 'https');
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const Key('nav-1')));
          await tester.pumpAndSettle();
          expect(find.text('示例音乐源'), findsOneWidget);
          expect(find.textContaining('media.example.test'), findsNothing);
          expect(find.text('本地文件'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const Key('nav-2')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('queue-list')), findsOneWidget);
          expect(_play.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets(
    'search failure exposes retry and add to queue does not start playback',
    (tester) async {
      await _withOnline(
        tester,
        run: (fixture) async {
          fixture.repository.failure = '连接超时，请稍后重试。';
          await tester.enterText(find.byKey(const Key('online-query')), '夜色');
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pumpAndSettle();
          expect(find.text('连接超时，请稍后重试。'), findsOneWidget);
          fixture.repository.failure = null;
          await tester.tap(find.text('重试'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('加入播放队列'));
          await tester.pumpAndSettle();
          expect(fixture.player.queue, hasLength(1));
          expect(fixture.player.isPlaying.value, isFalse);
          expect(fixture.backend.loadedUris, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );
}

final _play = find.byKey(const Key('toggle-playback'));

Future<String> _trySourceFieldEdit(
  WidgetTester tester,
  Finder field,
  String text,
) async {
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pump();
  final editable = find.descendant(
    of: field,
    matching: find.byType(EditableText),
  );
  // Exercise the same callback used for incoming platform editing updates.
  // Read-only fields must reject text changes even when they retain focus.
  tester
      .state<EditableTextState>(editable)
      .updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
  await tester.pump();
  return tester.widget<EditableText>(editable).controller.text;
}

Future<void> _sourceAction(WidgetTester tester, String action) async {
  await tester.tap(find.byKey(const Key('online-source-actions')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
}

Future<void> _withOnline(
  WidgetTester tester, {
  required Future<void> Function(_Fixture) run,
  bool empty = false,
  Size size = const Size(1280, 720),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fixture = _Fixture(empty: empty);
  await fixture.online.initialize();
  fixture.controller.onInit();
  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: HanMusicTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: PlayerPage(controller: fixture.controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-3')));
    await tester.pumpAndSettle();
    await run(fixture);
  } finally {
    fixture.controller.onClose();
    fixture.timer.onClose();
    fixture.library.onClose();
    await fixture.online.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.player.shutdown);
    await tester.pump();
  }
}

class _Fixture {
  _Fixture({required bool empty}) {
    store = MemoryOnlineSourceStore(
      sources: empty ? [] : [onlineTestSource()],
      selected: empty ? null : 'demo',
    );
    online = OnlineMusicService(repository: repository, store: store);
    player = PlayerService(backend, resolver: online.resolveForPlayback);
    timer = TimerService(onExpired: player.pause);
    controller = PlayerController(
      player: player,
      timer: timer,
      picker: _NoPicker(),
      library: library,
      online: online,
    );
  }
  final repository = FakeOnlineMusicRepository();
  final backend = FakeAudioBackend();
  final library = LibraryService(
    repository: LocalLibraryRepository(
      artworkDirectory: Directory('D:/dev/tmp/hanmusic-online-widget-artwork'),
    ),
  );
  late final MemoryOnlineSourceStore store;
  late final OnlineMusicService online;
  late final PlayerService player;
  late final TimerService timer;
  late final PlayerController controller;
}

class _NoPicker implements SongPicker {
  @override
  Future<Song?> pick() async => null;
}
