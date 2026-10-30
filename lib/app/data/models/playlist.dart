import 'song.dart';

/// A self-contained playlist snapshot, including restorable online identities.
class Playlist {
  factory Playlist({
    required String id,
    required String name,
    required List<Song> songs,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    if (id.isEmpty ||
        id.trim() != id ||
        id.length > 128 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(id)) {
      throw const FormatException('歌单标识无效。');
    }
    final checkedName = validateName(name);
    if (id == favoritesId && checkedName != favoritesName) {
      throw const FormatException('“我喜欢”歌单名称不可修改。');
    }
    if (id != favoritesId && checkedName == favoritesName) {
      throw const FormatException('“我喜欢”是保留的歌单名称。');
    }
    final created = createdAt.toUtc();
    final updated = updatedAt.toUtc();
    if (updated.isBefore(created)) {
      throw const FormatException('歌单更新时间不能早于创建时间。');
    }
    final ids = <String>{};
    final checkedSongs = <Song>[];
    for (final song in songs) {
      final checked = validateSong(song);
      if (!ids.add(checked.id)) {
        throw const FormatException('歌单中包含重复歌曲。');
      }
      checkedSongs.add(checked);
    }
    return Playlist._(
      id: id,
      name: checkedName,
      songs: List.unmodifiable(checkedSongs),
      createdAt: created,
      updatedAt: updated,
    );
  }

  const Playlist._({
    required this.id,
    required this.name,
    required this.songs,
    required this.createdAt,
    required this.updatedAt,
  });

  static const favoritesId = 'favorites';
  static const favoritesName = '我喜欢';

  final String id;
  final String name;
  final List<Song> songs;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isFavorites => id == favoritesId;

  static String validateName(String value) {
    final name = value.trim();
    if (name.isEmpty ||
        name.runes.length > 100 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const FormatException('歌单名称需为 1–100 个字符，且不能包含控制字符。');
    }
    return name;
  }

  /// Reuse Song's canonical identity checks; never persist a resolved stream URL.
  static Song validateSong(Song song) {
    final checked = Song.fromJson(song.toJson());
    if (!checked.isOnline) {
      final uri = checked.uri;
      if (!uri.path.startsWith('/') ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const FormatException('歌单仅支持本地文件或稳定的在线歌曲标识。');
      }
      try {
        uri.toFilePath(windows: true);
      } on UnsupportedError {
        throw const FormatException('歌单中的本地文件地址无效。');
      } on ArgumentError {
        throw const FormatException('歌单中的本地文件地址无效。');
      }
    }
    return checked;
  }

  Playlist copyWith({String? name, List<Song>? songs, DateTime? updatedAt}) =>
      Playlist(
        id: id,
        name: name ?? this.name,
        songs: songs ?? this.songs,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'songs': songs.map((song) => song.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory Playlist.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final songs = json['songs'];
    if (id is! String || name is! String || songs is! List) {
      throw const FormatException('歌单内容格式无效。');
    }
    DateTime readTime(String key) {
      final raw = json[key];
      final time = raw is String ? DateTime.tryParse(raw) : null;
      if (time == null || !time.isUtc || time.toIso8601String() != raw) {
        throw const FormatException('歌单时间格式无效。');
      }
      return time;
    }

    return Playlist(
      id: id,
      name: name,
      songs: [
        for (final item in songs)
          if (item is Map<String, dynamic>)
            Song.fromJson(item)
          else
            throw const FormatException('歌单歌曲格式无效。'),
      ],
      createdAt: readTime('createdAt'),
      updatedAt: readTime('updatedAt'),
    );
  }
}
