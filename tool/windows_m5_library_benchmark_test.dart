// Run explicitly with flutter test; real files and parser, no mock metadata.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/services/library_service.dart';

void main() {
  test(
    'real directory import, cancellation, search and state round-trip',
    () async {
      const root = String.fromEnvironment('HANMUSIC_BENCHMARK_DIR');
      const count = int.fromEnvironment(
        'HANMUSIC_BENCHMARK_COUNT',
        defaultValue: 10000,
      );
      if (root.isEmpty || !Directory(root).isAbsolute || count < 100) {
        throw ArgumentError(
          'Provide absolute HANMUSIC_BENCHMARK_DIR containing sample.flac; count >= 100.',
        );
      }
      final output = Directory(root);
      final sample = await File('$root/sample.flac').readAsBytes();
      final files = Directory('$root/真实曲库 中文空格');
      await files.create(recursive: true);
      final generation = Stopwatch()..start();
      // Separate paths hold identical generated FLAC bytes. This is intentionally
      // a controlled filesystem workload, not a diverse commercial music library.
      for (var index = 0; index < count; index++) {
        final folder = Directory(
          '${files.path}/${(index ~/ 100).toString().padLeft(3, '0')}',
        );
        if (index % 100 == 0) await folder.create(recursive: true);
        await File(
          '${folder.path}/曲目 ${index.toString().padLeft(5, '0')}.flac',
        ).writeAsBytes(sample);
      }
      final metrics = <String, Object?>{
        'mode': 'flutter_test; real filesystem and production metadata isolate',
        'os': Platform.operatingSystemVersion,
        'count': count,
        'sampleBytes': sample.length,
        'audioBytes': sample.length * count,
        'fixturePreparationMs': generation.elapsedMilliseconds,
        'rssBeforeImportBytes': ProcessInfo.currentRss,
        'hasArtwork': false,
        'sampleDurationSeconds': 0.1,
      };
      var peakRss = ProcessInfo.currentRss;
      final sampler = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (ProcessInfo.currentRss > peakRss) peakRss = ProcessInfo.currentRss;
      });
      final library = LibraryService(
        repository: LocalLibraryRepository(
          artworkDirectory: Directory('$root/artwork'),
        ),
      );
      final cancelled = LibraryService(
        repository: LocalLibraryRepository(
          artworkDirectory: Directory('$root/cancel-artwork'),
        ),
      );
      Worker? progress;
      Worker? cancellationWatch;
      var progressNotifications = 0;
      var passed = false;
      try {
        progress = ever(library.processed, (_) => progressNotifications++);
        final watch = Stopwatch()..start();
        await library.importPaths([files.path]);
        metrics['importMs'] = watch.elapsedMilliseconds;
        metrics['importedCount'] = library.songs.length;
        metrics['metadataFallbacks'] = library.warningCount.value;
        metrics['errors'] = library.errorCount.value;
        metrics['progressNotifications'] = progressNotifications;
        expect(library.songs.length, count);
        expect(library.errorCount.value, 0);
        expect(library.warningCount.value, 0);
        expect(progressNotifications, greaterThanOrEqualTo(count));
        expect(library.songs.first.artist, 'HanMusic fixture');

        watch.reset();
        await library.importPaths([files.path]);
        metrics['duplicateScanMs'] = watch.elapsedMilliseconds;
        expect(library.songs.length, count);
        final samples = <int>[];
        for (var index = 0; index < 50; index++) {
          watch.reset();
          final matches = library.search('曲目 00042');
          samples.add(watch.elapsedMicroseconds);
          expect(matches.length, 1);
        }
        samples.sort();
        metrics['searchSamples'] = samples.length;
        metrics['searchP95Microseconds'] =
            samples[(samples.length * .95).ceil() - 1];
        final store = FileAppStateStore(Directory('$root/state'));
        await store.load();
        watch.reset();
        await store.save(AppSnapshot(songs: library.songs.toList()));
        metrics['saveMs'] = watch.elapsedMilliseconds;
        watch.reset();
        final snapshot = await FileAppStateStore(
          Directory('$root/state'),
        ).load();
        metrics['loadMs'] = watch.elapsedMilliseconds;
        expect(snapshot.songs.length, count);
        metrics['stateBytes'] = await File('$root/state/state.json').length();
        watch.reset();
        await library.refreshMissing();
        metrics['existenceCheckMs'] = watch.elapsedMilliseconds;
        expect(library.songs.any((song) => song.isMissing), false);

        final cancellationTime = Stopwatch();
        cancellationWatch = ever(cancelled.processed, (int processed) {
          if (processed == 25) {
            cancellationTime.start();
            cancelled.cancelImport();
          }
        });
        await cancelled.importPaths([files.path]);
        metrics['cancelToFinishedMs'] = cancellationTime.elapsedMilliseconds;
        metrics['retainedOnCancel'] = cancelled.songs.length;
        expect(cancelled.songs.length, 25);
        expect(cancelled.isImporting.value, false);
        final retained = library.songs.first;
        library.remove(retained.id);
        expect(await File.fromUri(retained.uri).exists(), true);
        metrics['removeIndexPreservesFile'] = true;
        passed = true;
      } finally {
        progress?.dispose();
        cancellationWatch?.dispose();
        sampler.cancel();
        library.onClose();
        cancelled.onClose();
        metrics['passed'] = passed;
        metrics['sampledPeakRssBytes'] = peakRss;
        metrics['rssAfterBytes'] = ProcessInfo.currentRss;
        metrics['finishedAt'] = DateTime.now().toUtc().toIso8601String();
        metrics['limitations'] = [
          'Single controlled FLAC sample copied to distinct real files; no artwork or mixed codecs.',
          'flutter_test process overhead is included; not a Release app performance promise.',
          'State load uses a new store in the same process, not a full application cold start.',
          '100ms RSS sampling may miss shorter peaks; source files are retained for review.',
        ];
        await output.create(recursive: true);
        await File('$root/library-result.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert(metrics),
          flush: true,
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
