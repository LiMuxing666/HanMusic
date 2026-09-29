import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/play_mode.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';

import '../../tool/windows_m5_restart_probe.dart';

void main() {
  const root = r'D:\dev\tmp\hanmusic-m5-restart-test01';
  final local = Song(
    uri: Uri.file('$root/music/local.flac', windows: true),
    fileName: 'local.flac',
    duration: const Duration(milliseconds: 100),
  );
  final missing = Song(
    uri: Uri.file('$root/music/missing.flac', windows: true),
    fileName: 'missing.flac',
    isMissing: true,
  );
  final online = Song.online(
    sourceId: 'fixture',
    trackId: 'remote',
    title: 'Online',
  );
  Map<String, dynamic> expected() => {
    'libraryCount': 2,
    'queueIds': [local.id, online.id, missing.id],
    'currentId': local.id,
    'positionMs': 42,
    'mode': 'shuffle',
    'volume': .37,
    'skipOnError': false,
    'missingIds': [missing.id],
  };
  AppSnapshot snapshot({
    List<Song>? queue,
    int position = 42,
    double volume = .37,
    List<Song>? songs,
  }) => AppSnapshot(
    songs: songs ?? [local, missing],
    queue: queue ?? [local, online, missing],
    currentId: local.id,
    position: Duration(milliseconds: position),
    mode: PlayMode.shuffle,
    volume: volume,
    skipOnError: false,
  );

  test('controlled D paths require matching data/results children', () {
    final paths = RestartProbePaths.parse('$root/data', '$root/results');
    expect(paths.root, root);
    expect(paths.contains('$root/music/中文 文件.flac'), isTrue);
    expect(paths.contains('${root}2/music/file.flac'), isFalse);
    expect(paths.contains('$root/music/../../outside.flac'), isFalse);
    expect(paths.contains(r'C:\Users\someone\music.flac'), isFalse);
  });

  test(
    'environment guards reject missing, relative and unrelated directories',
    () {
      for (final input in [
        (null, '$root/results'),
        ('data', '$root/results'),
        (r'C:\dev\tmp\hanmusic-m5-restart-test01\data', '$root/results'),
        (r'D:\dev\data\HanMusic', '$root/results'),
        ('$root/data', '$root/other'),
        ('$root/data', '${root}2/results'),
        ('$root/../hanmusic-m5-restart-other/data', '$root/results'),
      ]) {
        expect(
          () => RestartProbePaths.parse(input.$1, input.$2),
          throwsFormatException,
        );
      }
    },
  );

  test('path guard handles Windows case aliases consistently', () {
    final paths = RestartProbePaths.parse(
      '$root/data'.toUpperCase(),
      '$root/results',
    );
    expect(paths.contains('$root/music/local.flac'), isTrue);
  });

  test(
    'snapshot expectation checks mixed queue and missing library entries',
    () {
      final expectation = RestartProbeExpectation.fromJson(expected());
      expect(() => expectation.verify(snapshot()), returnsNormally);
      expect(
        () => expectation.verify(snapshot(queue: [online, local, missing])),
        throwsStateError,
      );
      expect(
        () => expectation.verify(snapshot(position: 73)),
        throwsStateError,
      );
      expect(() => expectation.verify(snapshot(volume: .22)), throwsStateError);
      expect(
        () => expectation.verify(
          snapshot(songs: [local, missing.copyWith(isMissing: false)]),
        ),
        throwsStateError,
      );
    },
  );

  test('invalid expectations cannot silently normalize a broken fixture', () {
    final invalid = <Map<String, dynamic>>[
      {...expected(), 'libraryCount': 0},
      {...expected(), 'positionMs': -1},
      {...expected(), 'volume': double.nan},
      {...expected(), 'volume': 2},
      {...expected(), 'mode': 'unknown'},
      {...expected(), 'currentId': 'absent'},
      {
        ...expected(),
        'queueIds': [local.id, local.id],
      },
      {
        ...expected(),
        'missingIds': [missing.id, missing.id],
      },
    ];
    for (final value in invalid) {
      expect(
        () => RestartProbeExpectation.fromJson(value),
        throwsFormatException,
      );
    }
  });
}
