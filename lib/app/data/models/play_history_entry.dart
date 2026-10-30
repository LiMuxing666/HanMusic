import 'playlist.dart';
import 'song.dart';

/// A restorable identity and metadata snapshot, never a resolved stream URL.
class PlayHistoryEntry {
  factory PlayHistoryEntry({
    required Song song,
    required DateTime lastPlayedAt,
    required int playCount,
  }) {
    if (playCount <= 0) {
      throw const FormatException('播放次数必须为正整数。');
    }
    return PlayHistoryEntry._(
      song: Playlist.validateSong(song),
      lastPlayedAt: lastPlayedAt.toUtc(),
      playCount: playCount,
    );
  }

  const PlayHistoryEntry._({
    required this.song,
    required this.lastPlayedAt,
    required this.playCount,
  });

  final Song song;
  final DateTime lastPlayedAt;
  final int playCount;

  PlayHistoryEntry copyWith({
    Song? song,
    DateTime? lastPlayedAt,
    int? playCount,
  }) => PlayHistoryEntry(
    song: song ?? this.song,
    lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
    playCount: playCount ?? this.playCount,
  );

  Map<String, Object?> toJson() => {
    'song': song.toJson(),
    'lastPlayedAt': lastPlayedAt.toIso8601String(),
    'playCount': playCount,
  };

  factory PlayHistoryEntry.fromJson(Map<String, dynamic> json) {
    final song = json['song'];
    final count = json['playCount'];
    final rawTime = json['lastPlayedAt'];
    final time = rawTime is String ? DateTime.tryParse(rawTime) : null;
    if (song is! Map<String, dynamic> ||
        count is! int ||
        time == null ||
        !time.isUtc ||
        time.toIso8601String() != rawTime) {
      throw const FormatException('播放历史格式无效。');
    }
    return PlayHistoryEntry(
      song: Song.fromJson(song),
      lastPlayedAt: time,
      playCount: count,
    );
  }
}
