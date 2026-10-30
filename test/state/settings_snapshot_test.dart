import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/app_settings.dart';
import 'package:han_music/app/data/models/library_sort.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customized = AppSettings(
    themeMode: ThemeMode.dark,
    librarySort: LibrarySort.album,
    librarySortDescending: true,
  );

  for (final version in [1, 2, 3, 4]) {
    test('schema $version migrates with the original appearance and sort', () {
      final data = {
        ...const AppSnapshot().toJson(),
        'schemaVersion': version,
        'volume': 0.4,
      }..remove('settings');
      if (version < 4) data.remove('history');
      if (version < 3) data.remove('playlists');
      final restored = AppSnapshot.fromJson(data);
      expect(restored.settings, const AppSettings());
      expect(restored.volume, 0.4);
      expect(restored.toJson()['schemaVersion'], 5);
      expect(restored.toJson()['settings'], const AppSettings().toJson());
      // Older schemas never defined settings, so stray values cannot alter
      // their migration defaults.
      expect(
        AppSnapshot.fromJson({
          ...data,
          'settings': customized.toJson(),
        }).settings,
        const AppSettings(),
      );
    });
  }

  test('schema 5 requires a complete valid settings object', () {
    final data = const AppSnapshot(settings: customized).toJson();
    expect(
      AppSnapshot.fromJson(jsonDecode(jsonEncode(data))).settings,
      customized,
    );
    for (final invalid in <Map<String, dynamic>>[
      {...data}..remove('settings'),
      {...data, 'settings': null},
      {...data, 'settings': []},
      {...data, 'settings': {}},
      {
        ...data,
        'settings': {...customized.toJson(), 'themeMode': 'invalid'},
      },
    ]) {
      expect(() => AppSnapshot.fromJson(invalid), throwsFormatException);
    }
  });

  test(
    'queued saves capture settings and damaged preferences recover backup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hanmusic-settings-state-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileAppStateStore(directory);
      await store.load();
      var settings = customized;
      final saving = store.save(AppSnapshot(settings: settings));
      settings = settings.copyWith(themeMode: ThemeMode.system);
      await saving;
      expect((await FileAppStateStore(directory).load()).settings, customized);
      await store.save(AppSnapshot(settings: settings));
      expect((await FileAppStateStore(directory).load()).settings, settings);
      final primary = File('${directory.path}/state.json');
      await primary.writeAsString(
        jsonEncode({
          ...const AppSnapshot().toJson(),
          'settings': {
            ...customized.toJson(),
            'librarySortDescending': 'false',
          },
        }),
      );
      final recovery = FileAppStateStore(directory);
      final recovered = await recovery.load();
      expect(recovered.settings, customized);
      expect(recovery.warning, contains('备份恢复'));
      await recovery.save(recovered);
      expect((await FileAppStateStore(directory).load()).settings, customized);
    },
  );
}
