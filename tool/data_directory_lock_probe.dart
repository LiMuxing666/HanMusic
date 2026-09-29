// Small standalone child process for test/services/data_directory_lock_test.dart.
// No Flutter engine, audio backend, state file or GUI is initialized.
import 'dart:convert';
import 'dart:io';

import 'package:han_music/app/services/data_directory_lock.dart';

Future<void> main(List<String> arguments) async {
  stdout.encoding = utf8;
  stderr.encoding = utf8;
  if (arguments.length != 2 || !{'hold', 'try'}.contains(arguments[0])) {
    stderr.writeln(
      'Usage: dart tool/data_directory_lock_probe.dart hold|try DIR',
    );
    exitCode = 64;
    return;
  }
  DataDirectoryLock? lock;
  try {
    lock = await DataDirectoryLock.acquire(Directory(arguments[1]));
    stdout.writeln(
      jsonEncode({'status': 'acquired', 'path': lock.canonicalDirectory.path}),
    );
    await stdout.flush();
    if (arguments[0] == 'hold') {
      // A line or EOF requests normal release. Tests also kill this process
      // without sending input to exercise Windows crash cleanup.
      await for (final _
          in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
        break;
      }
    }
  } on DataDirectoryInUseException catch (error) {
    stdout.writeln(jsonEncode({'status': 'in_use', 'message': error.message}));
    exitCode = 2;
  } on DataDirectoryLockException catch (error) {
    stdout.writeln(jsonEncode({'status': 'error', 'message': error.message}));
    exitCode = 3;
  } finally {
    await lock?.release();
  }
}
