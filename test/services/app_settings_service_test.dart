import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:han_music/app/data/models/app_settings.dart';
import 'package:han_music/app/data/models/library_sort.dart';
import 'package:han_music/app/services/app_settings_service.dart';

void main() {
  test(
    'settings defaults and value copies round trip every supported option',
    () {
      const defaults = AppSettings();
      expect(defaults.themeMode, ThemeMode.light);
      expect(defaults.librarySort, LibrarySort.importOrder);
      expect(defaults.librarySortDescending, isFalse);
      for (final theme in ThemeMode.values) {
        for (final sort in LibrarySort.values) {
          for (final descending in [false, true]) {
            final settings = defaults.copyWith(
              themeMode: theme,
              librarySort: sort,
              librarySortDescending: descending,
            );
            final restored = AppSettings.fromJson(settings.toJson());
            expect(restored, settings);
            expect(restored.hashCode, settings.hashCode);
            expect(settings.copyWith(), settings);
            expect(settings.themeMode, theme);
            expect(settings.librarySort, sort);
            expect(settings.librarySortDescending, descending);
          }
        }
      }
      expect(defaults, const AppSettings());
      expect(defaults.copyWith(themeMode: ThemeMode.dark), isNot(defaults));
      expect(
        defaults.copyWith(librarySort: LibrarySort.title),
        isNot(defaults),
      );
      expect(defaults.copyWith(librarySortDescending: true), isNot(defaults));
      expect(
        defaults
            .copyWith(librarySortDescending: true)
            .copyWith(librarySortDescending: false),
        defaults,
      );
    },
  );

  test(
    'settings reject missing, unknown and incorrectly typed preferences',
    () {
      final valid = const AppSettings().toJson();
      for (final key in valid.keys) {
        expect(
          () => AppSettings.fromJson({...valid}..remove(key)),
          throwsFormatException,
        );
      }
      for (final invalid in <Map<String, dynamic>>[
        {...valid, 'themeMode': 'sepia'},
        {...valid, 'themeMode': 0},
        {...valid, 'themeMode': null},
        {...valid, 'librarySort': 'random'},
        {...valid, 'librarySort': 0},
        {...valid, 'librarySort': null},
        {...valid, 'librarySortDescending': 'false'},
        {...valid, 'librarySortDescending': 0},
        {...valid, 'librarySortDescending': null},
        {...valid, 'unknownSetting': true},
      ]) {
        expect(() => AppSettings.fromJson(invalid), throwsFormatException);
      }
    },
  );

  test('service updates synchronously, deduplicates and stops after close', () {
    const initial = AppSettings(
      themeMode: ThemeMode.system,
      librarySort: LibrarySort.artist,
      librarySortDescending: true,
    );
    final service = AppSettingsService(initial: initial);
    addTearDown(service.onClose);
    final observed = <AppSettings>[];
    final worker = ever(service.settings, observed.add);
    addTearDown(worker.dispose);
    expect(service.settings.value, initial);
    service.restore(initial.copyWith());
    expect(observed, isEmpty);
    service.setThemeMode(ThemeMode.dark);
    expect(service.settings.value, initial.copyWith(themeMode: ThemeMode.dark));
    service.setLibrarySort(LibrarySort.album);
    service.setLibrarySortDescending(false);
    expect(observed, hasLength(3));
    expect(
      service.settings.value,
      const AppSettings(
        themeMode: ThemeMode.dark,
        librarySort: LibrarySort.album,
      ),
    );
    service.restore(const AppSettings());
    expect(service.settings.value, const AppSettings());
    expect(observed, hasLength(4));
    service.onClose();
    service.setThemeMode(ThemeMode.system);
    service.setLibrarySort(LibrarySort.title);
    service.setLibrarySortDescending(true);
    service.restore(initial);
    expect(service.settings.value, const AppSettings());
    expect(observed, hasLength(4));
  });
}
