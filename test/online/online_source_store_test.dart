import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/repositories/online_source_store.dart';

import 'online_test_support.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hanmusic-online-store-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('awaited writes persist only source config and selection', () async {
    final store = FileOnlineSourceStore(directory);
    expect((await store.load()).sources, isEmpty);
    await store.save(
      OnlineSourceSnapshot(sources: [source()], selectedSourceId: 'demo'),
    );
    final restored = await FileOnlineSourceStore(directory).load();
    expect(restored.sources.single.id, 'demo');
    expect(restored.selectedSourceId, 'demo');
    final raw = await File('${directory.path}/sources.json').readAsString();
    expect(raw, isNot(contains('temporary')));
    expect(jsonDecode(raw)['schemaVersion'], 1);
  });

  test(
    'concurrent saves serialize and backup contains prior known-good config',
    () async {
      final store = FileOnlineSourceStore(directory);
      await store.load();
      await Future.wait([
        store.save(
          OnlineSourceSnapshot(
            sources: [source(id: 'a')],
            selectedSourceId: 'a',
          ),
        ),
        store.save(
          OnlineSourceSnapshot(
            sources: [source(id: 'b')],
            selectedSourceId: 'b',
          ),
        ),
      ]);
      expect(
        (await FileOnlineSourceStore(directory).load()).selectedSourceId,
        'b',
      );
      final backup = jsonDecode(
        await File('${directory.path}/sources.backup.json').readAsString(),
      );
      expect(backup['selectedSourceId'], 'a');
    },
  );

  test(
    'corrupt primary recovers backup and next write keeps recovered snapshot',
    () async {
      final store = FileOnlineSourceStore(directory);
      await store.load();
      await store.save(
        OnlineSourceSnapshot(
          sources: [source(id: 'a')],
          selectedSourceId: 'a',
        ),
      );
      await store.save(
        OnlineSourceSnapshot(
          sources: [source(id: 'b')],
          selectedSourceId: 'b',
        ),
      );
      await File('${directory.path}/sources.json').writeAsString('corrupt');
      final recovered = FileOnlineSourceStore(directory);
      expect((await recovered.load()).selectedSourceId, 'a');
      expect(recovered.warning, contains('备份恢复'));
      await recovered.save(
        OnlineSourceSnapshot(
          sources: [source(id: 'c')],
          selectedSourceId: 'c',
        ),
      );
      final backup = jsonDecode(
        await File('${directory.path}/sources.backup.json').readAsString(),
      );
      expect(backup['selectedSourceId'], 'a');
    },
  );

  test(
    'new schema is protected and not downgraded through an older backup',
    () async {
      final primary = File('${directory.path}/sources.json');
      await primary.writeAsString('{"schemaVersion":2,"future":"preserve"}');
      await File(
        '${directory.path}/sources.backup.json',
      ).writeAsString(jsonEncode(const OnlineSourceSnapshot().toJson()));
      final store = FileOnlineSourceStore(directory);
      expect((await store.load()).sources, isEmpty);
      expect(store.warning, contains('较新版本'));
      await expectLater(
        store.save(const OnlineSourceSnapshot()),
        throwsStateError,
      );
      expect(await primary.readAsString(), contains('preserve'));
    },
  );

  test('a future nested source schema also protects the outer file', () async {
    final json = sourceJson()..['schemaVersion'] = 2;
    await File('${directory.path}/sources.json').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'sources': [json],
        'selectedSourceId': 'demo',
      }),
    );
    final store = FileOnlineSourceStore(directory);
    await store.load();
    expect(store.warning, contains('较新版本'));
    await expectLater(
      store.save(const OnlineSourceSnapshot()),
      throwsStateError,
    );
  });

  test('two invalid files are preserved and writes blocked', () async {
    for (final name in ['sources.json', 'sources.backup.json']) {
      await File('${directory.path}/$name').writeAsString('original-$name');
    }
    final store = FileOnlineSourceStore(directory);
    await store.load();
    expect(store.warning, contains('均无法读取'));
    await expectLater(
      store.save(const OnlineSourceSnapshot()),
      throwsStateError,
    );
    expect(
      await File('${directory.path}/sources.json').readAsString(),
      'original-sources.json',
    );
  });

  test(
    'snapshot rejects duplicate IDs missing selections and secret fields',
    () {
      expect(
        () => OnlineSourceSnapshot(sources: [source(), source()]).toJson(),
        throwsFormatException,
      );
      expect(
        () => const OnlineSourceSnapshot(selectedSourceId: 'missing').toJson(),
        throwsFormatException,
      );
      expect(
        () => OnlineSourceSnapshot.fromJson({
          'schemaVersion': 1,
          'sources': [],
          'token': 'secret',
        }),
        throwsFormatException,
      );
    },
  );
}
