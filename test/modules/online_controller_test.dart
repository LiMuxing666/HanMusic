import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/modules/online/controller.dart';
import 'package:han_music/app/services/online_music_service.dart';

import '../support/fake_online_music.dart';

void main() {
  late FakeOnlineMusicRepository repository;
  late MemoryOnlineSourceStore store;
  late OnlineMusicService service;
  late OnlineMusicController controller;
  final played = <Song>[];
  final enqueued = <Song>[];

  setUp(() async {
    repository = FakeOnlineMusicRepository();
    store = MemoryOnlineSourceStore();
    service = OnlineMusicService(repository: repository, store: store);
    await service.initialize();
    played.clear();
    enqueued.clear();
    controller = OnlineMusicController(
      service: service,
      playSong: (song) async => played.add(song),
      enqueueSong: enqueued.add,
    );
  });
  tearDown(() async {
    controller.onClose();
    await service.close();
  });

  test(
    'save tests explicit query, rejects failure and preserves existing source',
    () async {
      final source = onlineTestSource();
      repository.failure = '测试连接失败';
      expect(
        await controller.saveSource(jsonEncode(source.toJson()), '  夏天  '),
        isFalse,
      );
      expect(repository.requests.single.query, '夏天');
      expect(store.saves, 0);
      expect(service.sources, isEmpty);
      expect(controller.actionError.value, '测试连接失败');
      repository.failure = null;
      expect(
        await controller.saveSource(jsonEncode(source.toJson()), '夏天'),
        isTrue,
      );
      expect(service.selectedSourceId.value, source.id);
      repository.failure = '新地址无法连接';
      expect(
        await controller.saveSource(
          jsonEncode(onlineTestSource(name: '新名称').toJson()),
          '秋天',
          originalId: source.id,
        ),
        isFalse,
      );
      expect(service.sources.single.name, source.name);
      expect(store.snapshot.sources.single.name, source.name);
    },
  );

  test(
    'editing validates source identity, maps changes and removes configuration',
    () async {
      final source = onlineTestSource();
      expect(
        await controller.saveSource(jsonEncode(source.toJson()), '测试'),
        isTrue,
      );
      final count = repository.requests.length;
      expect(
        await controller.saveSource(jsonEncode(source.toJson()), '测试'),
        isFalse,
      );
      expect(repository.requests, hasLength(count));
      expect(
        await controller.saveSource(
          jsonEncode(onlineTestSource(id: 'different').toJson()),
          '测试',
          originalId: source.id,
        ),
        isFalse,
      );
      expect(
        await controller.saveSource(
          jsonEncode(onlineTestSource(name: '更新名称').toJson()),
          '测试',
          originalId: source.id,
        ),
        isTrue,
      );
      expect(service.sources.single.name, '更新名称');
      await controller.removeSource(source.id);
      expect(service.sources, isEmpty);
      expect(store.snapshot.sources, isEmpty);
    },
  );

  test(
    'invalid JSON reports an actionable error before any connection attempt',
    () async {
      expect(await controller.saveSource('{broken', '测试'), isFalse);
      expect(controller.actionError.value, contains('配置格式不正确'));
      expect(repository.requests, isEmpty);
      expect(controller.isSaving.value, isFalse);
    },
  );

  test(
    'empty probe preserves playback mapping limitation without redundant selection save',
    () async {
      repository.songsFor = (_, _, _) => [];
      expect(
        await controller.saveSource(
          jsonEncode(onlineTestSource().toJson()),
          '无匹配',
        ),
        isTrue,
      );
      expect(store.saves, 1);
      expect(service.statusMessage.value, contains('播放映射尚未验证'));
      expect(
        await controller.saveSource(
          jsonEncode(onlineTestSource(id: 'second').toJson()),
          '无匹配',
        ),
        isTrue,
      );
      expect(service.selectedSourceId.value, 'second');
      expect(service.statusMessage.value, contains('播放映射尚未验证'));
    },
  );

  test('failed selection after save is not reported as full success', () async {
    expect(
      await controller.saveSource(
        jsonEncode(onlineTestSource().toJson()),
        '测试',
      ),
      isTrue,
    );
    store.failOnSave = store.saves + 2;
    expect(
      await controller.saveSource(
        jsonEncode(onlineTestSource(id: 'second').toJson()),
        '测试',
      ),
      isFalse,
    );
    expect(service.sources, hasLength(2));
    expect(service.selectedSourceId.value, 'demo');
    expect(controller.actionError.value, contains('已保存，但未能切换'));
  });

  for (final lateFailure in [false, true]) {
    test('online opening keeps the latest selection busy after an older '
        '${lateFailure ? 'failure' : 'success'}', () async {
      final a = Song.online(sourceId: 'demo', trackId: 'a', title: '歌曲 A');
      final b = Song.online(sourceId: 'demo', trackId: 'b', title: '歌曲 B');
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();
      final staleError = StateError('Old selection failed');
      Object? firstError;
      controller.onClose();
      controller = OnlineMusicController(
        service: service,
        playSong: (song) {
          played.add(song);
          return song.id == a.id ? firstGate.future : secondGate.future;
        },
        enqueueSong: enqueued.add,
      );
      final pending = <Future<void>>[];
      try {
        pending.add(
          controller.play(a).catchError((Object error) {
            firstError = error;
          }),
        );
        expect(controller.isOpening.value, isTrue);
        expect(controller.openingSongId.value, a.id);

        pending.add(controller.play(b));
        expect(played, [a, b]);
        expect(controller.isOpening.value, isTrue);
        expect(controller.openingSongId.value, b.id);
        var duplicateReturned = false;
        pending.add(
          controller.play(b).then((_) {
            duplicateReturned = true;
          }),
        );
        await Future<void>.delayed(Duration.zero);
        expect(duplicateReturned, isTrue);
        expect(played, [a, b]);

        if (lateFailure) {
          firstGate.completeError(staleError);
        } else {
          firstGate.complete();
        }
        await pending.first;
        expect(firstError, lateFailure ? same(staleError) : isNull);
        expect(secondGate.isCompleted, isFalse);
        expect(controller.isOpening.value, isTrue);
        expect(controller.openingSongId.value, b.id);

        secondGate.complete();
        await pending[1];
        expect(controller.isOpening.value, isFalse);
        expect(controller.openingSongId.value, isNull);
        controller.onClose();
        await controller.play(a);
        await controller.play(b);
        expect(played, [a, b]);
      } finally {
        if (!firstGate.isCompleted) firstGate.complete();
        if (!secondGate.isCompleted) secondGate.complete();
        await Future.wait(pending);
      }
    });
  }

  test(
    'play and enqueue preserve stable song identity and stop after disposal',
    () async {
      final song = Song.online(
        sourceId: 'demo',
        trackId: 'track-1',
        title: '测试音乐',
      );
      await controller.play(song);
      controller.enqueue(song);
      expect(played, [song]);
      expect(enqueued, [song]);
      controller.onClose();
      await controller.play(song);
      controller.enqueue(song);
      expect(played, hasLength(1));
      expect(enqueued, hasLength(1));
    },
  );
}
