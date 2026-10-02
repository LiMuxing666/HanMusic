import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';

void main() {
  late FilePickerPlatform previousPlatform;
  late _RecordingFilePickerPlatform platform;

  setUp(() {
    previousPlatform = FilePickerPlatform.instance;
    platform = _RecordingFilePickerPlatform();
    FilePickerPlatform.instance = platform;
  });

  tearDown(() => FilePickerPlatform.instance = previousPlatform);

  test(
    'multi-file import owns its Windows dialog and cancel returns no paths',
    () async {
      final paths = await LocalLibraryPicker().pickFiles();

      expect(paths, isEmpty);
      expect(platform.pickFilesCalls, 1);
      expect(platform.pickFilesWindowsOptions?.lockParentWindow, isTrue);
      expect(platform.pickFilesType, FileType.custom);
      expect(platform.pickFilesExtensions, containsAll(['mp3', 'flac', 'wav']));
    },
  );

  test(
    'directory import owns its Windows dialog and cancel returns null',
    () async {
      final path = await LocalLibraryPicker().pickDirectory();

      expect(path, isNull);
      expect(platform.directoryCalls, 1);
      expect(platform.directoryWindowsOptions?.lockParentWindow, isTrue);
    },
  );

  test(
    'single-file import owns its Windows dialog and cancel returns no song',
    () async {
      final song = await LocalSongPicker().pick();

      expect(song, isNull);
      expect(platform.pickFileCalls, 1);
      expect(platform.pickFileWindowsOptions?.lockParentWindow, isTrue);
      expect(platform.pickFileType, FileType.custom);
      expect(platform.pickFileExtensions, containsAll(['mp3', 'flac', 'wav']));
    },
  );
}

class _RecordingFilePickerPlatform extends FilePickerPlatform {
  int pickFilesCalls = 0;
  int directoryCalls = 0;
  int pickFileCalls = 0;
  WindowsOptions? pickFilesWindowsOptions;
  WindowsOptions? directoryWindowsOptions;
  WindowsOptions? pickFileWindowsOptions;
  FileType? pickFilesType;
  FileType? pickFileType;
  List<String>? pickFilesExtensions;
  List<String>? pickFileExtensions;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    pickFilesCalls++;
    pickFilesWindowsOptions = windowsOptions;
    pickFilesType = type;
    pickFilesExtensions = allowedExtensions;
    return [];
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    directoryCalls++;
    directoryWindowsOptions = windowsOptions;
    return null;
  }

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    pickFileCalls++;
    pickFileWindowsOptions = windowsOptions;
    pickFileType = type;
    pickFileExtensions = allowedExtensions;
    return null;
  }
}
