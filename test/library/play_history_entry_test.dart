import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/play_history_entry.dart';
import 'package:han_music/app/data/models/song.dart';

void main() {
  final song = Song(
    uri: Uri.file(r'D:\音乐 & samples\清晨 (UTF8).mp3', windows: true),
    fileName: '清晨 (UTF8).mp3',
    trackTitle: '清晨',
    artist: '歌手',
    duration: const Duration(minutes: 3),
  );
  final time = DateTime.utc(2026, 10, 29, 12);

  test('local and online identities round trip with immutable metadata', () {
    for (final source in [
      song,
      Song.online(sourceId: 'source', trackId: 'track', title: '在线歌曲'),
    ]) {
      final entry = PlayHistoryEntry(
        song: source,
        lastPlayedAt: time.toLocal(),
        playCount: 3,
      );
      final json = entry.toJson();
      final restored = PlayHistoryEntry.fromJson(json);
      expect(restored.toJson(), json);
      expect(restored.lastPlayedAt.isUtc, isTrue);
      expect(restored.lastPlayedAt, time);
      expect(identical(entry.song, source), isFalse);
      (json['song']! as Map<String, Object?>)['fileName'] = 'changed';
      expect(entry.song.fileName, source.fileName);
      expect(restored.song.fileName, source.fileName);
      final updated = entry.copyWith(
        playCount: 4,
        song: source.copyWith(artist: '新歌手'),
      );
      expect(updated.playCount, 4);
      expect(updated.song.artist, '新歌手');
      expect(entry.playCount, 3);
      expect(entry.song.artist, source.artist);
    }
  });

  test(
    'malformed fields, noncanonical times and nonpositive counts are rejected',
    () {
      final valid = PlayHistoryEntry(
        song: song,
        lastPlayedAt: time,
        playCount: 1,
      ).toJson();
      for (final key in ['song', 'lastPlayedAt', 'playCount']) {
        final missing = Map<String, dynamic>.from(valid)..remove(key);
        expect(() => PlayHistoryEntry.fromJson(missing), throwsFormatException);
      }
      for (final value in [null, false, 0, -1, 1.0, '1']) {
        expect(
          () => PlayHistoryEntry.fromJson({...valid, 'playCount': value}),
          throwsFormatException,
        );
      }
      for (final value in [
        null,
        1,
        'bad',
        '2026-02-30T00:00:00.000Z',
        '2026-10-29T12:00:00',
        '2026-10-29T12:00:00.000+00:00',
      ]) {
        expect(
          () => PlayHistoryEntry.fromJson({...valid, 'lastPlayedAt': value}),
          throwsFormatException,
        );
      }
      for (final value in [null, 'song', [], <String, dynamic>{}]) {
        expect(
          () => PlayHistoryEntry.fromJson({...valid, 'song': value}),
          throwsFormatException,
        );
      }
      expect(
        () => PlayHistoryEntry(song: song, lastPlayedAt: time, playCount: 0),
        throwsFormatException,
      );
    },
  );

  test(
    'resolved HTTP URLs, credentials and invalid local references never persist',
    () {
      for (final uri in [
        Uri.parse('https://example.invalid/audio?token=secret'),
        Uri.parse('https://user:password@example.invalid/audio'),
        Uri.parse('relative.mp3'),
        Uri.parse('file:///D:/music/a.mp3?token=secret'),
        Uri.parse('file:///D:/music/a.mp3#fragment'),
      ]) {
        final unsafe = Song(uri: uri, fileName: 'audio.mp3');
        expect(
          () =>
              PlayHistoryEntry(song: unsafe, lastPlayedAt: time, playCount: 1),
          throwsFormatException,
          reason: 'Unsafe history identity must be rejected: $uri',
        );
      }
      final online = Song.online(sourceId: 's', trackId: 't', title: '歌曲');
      final invalidSong = {...online.toJson(), 'trackId': 'different'};
      expect(
        () => PlayHistoryEntry.fromJson({
          'song': invalidSong,
          'lastPlayedAt': time.toIso8601String(),
          'playCount': 1,
        }),
        throwsFormatException,
      );
    },
  );
}
