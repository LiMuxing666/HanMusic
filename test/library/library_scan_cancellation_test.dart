import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/services/library_service.dart';

void main() {
  for (final lateError in [false, true]) {
    test(
      'cancel releases a stalled scan, keeps completed songs and ignores late ${lateError ? "errors" : "entries"}',
      () async {
        final first = _ControlledFile('first.wav');
        final late = _ControlledFile('late.wav');
        final next = _ControlledFile('next.wav');
        final scan = _PausedScan(first: first, late: late);
        final repository = _ScanRepository([
          () => scan.stream,
          () => Stream.value(LibraryScanEntry.file(next)),
        ]);
        final library = LibraryService(repository: repository);
        final importing = library.importPaths(['first import']);
        try {
          await scan.waiting.future;
          expect(library.songs.single.fileName, 'first.wav');
          library.cancelImport();
          final imported = await importing.timeout(const Duration(seconds: 1));
          expect(imported.single.fileName, 'first.wav');
          expect(library.isImporting.value, isFalse);
          expect(library.statusMessage.value, contains('已取消导入'));

          await library.importPaths(['new import']);
          final status = library.statusMessage.value;
          final errors = library.errorCount.value;
          final warnings = library.warningCount.value;
          if (lateError) {
            scan.gate.completeError(StateError('late scan failure'));
          } else {
            scan.gate.complete();
          }
          await scan.finished.future;
          await Future<void>.delayed(Duration.zero);
          expect(library.songs.map((song) => song.fileName), [
            'first.wav',
            'next.wav',
          ]);
          expect(library.statusMessage.value, status);
          expect(library.errorCount.value, errors);
          expect(library.warningCount.value, warnings);
          expect(library.isImporting.value, isFalse);
        } finally {
          if (!scan.gate.isCompleted) scan.gate.complete();
          await importing;
          await scan.finished.future;
          library.onClose();
        }
      },
    );
  }

  for (final lateError in [false, true]) {
    test(
      'cancel releases the pre-commit existence check and ignores its late ${lateError ? "failure" : "success"}',
      () async {
        final existence = Completer<bool>();
        final blocked = _ControlledFile('pending.wav', existence: existence);
        final next = _ControlledFile('next.wav');
        final repository = _ScanRepository([
          () => Stream.value(LibraryScanEntry.file(blocked)),
          () => Stream.value(LibraryScanEntry.file(next)),
        ]);
        final library = LibraryService(repository: repository);
        final importing = library.importPaths(['blocked import']);
        try {
          await blocked.checkStarted.future;
          library.cancelImport();
          expect(await importing.timeout(const Duration(seconds: 1)), isEmpty);
          expect(library.isImporting.value, isFalse);
          expect(library.songs, isEmpty);
          await library.importPaths(['new import']);
          final status = library.statusMessage.value;
          final errors = library.errorCount.value;
          if (lateError) {
            existence.completeError(
              const FileSystemException('late existence failure'),
            );
          } else {
            existence.complete(true);
          }
          await Future<void>.delayed(Duration.zero);
          expect(library.songs.single.fileName, 'next.wav');
          expect(library.errorCount.value, errors);
          expect(library.statusMessage.value, status);
        } finally {
          if (!existence.isCompleted) existence.complete(true);
          await importing;
          library.onClose();
        }
      },
    );
  }

  test('a current scan failure is still reported and releases busy', () async {
    final library = LibraryService(
      repository: _ScanRepository([
        () => Stream.error(const FileSystemException('current scan failure')),
      ]),
    );
    try {
      expect(await library.importPaths(['scan failure']), isEmpty);
      expect(library.errorCount.value, 1);
      expect(library.statusMessage.value, contains('1 项无法访问或处理'));
      expect(library.statusMessage.value, isNot(contains('已取消')));
      expect(library.isImporting.value, isFalse);
    } finally {
      library.onClose();
    }
  });

  test(
    'a current existence failure is still reported and releases busy',
    () async {
      final file = _ControlledFile(
        'unavailable.wav',
        existenceFailure: const FileSystemException(
          'current existence failure',
        ),
      );
      final library = LibraryService(
        repository: _ScanRepository([
          () => Stream.value(LibraryScanEntry.file(file)),
        ]),
      );
      try {
        expect(await library.importPaths(['existence failure']), isEmpty);
        expect(library.errorCount.value, 1);
        expect(library.statusMessage.value, contains('1 项无法访问或处理'));
        expect(library.isImporting.value, isFalse);
      } finally {
        library.onClose();
      }
    },
  );
}

class _ScanRepository extends LocalLibraryRepository {
  _ScanRepository(Iterable<Stream<LibraryScanEntry> Function()> scans)
    : _scans = Queue.of(scans),
      super(
        artworkDirectory: Directory('D:/dev/tmp/unused-scan-test-artwork'),
        // Exercise the real metadata fallback without starting a worker or
        // depending on disk timing; only scan/exists completion is controlled.
        metadataReader: (_) => throw const FormatException('no metadata'),
      );

  final Queue<Stream<LibraryScanEntry> Function()> _scans;

  @override
  Stream<LibraryScanEntry> scan(
    List<String> paths,
    ImportCancellation cancellation,
  ) => _scans.removeFirst()();
}

class _PausedScan {
  _PausedScan({required this.first, required this.late});
  final File first;
  final File late;
  final waiting = Completer<void>();
  final gate = Completer<void>();
  final finished = Completer<void>();

  Stream<LibraryScanEntry> get stream async* {
    try {
      yield LibraryScanEntry.file(first);
      waiting.complete();
      // async* cancellation cannot finish until this operation returns.
      await gate.future;
      yield const LibraryScanEntry.warning('stale scan warning');
      yield LibraryScanEntry.file(late);
    } finally {
      finished.complete();
    }
  }
}

class _ControlledFile implements File {
  _ControlledFile(String name, {this.existence, this.existenceFailure})
    : path = 'D:/controlled-library-scan/$name';

  @override
  final String path;
  final Completer<bool>? existence;
  final Object? existenceFailure;
  final checkStarted = Completer<void>();

  @override
  Uri get uri => Uri.file(path, windows: true);

  @override
  File get absolute => this;

  @override
  Future<bool> exists() {
    if (!checkStarted.isCompleted) checkStarted.complete();
    if (existenceFailure case final failure?) return Future.error(failure);
    return existence?.future ?? Future.value(true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
