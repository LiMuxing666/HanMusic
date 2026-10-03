import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/services/data_directory_lock.dart';

void main() {
  group('Windows data directory ownership', () {
    final testRoot = Directory('D:/dev/tmp/hanmusic-lock-tests').absolute;
    late Directory temporary;
    final holders = <Process>[];
    final locks = <DataDirectoryLock>[];

    setUp(() async {
      await testRoot.create(recursive: true);
      temporary = await testRoot.createTemp('test-');
    });

    tearDown(() async {
      for (final process in holders) {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 10));
      }
      holders.clear();
      for (final lock in locks) {
        await lock.release();
      }
      locks.clear();
      if (await temporary.exists()) {
        final resolved = await temporary.resolveSymbolicLinks();
        final root = await testRoot.resolveSymbolicLinks();
        expect(
          resolved.toLowerCase().startsWith('${root.toLowerCase()}\\'),
          isTrue,
          reason: 'Recursive cleanup must remain within the lock-test root',
        );
        await temporary.delete(recursive: true);
      }
    });

    Future<Process> hold(Directory directory) async {
      final process = await Process.start(_dart, [
        _probe,
        'hold',
        directory.path,
      ]);
      holders.add(process);
      final errors = process.stderr.transform(utf8.decoder).join();
      final line = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15));
      final status = jsonDecode(line) as Map<String, dynamic>;
      if (status['status'] != 'acquired') {
        fail('Child did not acquire: $line; ${await errors}');
      }
      return process;
    }

    Future<Map<String, dynamic>> tryInChild(Directory directory) async {
      final result = await Process.run(
        _dart,
        [_probe, 'try', directory.path],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 15));
      expect(result.stderr, isEmpty);
      final status =
          jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(result.exitCode, status['status'] == 'acquired' ? 0 : 2);
      return status;
    }

    test(
      'a second process conflicts; another directory remains usable',
      () async {
        final directory = Directory('${temporary.path}/first');
        await hold(directory);
        expect((await tryInChild(directory))['status'], 'in_use');
        expect(
          (await tryInChild(Directory('${temporary.path}/other')))['status'],
          'acquired',
        );
        // A failed contender must not release the holder's lock.
        expect((await tryInChild(directory))['status'], 'in_use');
      },
    );

    test('same-process handles conflict and release is idempotent', () async {
      final first = await DataDirectoryLock.acquire(temporary);
      locks.add(first);
      await expectLater(
        DataDirectoryLock.acquire(temporary),
        throwsA(isA<DataDirectoryInUseException>()),
      );
      final release = first.release();
      expect(identical(release, first.release()), isTrue);
      await release;
      expect(first.isReleased, isTrue);
      final second = await DataDirectoryLock.acquire(temporary);
      locks.add(second);
      await first.release();
      expect((await tryInChild(temporary))['status'], 'in_use');
      await second.release();
      expect((await tryInChild(temporary))['status'], 'acquired');
    });

    test(
      'normal child release leaves its file reusable and untouched',
      () async {
        final file = File('${temporary.path}/${DataDirectoryLock.fileName}');
        await file.writeAsString('existing marker');
        final child = await hold(temporary);
        expect((await tryInChild(temporary))['status'], 'in_use');
        child.stdin.writeln('release');
        await child.stdin.flush();
        // Close the pipe after the command: Windows can retain the child's
        // stdin read handle after its line subscription is canceled. EOF lets
        // normal process shutdown finish without relying on scheduler timing.
        await child.stdin.close();
        expect(await child.exitCode.timeout(const Duration(seconds: 10)), 0);
        holders.remove(child);
        expect(await file.readAsString(), 'existing marker');
        expect((await tryInChild(temporary))['status'], 'acquired');
        expect(await file.readAsString(), 'existing marker');
      },
    );

    test('process termination releases lock without deleting the file', () async {
      final child = await hold(temporary);
      expect(child.kill(), isTrue);
      await child.exitCode.timeout(const Duration(seconds: 10));
      holders.remove(child);
      final file = File('${temporary.path}/${DataDirectoryLock.fileName}');
      expect(await file.exists(), isTrue);
      expect(await file.length(), 0);
      // Windows may briefly retain the lock while cleaning up the dead process.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (true) {
        final result = await tryInChild(temporary);
        if (result['status'] == 'acquired') break;
        if (DateTime.now().isAfter(deadline)) {
          fail('OS did not release the lock');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });

    test(
      'case aliases and a directory junction refer to the same lock',
      () async {
        final target = await Directory(
          '${temporary.path}/Mixed Case 中文',
        ).create();
        final alias = '${temporary.path}/Junction Alias';
        // PowerShell creates a real directory junction without developer mode.
        final escapedAlias = alias.replaceAll("'", "''");
        final escapedTarget = target.path.replaceAll("'", "''");
        final junction = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "New-Item -ItemType Junction -Path '$escapedAlias' "
              "-Target '$escapedTarget' -ErrorAction Stop | Out-Null",
        ]);
        expect(junction.exitCode, 0, reason: '${junction.stderr}');
        final lock = await DataDirectoryLock.acquire(Directory(alias));
        locks.add(lock);
        expect(
          lock.canonicalDirectory.path.toLowerCase(),
          (await target.resolveSymbolicLinks()).toLowerCase(),
        );
        expect((await tryInChild(target))['status'], 'in_use');
        expect(
          (await tryInChild(Directory(target.path.toUpperCase())))['status'],
          'in_use',
        );
        // Delete the link itself, never recursively traverse its target.
        await Link(alias).delete();
      },
    );

    test('simultaneous first startup has exactly one owner', () async {
      final directory = Directory('${temporary.path}/new directory');
      final children = await Future.wait([
        Process.start(_dart, [_probe, 'hold', directory.path]),
        Process.start(_dart, [_probe, 'hold', directory.path]),
      ]);
      holders.addAll(children);
      final results = await Future.wait(
        children.map((child) async {
          child.stderr.drain<void>();
          final line = await child.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 15));
          final result = jsonDecode(line) as Map<String, dynamic>;
          if (result['status'] == 'in_use') {
            expect(
              await child.exitCode.timeout(const Duration(seconds: 10)),
              2,
            );
            holders.remove(child);
          }
          return result['status'];
        }),
      );
      expect(results, unorderedEquals(['acquired', 'in_use']));
      expect((await tryInChild(directory))['status'], 'in_use');
    });

    test('read-only lock file fails closed as an access error', () async {
      final file = File('${temporary.path}/${DataDirectoryLock.fileName}');
      await file.writeAsString('preserve');
      final result = await Process.run('attrib.exe', ['+R', file.path]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      try {
        await expectLater(
          DataDirectoryLock.acquire(temporary),
          throwsA(
            isA<DataDirectoryLockException>().having(
              (error) => error is DataDirectoryInUseException,
              'is directory conflict',
              isFalse,
            ),
          ),
        );
        expect(await file.readAsString(), 'preserve');
      } finally {
        final restored = await Process.run('attrib.exe', ['-R', file.path]);
        expect(restored.exitCode, 0);
      }
    });

    test('invalid paths fail closed without being called a conflict', () async {
      final notDirectory = File('${temporary.path}/file');
      await notDirectory.writeAsString('preserve');
      await expectLater(
        DataDirectoryLock.acquire(Directory(notDirectory.path)),
        throwsA(
          isA<DataDirectoryLockException>().having(
            (error) => error is DataDirectoryInUseException,
            'is directory conflict',
            isFalse,
          ),
        ),
      );
      expect(await notDirectory.readAsString(), 'preserve');
      await Directory(
        '${temporary.path}/${DataDirectoryLock.fileName}',
      ).create();
      await expectLater(
        DataDirectoryLock.acquire(temporary),
        throwsA(isA<DataDirectoryLockException>()),
      );
    });
  }, skip: !Platform.isWindows);
}

String get _probe => File('tool/data_directory_lock_probe.dart').absolute.path;

String get _dart {
  // flutter_tester is not a Dart CLI. Its SDK's cache also contains dart.exe.
  final executable = File(Platform.resolvedExecutable);
  if (executable.uri.pathSegments.last.toLowerCase() == 'dart.exe') {
    return executable.path;
  }
  final cache = executable.parent.parent.parent.parent;
  final dart = File('${cache.path}/dart-sdk/bin/dart.exe');
  if (!dart.existsSync()) throw StateError('Cannot locate Flutter Dart SDK');
  return dart.path;
}
