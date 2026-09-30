import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum StoreWriteFault { partialBackupWrite, backupReplace, primaryReplace }

/// Performs real I/O only in the test's owned temporary directory, and injects
/// one storage failure. Both old direct backup writes and staged backup writes
/// are intercepted so the same regression test can fail before the fix.
class StoreWriteFaultInjection {
  StoreWriteFaultInjection({
    required Directory directory,
    required this.stem,
    required this.fault,
  }) : _directory = directory.absolute.path.replaceAll('\\', '/');

  final String _directory;
  final String stem;
  final StoreWriteFault fault;
  int injected = 0;

  Future<T> run<T>(Future<T> Function() action) {
    final parentZone = Zone.current;
    return IOOverrides.runZoned(
      action,
      createFile: (path) {
        final file = parentZone.run(() => File(path));
        final normalized = parentZone
            .run(() => file.absolute.path)
            .replaceAll('\\', '/');
        if (!normalized.startsWith('$_directory/')) return file;
        return _FaultFile(file, this);
      },
    );
  }

  bool _take(StoreWriteFault point, String path) {
    if (injected != 0 || fault != point) return false;
    final name = path.replaceAll('\\', '/').split('/').last;
    final matches = switch (point) {
      StoreWriteFault.partialBackupWrite =>
        name == '$stem.backup.json' || name == '$stem.backup.next.json',
      StoreWriteFault.backupReplace => name == '$stem.backup.json',
      StoreWriteFault.primaryReplace => name == '$stem.json',
    };
    if (matches) injected++;
    return matches;
  }
}

class _FaultFile implements File {
  _FaultFile(this._file, this._injection);

  final File _file;
  final StoreWriteFaultInjection _injection;

  @override
  String get path => _file.path;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    if (_injection._take(StoreWriteFault.partialBackupWrite, path)) {
      await _file.writeAsString(
        contents.substring(0, contents.length ~/ 2),
        mode: mode,
        encoding: encoding,
        flush: flush,
      );
      throw const FileSystemException('Injected partial backup write failure');
    }
    return _file.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  Future<File> rename(String newPath) async {
    if (_injection._take(StoreWriteFault.backupReplace, newPath)) {
      throw const FileSystemException('Injected backup replacement failure');
    }
    if (_injection._take(StoreWriteFault.primaryReplace, newPath)) {
      throw const FileSystemException('Injected primary replacement failure');
    }
    return _file.rename(newPath);
  }

  @override
  Future<bool> exists() => _file.exists();

  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      _file.readAsString(encoding: encoding);

  @override
  Future<int> length() => _file.length();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected File API: ${invocation.memberName}');
}
