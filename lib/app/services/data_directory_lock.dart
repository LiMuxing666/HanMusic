import 'dart:io';

/// A safe, user-facing startup failure. Never continue with writable stores.
class DataDirectoryLockException implements Exception {
  const DataDirectoryLockException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DataDirectoryInUseException extends DataDirectoryLockException {
  const DataDirectoryInUseException()
    : super('此数据目录正在被另一个实例使用。请关闭原实例，或选择其他数据目录后重试。');
}

/// Holds the Windows file handle until all application writes have drained.
///
/// Acquire before reading any persistent state, and use [canonicalDirectory]
/// for every store. Junctions/symlinks are resolved before opening the lock;
/// the OS file identity, rather than a lowercased path string, decides whether
/// two callers conflict. This also respects Windows case-sensitive directories.
///
/// The empty lock file is permanent: deleting/renaming it on release would let
/// another process lock a different file while an earlier handle still exists.
/// Nothing is written or truncated before or after locking. Byte [0, 1) may be
/// locked even while the file is empty. Closing this handle releases the lock;
/// Windows also releases it after process termination (possibly with a delay).
///
/// This intentionally supports Windows only. POSIX process-scoped advisory
/// locks do not provide the same same-process/independent-handle guarantees.
/// See https://api.dart.dev/dart-io/RandomAccessFile/lock.html and
/// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-lockfileex.
class DataDirectoryLock {
  DataDirectoryLock._(this.canonicalDirectory, this._handle);

  static const fileName = '.hanmusic.lock';

  final Directory canonicalDirectory;
  final RandomAccessFile _handle;
  Future<void>? _releaseTask;
  bool _isReleased = false;

  bool get isReleased => _isReleased;

  static Future<DataDirectoryLock> acquire(Directory directory) async {
    if (!Platform.isWindows) {
      throw const DataDirectoryLockException('当前平台尚未支持数据目录独占保护。');
    }
    RandomAccessFile? handle;
    try {
      // Directory creation is the only operation before the lock-file open.
      // No state, source configuration or artwork is read at this stage.
      await directory.create(recursive: true);
      final canonical = Directory(await directory.resolveSymbolicLinks());
      handle = await File(
        '${canonical.path}${Platform.pathSeparator}$fileName',
      ).open(mode: FileMode.append);
      await handle.lock(FileLock.exclusive, 0, 1);
      final result = DataDirectoryLock._(canonical, handle);
      handle = null; // Transfer handle ownership to the returned lock.
      return result;
    } on FileSystemException catch (error) {
      // Win32 ERROR_LOCK_VIOLATION. Permissions, invalid paths and unrelated
      // I/O failures are deliberately not reported as an existing instance.
      if (error.osError?.errorCode == 33) {
        throw const DataDirectoryInUseException();
      }
      throw const DataDirectoryLockException(
        '无法锁定数据目录。请检查目录、磁盘与访问权限，或选择其他数据目录后重试。',
      );
    } finally {
      if (handle != null) {
        try {
          await handle.close();
        } on FileSystemException {
          // Preserve the original acquisition failure; no lock was returned.
        }
      }
    }
  }

  /// Call only after state, online configuration and artwork writers stop.
  /// Repeated/concurrent calls share the same completion, without deleting
  /// the file or releasing a later owner's lock.
  Future<void> release() => _releaseTask ??= _release();

  Future<void> _release() async {
    try {
      await _handle.close();
      _isReleased = true;
    } on FileSystemException {
      throw const DataDirectoryLockException('数据目录锁释放失败，请退出应用后重试。');
    }
  }
}
