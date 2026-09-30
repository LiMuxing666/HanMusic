import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/online_source_config.dart';
import 'package:han_music/app/data/models/playback_source_exception.dart';
import 'package:han_music/app/data/repositories/online_music_repository.dart';
import 'package:han_music/app/data/repositories/online_source_store.dart';
import 'package:han_music/app/services/online_music_service.dart';

import 'online_test_support.dart';

void main() {
  late ControlledRepository repository;
  late MemorySourceStore store;
  late OnlineMusicService service;
  setUp(() async {
    repository = ControlledRepository();
    store = MemorySourceStore(
      OnlineSourceSnapshot(
        sources: [
          source(),
          source(id: 'other'),
        ],
        selectedSourceId: 'demo',
      ),
    );
    service = OnlineMusicService(repository: repository, store: store);
    await service.initialize();
  });
  tearDown(() => service.close());

  test('initialization surfaces a protected/recovered store warning', () async {
    store.warning = '保护原配置';
    await service.initialize();
    expect(service.statusMessage.value, '保护原配置');
  });

  test('debounce sends only the latest query after 500 ms', () async {
    service.setQuery('first');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    service.setQuery('latest');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(repository.queries, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(repository.queries, ['latest']);
  });

  test(
    'late old search cannot overwrite newer search even if transport ignores cancel',
    () async {
      final old = Completer<OnlineSearchPage>();
      repository.onSearch = (_, query, _) async => query == 'old'
          ? old.future
          : OnlineSearchPage(songs: [onlineSong('new')], hasMore: false);
      final previous = service.searchNow('old');
      await service.searchNow('new');
      old.complete(OnlineSearchPage(songs: [onlineSong('old')], hasMore: true));
      await previous;
      expect(service.results.single.trackId, 'new');
      expect(service.hasMore.value, isFalse);
      expect(repository.cancellations.first!.isCancelled, isTrue);
    },
  );

  test('switching source drops old results and late old errors', () async {
    final old = Completer<OnlineSearchPage>();
    repository.onSearch = (_, _, _) => old.future;
    final previous = service.searchNow('old');
    await service.selectSource('other');
    old.completeError(const OnlineMusicException('旧错误'));
    await previous;
    expect(service.selectedSourceId.value, 'other');
    expect(service.results, isEmpty);
    expect(service.errorMessage.value, isNull);
    expect(service.isSearching.value, isFalse);
  });

  test('load more deduplicates and ends repeated-page pagination', () async {
    repository.onSearch = (_, _, page) async => OnlineSearchPage(
      songs: [onlineSong('1'), if (page > 0) onlineSong('2')],
      hasMore: true,
    );
    await service.searchNow('music');
    await service.loadMore();
    expect(service.results.map((song) => song.trackId), ['1', '2']);
    await service.loadMore();
    expect(service.hasMore.value, isFalse);
    await service.loadMore();
    expect(repository.queries.length, 3);
  });

  test('draft connection test checks playback and does not save', () async {
    repository.onSearch = (config, _, _) async => OnlineSearchPage(
      songs: [onlineSong('one', sourceId: config.id)],
      hasMore: false,
    );
    var resolves = 0;
    repository.onResolve = (_, _) async {
      resolves++;
      return Uri.parse('https://example.invalid/music');
    };
    expect(
      await service.testConfig(source(id: 'draft'), query: '自定义词'),
      isTrue,
    );
    expect(repository.queries, ['自定义词']);
    expect(resolves, 1);
    expect(store.writes, 0);
    expect(service.sources.length, 2);
  });

  test(
    'empty connection test can save while retaining unverified playback wording',
    () async {
      expect(
        await service.upsertSource(source(id: 'new'), testQuery: '空词'),
        isTrue,
      );
      expect(service.statusMessage.value, contains('播放映射尚未验证'));
      expect(store.snapshot.sources.length, 3);
    },
  );

  test('failed test or disk write retains original in-memory source', () async {
    final json = sourceJson()..['name'] = 'edited';
    final edited = OnlineSourceConfig.fromJson(json);
    repository.onSearch = (_, _, _) async =>
        throw const OnlineMusicException('连接失败');
    expect(await service.upsertSource(edited), isFalse);
    expect(store.writes, 0);
    expect(service.selectedSource!.name, '测试源 demo');
    repository.onSearch = null;
    store.failWrites = true;
    expect(await service.upsertSource(edited), isFalse);
    expect(service.selectedSource!.name, '测试源 demo');
    expect(service.errorMessage.value, isNot(contains('private disk detail')));
  });

  test('failed remove or selection write preserves active source', () async {
    store.failWrites = true;
    await service.selectSource('other');
    expect(service.selectedSourceId.value, 'demo');
    await service.removeSource('demo');
    expect(service.sources.length, 2);
    expect(service.selectedSourceId.value, 'demo');
  });

  test(
    'exit checkpoint reports a pending failed save without closing service',
    () async {
      store.writeGate = Completer<void>();
      store.writeStarted = Completer<void>();
      final saving = service.upsertSource(source(id: 'draft'));
      await store.writeStarted!.future;
      final checkpoint = service.flushPendingMutations();
      store.failWrites = true;
      store.writeGate!.complete();
      expect(await saving, isFalse);
      expect(await checkpoint, isFalse);
      expect(service.sources.map((item) => item.id), ['demo', 'other']);

      store.failWrites = false;
      store.writeGate = null;
      expect(await service.upsertSource(source(id: 'retry')), isTrue);
      expect(await service.flushPendingMutations(), isTrue);
      expect(store.snapshot.sources.last.id, 'retry');
    },
  );

  for (final removing in [false, true]) {
    test(
      'exit checkpoint observes pending ${removing ? 'removal' : 'selection'} failure',
      () async {
        store.writeGate = Completer<void>();
        store.writeStarted = Completer<void>();
        final changing = removing
            ? service.removeSource('demo')
            : service.selectSource('other');
        await store.writeStarted!.future;
        final checkpoint = service.flushPendingMutations();
        store.failWrites = true;
        store.writeGate!.complete();
        await changing;
        expect(await checkpoint, isFalse);
        expect(service.selectedSourceId.value, 'demo');
        expect(service.sources, hasLength(2));
        // The failure is already delivered; a later close is not permanently
        // blocked merely because this user operation failed in the past.
        expect(await service.flushPendingMutations(), isTrue);
      },
    );
  }

  test(
    'exit checkpoint ignores already reported test and disk failures',
    () async {
      repository.onSearch = (_, _, _) async =>
          throw const OnlineMusicException('测试失败');
      expect(await service.upsertSource(source(id: 'draft')), isFalse);
      expect(await service.flushPendingMutations(), isTrue);
      repository.onSearch = null;
      store.failWrites = true;
      expect(await service.upsertSource(source(id: 'draft')), isFalse);
      expect(await service.flushPendingMutations(), isTrue);
    },
  );

  test(
    'exit checkpoint drains selection queued by a successful save caller',
    () async {
      final firstGate = store.writeGate = Completer<void>();
      store.writeStarted = Completer<void>();
      final saving = service.upsertSource(source(id: 'draft'));
      await store.writeStarted!.future;
      final secondStarted = Completer<void>();
      final secondGate = Completer<void>();
      final caller = saving.then((saved) async {
        expect(saved, isTrue);
        store.writeGate = secondGate;
        store.writeStarted = secondStarted;
        await service.selectSource('draft');
      });
      var drained = false;
      final checkpoint = service.flushPendingMutations().then((value) {
        drained = true;
        return value;
      });
      firstGate.complete();
      await secondStarted.future;
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      secondGate.complete();
      await caller;
      expect(await checkpoint, isTrue);
      expect(store.snapshot.selectedSourceId, 'draft');
    },
  );

  test(
    'checkpoint timeout leaves late commit and a queued retry usable',
    () async {
      final gate = store.writeGate = Completer<void>();
      store.writeStarted = Completer<void>();
      final saving = service.upsertSource(source(id: 'draft'));
      await store.writeStarted!.future;
      final checkpoint = service.flushPendingMutations();
      await expectLater(
        checkpoint.timeout(const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
      final retry = service.upsertSource(
        OnlineSourceConfig.fromJson(
          sourceJson(id: 'draft')..['name'] = 'later edit',
        ),
      );
      gate.complete();
      expect(await saving, isTrue);
      expect(await retry, isTrue);
      expect(await checkpoint, isTrue);
      expect(store.snapshot.sources.last.name, 'later edit');
      expect(await service.flushPendingMutations(), isTrue);
    },
  );

  test(
    'checkpoint retains an immediate failure from a save continuation',
    () async {
      final gate = store.writeGate = Completer<void>();
      store.writeStarted = Completer<void>();
      final saving = service.upsertSource(source(id: 'draft'));
      await store.writeStarted!.future;
      final caller = saving.then((saved) async {
        expect(saved, isTrue);
        store.writeGate = null;
        store.failWrites = true;
        await service.selectSource('draft');
      });
      final checkpoint = service.flushPendingMutations();
      gate.complete();
      await caller;
      expect(service.errorMessage.value, contains('保存网络源选择失败'));
      expect(await checkpoint, isFalse);
      expect(await service.flushPendingMutations(), isTrue);
    },
  );

  test(
    'deleting a source cancels its draft test and prevents stale save',
    () async {
      final response = Completer<OnlineSearchPage>();
      final started = Completer<void>();
      repository.onSearch = (_, _, _) {
        started.complete();
        return response.future;
      };
      final save = service.upsertSource(source());
      await started.future;
      final removal = service.removeSource('demo');
      response.complete(const OnlineSearchPage(songs: [], hasMore: false));
      expect(await save, isFalse);
      await removal;
      expect(service.sources.map((value) => value.id), ['other']);
      expect(service.statusMessage.value, contains('已删除'));
      expect(service.isTesting.value, isFalse);
    },
  );

  test(
    'removed source rejects playback and late pending URL never escapes',
    () async {
      final response = Completer<Uri>();
      repository.onResolve = (_, _) => response.future;
      final pending = service.resolveForPlayback(onlineSong('one'));
      final expectation = expectLater(
        pending,
        throwsA(isA<PlaybackSourceException>()),
      );
      await service.removeSource('demo');
      response.complete(Uri.parse('https://secret.invalid/temporary'));
      await expectation;
      await expectLater(
        service.resolveForPlayback(onlineSong('one')),
        throwsA(isA<PlaybackSourceException>()),
      );
    },
  );

  test(
    'search and resolve started during source disk write are invalidated at commit',
    () async {
      final edited = OnlineSourceConfig.fromJson(
        sourceJson()..['name'] = 'edited',
      );
      store.writeGate = Completer<void>();
      store.writeStarted = Completer<void>();
      final save = service.upsertSource(edited);
      await store.writeStarted!.future;
      expect(service.selectedSource!.name, '测试源 demo');
      final lateSearch = Completer<OnlineSearchPage>();
      final lateResolve = Completer<Uri>();
      repository.onSearch = (_, _, _) => lateSearch.future;
      repository.onResolve = (_, _) => lateResolve.future;
      final search = service.searchNow('during-write');
      final resolve = service.resolveForPlayback(onlineSong('one'));
      final failedResolve = expectLater(
        resolve,
        throwsA(isA<PlaybackSourceException>()),
      );
      store.writeGate!.complete();
      expect(await save, isTrue);
      expect(service.selectedSource!.name, 'edited');
      lateSearch.complete(
        OnlineSearchPage(songs: [onlineSong('old')], hasMore: true),
      );
      lateResolve.complete(Uri.parse('https://old.invalid/temporary'));
      await search;
      await failedResolve;
      expect(service.results, isEmpty);
      expect(service.hasMore.value, isFalse);
    },
  );

  test('commit invalidation does not cancel a newer queued edit', () async {
    store.writeGate = Completer<void>();
    store.writeStarted = Completer<void>();
    final first = service.upsertSource(
      OnlineSourceConfig.fromJson(sourceJson()..['name'] = 'first'),
    );
    await store.writeStarted!.future;
    final second = service.upsertSource(
      OnlineSourceConfig.fromJson(sourceJson()..['name'] = 'second'),
    );
    store.writeGate!.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(service.selectedSource!.name, 'second');
    expect(store.snapshot.sources.first.name, 'second');
  });

  test(
    'late draft test after source selection cannot replace current status',
    () async {
      final response = Completer<OnlineSearchPage>();
      repository.onSearch = (_, _, _) => response.future;
      final test = service.testConfig(source(id: 'draft'));
      await service.selectSource('other');
      response.complete(const OnlineSearchPage(songs: [], hasMore: false));
      expect(await test, isFalse);
      expect(service.statusMessage.value, '已选择网络源。');
    },
  );

  test(
    'real service search and resolve use a controlled HTTP source',
    () async {
      final api = await LoopbackApi.start((request) async {
        if (request.uri.path == '/play') {
          await respond(request, {
            'data': {'url': 'https://cdn.invalid/stream?temporary=private'},
          });
        } else {
          await respond(request, apiPage([apiTrack('one')]));
        }
      });
      addTearDown(api.close);
      final realStore = MemorySourceStore();
      final realService = OnlineMusicService(
        repository: OnlineMusicRepository(),
        store: realStore,
      );
      addTearDown(realService.close);
      await realService.initialize();
      expect(
        await realService.upsertSource(
          source(baseUrl: api.base.toString()),
          testQuery: '音乐',
        ),
        isTrue,
      );
      await realService.searchNow('中文');
      expect(realService.results.single.title, '测试歌曲');
      final uri = await realService.resolveForPlayback(
        realService.results.single,
      );
      expect(uri.queryParameters['temporary'], 'private');
      expect(
        realStore.snapshot.toJson().toString(),
        isNot(contains('cdn.invalid')),
      );
    },
  );

  test('close cancels debounce and pending resolve rejects safely', () async {
    final response = Completer<Uri>();
    repository.onResolve = (_, _) => response.future;
    final work = service.resolveForPlayback(onlineSong('one'));
    final failed = expectLater(work, throwsA(isA<PlaybackSourceException>()));
    service.setQuery('not-sent');
    await service.close();
    response.complete(Uri.parse('https://secret.invalid/temp'));
    await failed;
    expect(repository.queries, isEmpty);
    expect(await service.upsertSource(source(id: 'never')), isFalse);
  });
}
