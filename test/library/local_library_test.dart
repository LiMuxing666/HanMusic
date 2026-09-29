import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late Directory artwork;
  final services = <LibraryService>[];
  setUp(() async {
    final base = Directory('build/library-test-tmp');
    await base.create(recursive: true);
    temporary = await base.createTemp('case-');
    artwork = Directory(p.join(temporary.path, 'artwork'));
  });
  tearDown(() async {
    for (final service in services) {
      service.onClose();
    }
    services.clear();
    await temporary.delete(recursive: true);
  });

  LibraryService create({
    MetadataReader? reader,
    Duration timeout = const Duration(seconds: 5),
  }) {
    final service = LibraryService(
      repository: LocalLibraryRepository(
        artworkDirectory: artwork,
        metadataReader: reader,
        metadataTimeout: timeout,
      ),
    );
    services.add(service);
    return service;
  }

  Future<File> fixture(String extension, {String? name}) async {
    final target = File(p.join(temporary.path, name ?? 'tagged.$extension'));
    await target.parent.create(recursive: true);
    return File('test/library/fixtures/tagged.$extension').copy(target.path);
  }

  test(
    'real MP3/FLAC/WAV tags and MP3/FLAC cover images are read in worker',
    () async {
      final files = [
        await fixture('mp3'),
        await fixture('flac'),
        await fixture('wav'),
      ];
      final originals = <String, List<int>>{
        for (final file in files)
          p.basename(file.path): await file.readAsBytes(),
      };
      final service = create();
      final imported = await service.importPaths(
        files.map((file) => file.path).toList(),
      );
      expect(imported, hasLength(3));
      expect(service.errorCount.value, 0);
      expect(service.warningCount.value, 0);
      for (final song in imported) {
        expect(song.title, 'Fixture ${song.extension}');
        expect(song.artist, 'HanMusic Tests');
        expect(song.album, 'Generated Samples');
        expect(song.duration, isNotNull, reason: song.fileName);
        expect(song.duration!, greaterThan(Duration.zero));
        expect(
          await File.fromUri(song.uri).readAsBytes(),
          originals[song.fileName],
        );
        if (song.extension != 'WAV') {
          expect(song.artworkPath, isNotNull);
          expect(
            await File(song.artworkPath!).readAsBytes(),
            await File('test/library/fixtures/cover.png').readAsBytes(),
          );
          expect(
            p.basename(song.artworkPath!),
            matches(RegExp(r'^[0-9a-f]{64}\.png$')),
          );
        }
      }
      expect(
        imported[0].artworkPath,
        imported[1].artworkPath,
      ); // identical art reuses cache
    },
  );

  test(
    'recursive directory import deduplicates root, file and case variants',
    () async {
      final a = await fixture('wav', name: '中文 空格/a.WAV');
      final b = await fixture('mp3', name: 'nested/deeper/b.mp3');
      await File(
        p.join(temporary.path, 'ignore.txt'),
      ).writeAsString('not audio');
      final service = create();
      final imported = await service.importPaths([
        temporary.path,
        a.path,
        a.absolute.path.toUpperCase(),
        b.path,
      ]);
      expect(imported, hasLength(2));
      expect(service.songs, hasLength(2));
      expect(service.discovered.value, 2);
      expect(service.processed.value, 2);
      expect(await service.importPaths([temporary.path]), isEmpty);
      expect(service.songs, hasLength(2));
    },
  );

  test(
    'explicit file links deduplicate and directory links are not followed',
    () async {
      final file = await fixture('wav');
      final alias = Link(p.join(temporary.path, 'alias.wav'));
      final cycle = Link(p.join(temporary.path, 'cycle'));
      await alias.create(file.absolute.path);
      await cycle.create(temporary.absolute.path);
      final service = create();
      expect(
        await service.importPaths([temporary.path, alias.path]),
        hasLength(1),
      );
      expect(
        service.songs.single.id,
        Song(
          uri: File(await file.resolveSymbolicLinks()).uri,
          fileName: 'tagged.wav',
        ).id,
      );
    },
    skip: !Platform.isWindows ? 'Windows identity and link policy' : false,
  );

  test('bad metadata keeps filename and other files keep importing', () async {
    final bad = File(p.join(temporary.path, '坏文件.mp3'));
    await bad.writeAsString('deliberately invalid audio');
    final good = await fixture('flac');
    final service = create();
    final imported = await service.importPaths([
      bad.path,
      good.path,
      p.join(temporary.path, 'missing.wav'),
    ]);
    expect(imported, hasLength(2));
    expect(imported.first.title, '坏文件');
    expect(imported.first.trackTitle, isNull);
    expect(imported.last.title, 'Fixture FLAC');
    expect(service.warningCount.value, 1);
    expect(service.errorCount.value, 1);
    expect(service.statusMessage.value, contains('降级'));
  });

  test(
    'cancelling an in-flight metadata read returns promptly and keeps completed songs',
    () async {
      final first = await fixture('wav', name: 'first.wav');
      final second = await fixture('wav', name: 'second.wav');
      final started = Completer<void>();
      final blocked = Completer<AudioMetadata>();
      final service = create(
        reader: (file) {
          if (p.basename(file.path) == 'second.wav') {
            started.complete();
            return blocked.future;
          }
          return AudioMetadata(file: file, title: 'First');
        },
      );
      final importing = service.importPaths([first.path, second.path]);
      await started.future;
      service.cancelImport();
      final result = await importing.timeout(const Duration(seconds: 1));
      expect(result, hasLength(1));
      expect(service.songs.single.title, 'First');
      expect(service.processed.value, 1);
      expect(service.isImporting.value, isFalse);
      expect(service.statusMessage.value, contains('已取消'));
      blocked.complete(AudioMetadata(file: second, title: 'Late result'));
      await Future<void>.delayed(Duration.zero);
      expect(service.songs, hasLength(1));
      expect(await service.importPaths([first.path]), isEmpty);
    },
  );

  test(
    'per-file deadline degrades metadata and proceeds to the next file',
    () async {
      final first = await fixture('wav', name: 'first.wav');
      final second = await fixture('wav', name: 'second.wav');
      final service = create(
        timeout: const Duration(milliseconds: 30),
        reader: (file) => p.basename(file.path) == 'first.wav'
            ? Completer<AudioMetadata>().future
            : AudioMetadata(file: file, title: 'Second'),
      );
      final result = await service.importPaths([first.path, second.path]);
      expect(result.map((song) => song.title), ['first', 'Second']);
      expect(service.warningCount.value, 1);
    },
  );

  test(
    'cover format, dimensions and size limits fall back without losing tags',
    () async {
      final file = await fixture('wav');
      final png = await File('test/library/fixtures/cover.png').readAsBytes();
      final tooWide = Uint8List.fromList(png);
      ByteData.sublistView(tooWide).setUint32(16, 100000);
      final service = create(
        reader: (source) =>
            AudioMetadata(file: source, title: 'Safe title')
              ..pictures = [
                Picture(
                  Uint8List.fromList('<svg/>'.codeUnits),
                  'image/svg+xml',
                  PictureType.coverFront,
                ),
                Picture(tooWide, 'image/png', PictureType.coverFront),
                Picture(
                  Uint8List(4 * 1024 * 1024 + 1),
                  'image/png',
                  PictureType.coverFront,
                ),
              ],
      );
      final result = await service.importPaths([file.path]);
      expect(result.single.title, 'Safe title');
      expect(result.single.artworkPath, isNull);
      expect(service.warningCount.value, 1);
      expect(artwork.existsSync(), isFalse);
    },
  );

  test(
    'missing refresh can recover; remove deletes only index; search covers fields',
    () async {
      final file = await fixture('mp3', name: '原文件.mp3');
      final service = create();
      final song = (await service.importPaths([file.path])).single;
      for (final term in [
        'fixture',
        'hanmusic tests',
        'generated samples',
        '原文件',
        '  MP3  ',
      ]) {
        expect(service.search(term), hasLength(1));
      }
      expect(service.search('nonexistent'), isEmpty);
      final moved = await file.rename('${file.path}.moved');
      await service.refreshMissing();
      expect(service.songs.single.isMissing, isTrue);
      await moved.rename(file.path);
      await service.refreshMissing();
      expect(service.songs.single.isMissing, isFalse);
      service.remove(song.id);
      expect(service.songs, isEmpty);
      expect(await file.exists(), isTrue);
    },
  );

  test(
    'restore deduplicates and missing refresh preserves online items',
    () async {
      final file = await fixture('wav');
      final local = Song(uri: file.absolute.uri, fileName: 'tagged.wav');
      final online = Song(
        uri: Uri.parse('https://example.com/Track'),
        fileName: 'Track',
      );
      final service = create();
      service.replaceAll([local, local, online]);
      expect(service.songs, hasLength(2));
      await service.refreshMissing();
      expect(service.songs.every((song) => !song.isMissing), isTrue);
    },
  );
}
