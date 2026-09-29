import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/song.dart';

void main() {
  test(
    'M1 file-name fallback, extension and tagged title remain compatible',
    () {
      final song = Song(
        uri: Uri.file(r'D:\Music\曲目.Mp3', windows: true),
        fileName: '曲目.Mp3',
      );
      expect(song.title, '曲目');
      expect(song.extension, 'MP3');
      expect(song.path, r'D:\Music\曲目.Mp3');
      expect(song.copyWith(trackTitle: '  标签标题  ').title, '标签标题');
      expect(song.copyWith(trackTitle: ' ').title, '曲目');
    },
  );

  test(
    'local identity normalizes segments and case; remote IDs preserve case',
    () {
      final a = Song(
        uri: Uri.parse('file:///D:/Music/../Music/TEST.mp3'),
        fileName: 'TEST.mp3',
      );
      final b = Song(
        uri: Uri.parse('file:///d:/music/test.mp3'),
        fileName: 'test.mp3',
      );
      expect(a.id, b.id);
      expect(
        Song(uri: Uri.parse('https://example.com/A'), fileName: 'A').id,
        isNot(Song(uri: Uri.parse('https://example.com/a'), fileName: 'a').id),
      );
    },
  );

  test(
    'JSON round trip preserves metadata and missing flag without image bytes',
    () {
      final song = Song(
        uri: Uri.file(r'D:\曲库\歌.wav', windows: true),
        fileName: '歌.wav',
        trackTitle: '标题',
        artist: '歌手',
        album: '专辑',
        duration: const Duration(milliseconds: 1234),
        artworkPath: r'D:\cache\cover.png',
        isMissing: true,
      );
      expect(Song.fromJson(song.toJson()).toJson(), song.toJson());
      expect(song.toJson().containsKey('pictures'), isFalse);
      expect(song.copyWith(isMissing: false).artist, '歌手');
      expect(song.copyWith(isMissing: false).isMissing, isFalse);
    },
  );

  test('malformed saved metadata is rejected explicitly', () {
    for (final value in <Map<String, dynamic>>[
      {},
      {'uri': 'relative.mp3', 'fileName': 'relative.mp3'},
      {'uri': 'file:///D:/a.mp3', 'fileName': 'a.mp3', 'durationMs': -1},
      {'uri': 'file:///D:/a.mp3', 'fileName': 'a.mp3', 'isMissing': 'yes'},
    ]) {
      expect(() => Song.fromJson(value), throwsFormatException);
    }
  });
}
