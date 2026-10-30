import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/app_settings.dart';
import 'package:han_music/app/data/models/library_sort.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/services/app_settings_service.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

import '../support/fake_audio_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlayerService player;
  late TimerService timer;
  late LibraryService library;
  final controllers = <PlayerController>[];
  final services = <AppSettingsService>[];

  PlayerController controllerFor(
    AppSettingsService? settings, {
    bool start = true,
  }) {
    final controller = PlayerController(
      player: player,
      timer: timer,
      picker: _NoPicker(),
      library: library,
      settings: settings,
    );
    controllers.add(controller);
    if (start) controller.onStart();
    return controller;
  }

  _CountingSettings settingsFor([AppSettings initial = const AppSettings()]) {
    final settings = _CountingSettings(initial: initial);
    services.add(settings);
    return settings;
  }

  setUp(() {
    controllers.clear();
    services.clear();
    player = PlayerService(FakeAudioBackend());
    timer = TimerService(onExpired: player.pause);
    library = LibraryService(
      repository: LocalLibraryRepository(
        artworkDirectory: Directory.systemTemp,
      ),
    );
    library.replaceAll([_song('zulu'), _song('alpha'), _song('mike')]);
  });

  tearDown(() async {
    for (final controller in controllers) {
      controller.onDelete();
    }
    for (final settings in services) {
      settings.onClose();
    }
    library.onClose();
    timer.onClose();
    await player.shutdown();
  });

  test(
    'constructor restores sorting immediately and onInit accepts a later restore without writes',
    () {
      final settings = settingsFor(
        const AppSettings(
          themeMode: ThemeMode.dark,
          librarySort: LibrarySort.title,
          librarySortDescending: true,
        ),
      );
      final controller = controllerFor(settings, start: false);
      expect(controller.librarySort.value, LibrarySort.title);
      expect(controller.librarySortDescending.value, isTrue);
      expect(controller.visibleSongs.map((song) => song.title), [
        'zulu',
        'mike',
        'alpha',
      ]);
      settings.restore(const AppSettings(librarySort: LibrarySort.album));
      controller.onStart();
      expect(controller.librarySort.value, LibrarySort.album);
      expect(controller.librarySortDescending.value, isFalse);
      expect(settings.sortWrites, 0);
      expect(settings.directionWrites, 0);
    },
  );

  test(
    'controller methods and legacy Rx writes synchronize once without changing theme',
    () {
      final settings = settingsFor(
        const AppSettings(themeMode: ThemeMode.dark),
      );
      final controller = controllerFor(settings);
      controller.setLibrarySort(LibrarySort.title);
      controller.setLibrarySort(LibrarySort.title);
      expect(settings.sortWrites, 1);
      expect(settings.settings.value.librarySort, LibrarySort.title);
      controller.toggleLibrarySortDirection();
      expect(settings.directionWrites, 1);
      expect(settings.settings.value.librarySortDescending, isTrue);
      controller.librarySort.value = LibrarySort.artist;
      controller.librarySortDescending.value = false;
      controller.librarySort.value = LibrarySort.artist;
      controller.librarySortDescending.value = false;
      expect(settings.sortWrites, 2);
      expect(settings.directionWrites, 2);
      expect(settings.settings.value.librarySort, LibrarySort.artist);
      expect(settings.settings.value.librarySortDescending, isFalse);
      expect(settings.settings.value.themeMode, ThemeMode.dark);
    },
  );

  test(
    'external updates synchronize both sort fields without echo and reset range order',
    () {
      final settings = settingsFor();
      final controller = controllerFor(settings);
      final alpha = library.songs[1];
      final mike = library.songs[2];
      controller.selectLibrarySong(alpha);
      settings.restore(
        const AppSettings(
          themeMode: ThemeMode.system,
          librarySort: LibrarySort.title,
          librarySortDescending: true,
        ),
      );
      expect(controller.visibleSongs.map((song) => song.title), [
        'zulu',
        'mike',
        'alpha',
      ]);
      expect(controller.selectedLibrarySongs, [alpha]);
      controller.selectLibrarySong(mike, toggle: false, range: true);
      expect(controller.selectedLibrarySongs, [mike]);
      expect(settings.sortWrites, 0);
      expect(settings.directionWrites, 0);
      settings.setThemeMode(ThemeMode.dark);
      expect(controller.librarySort.value, LibrarySort.title);
      expect(controller.librarySortDescending.value, isTrue);
      expect(settings.sortWrites, 0);
      expect(settings.directionWrites, 0);
    },
  );

  test(
    'saved settings survive controller recreation and closed controllers detach without owning the service',
    () {
      final settings = settingsFor();
      final first = controllerFor(settings);
      first.setLibrarySort(LibrarySort.title);
      first.toggleLibrarySortDirection();
      final saved = settings.settings.value;
      first.onDelete();
      settings.setLibrarySort(LibrarySort.artist);
      expect(settings.settings.value.librarySort, LibrarySort.artist);
      expect(first.librarySort.value, LibrarySort.title);
      first.librarySort.value = LibrarySort.album;
      expect(settings.settings.value.librarySort, LibrarySort.artist);
      first.toggleLibrarySortDirection();
      expect(first.librarySortDescending.value, isTrue);
      final restartedSettings = settingsFor(saved);
      final restarted = controllerFor(restartedSettings);
      expect(restarted.librarySort.value, LibrarySort.title);
      expect(restarted.librarySortDescending.value, isTrue);
      expect(restarted.visibleSongs.map((song) => song.title), [
        'zulu',
        'mike',
        'alpha',
      ]);
    },
  );

  test(
    'exit guards setters and direct Rx persistence; cancel resumes changes',
    () {
      final settings = settingsFor(
        const AppSettings(librarySort: LibrarySort.title),
      );
      final controller = controllerFor(settings);
      controller.beginExit();
      controller.setLibrarySort(LibrarySort.artist);
      controller.toggleLibrarySortDirection();
      controller.librarySort.value = LibrarySort.album;
      controller.librarySortDescending.value = true;
      expect(controller.librarySort.value, LibrarySort.title);
      expect(controller.librarySortDescending.value, isFalse);
      expect(settings.settings.value.librarySort, LibrarySort.title);
      expect(settings.settings.value.librarySortDescending, isFalse);
      expect(settings.sortWrites, 0);
      expect(settings.directionWrites, 0);
      // External ownership still permits a restore; the controller must not echo it.
      settings.restore(
        const AppSettings(
          librarySort: LibrarySort.artist,
          librarySortDescending: true,
        ),
      );
      expect(controller.librarySort.value, LibrarySort.artist);
      expect(controller.librarySortDescending.value, isTrue);
      expect(settings.sortWrites, 0);
      expect(settings.directionWrites, 0);
      controller.cancelExit();
      controller.setLibrarySort(LibrarySort.album);
      controller.toggleLibrarySortDirection();
      expect(settings.settings.value.librarySort, LibrarySort.album);
      expect(settings.settings.value.librarySortDescending, isFalse);
      expect(settings.sortWrites, 1);
      expect(settings.directionWrites, 1);
    },
  );

  test(
    'controllers without a settings service keep default and legacy Rx behavior',
    () {
      final controller = controllerFor(null);
      expect(controller.settings, isNull);
      expect(controller.librarySort.value, LibrarySort.importOrder);
      expect(controller.librarySortDescending.value, isFalse);
      controller.setLibrarySort(LibrarySort.title);
      controller.toggleLibrarySortDirection();
      expect(controller.visibleSongs.map((song) => song.title), [
        'zulu',
        'mike',
        'alpha',
      ]);
      controller.librarySort.value = LibrarySort.importOrder;
      expect(controller.visibleSongs.map((song) => song.title), [
        'mike',
        'alpha',
        'zulu',
      ]);
      controller.beginExit();
      controller.setLibrarySort(LibrarySort.album);
      controller.toggleLibrarySortDirection();
      expect(controller.librarySort.value, LibrarySort.importOrder);
      expect(controller.librarySortDescending.value, isTrue);
      controller.onDelete();
      controller.setLibrarySort(LibrarySort.artist);
      expect(controller.librarySort.value, LibrarySort.importOrder);
    },
  );
}

class _CountingSettings extends AppSettingsService {
  _CountingSettings({required super.initial});
  int sortWrites = 0;
  int directionWrites = 0;

  @override
  void setLibrarySort(LibrarySort value) {
    sortWrites++;
    super.setLibrarySort(value);
  }

  @override
  void setLibrarySortDescending(bool value) {
    directionWrites++;
    super.setLibrarySortDescending(value);
  }
}

Song _song(String name) => Song(
  uri: Uri.file('D:/music/$name.mp3', windows: true),
  fileName: '$name.mp3',
);

class _NoPicker implements SongPicker {
  @override
  Future<Song?> pick() async => null;
}
