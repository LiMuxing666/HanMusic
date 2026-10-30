/// One timestamp and its complete lyric, including translations at that time.
class LyricsLine {
  const LyricsLine({required this.timestamp, required this.text});

  final Duration timestamp;
  final String text;
}

/// Parsed LRC or plain-text lyrics. Source audio and lyric files stay untouched.
class LyricsDocument {
  LyricsDocument._({
    required List<LyricsLine> timedLines,
    required List<String> plainLines,
  }) : timedLines = List.unmodifiable(timedLines),
       plainLines = List.unmodifiable(plainLines);

  final List<LyricsLine> timedLines;
  final List<String> plainLines;

  bool get isTimed => timedLines.isNotEmpty;

  static final _leadingTag = RegExp(r'^\[([^\]\r\n]*)\]');
  static final _timestamp = RegExp(r'^(\d{1,3}):([0-5]\d)(?:\.(\d{1,3}))?$');
  static final _metadata = RegExp(r'^([a-zA-Z][a-zA-Z0-9_-]*)\s*:(.*)$');
  static final _malformedTimestamp = RegExp(r'^\d[^\]]*:');
  static final _maximumMilliseconds = BigInt.from(
    0x7FFFFFFFFFFFFFFF ~/ Duration.microsecondsPerMillisecond,
  );

  factory LyricsDocument.parse(String text) {
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    final entries = <({int milliseconds, String text, int order})>[];
    final plain = <String>[];
    var offset = 0;
    for (final source in text.split(RegExp(r'\r\n?|\n'))) {
      var content = source.trim();
      final times = <int>[];
      while (true) {
        final tag = _leadingTag.firstMatch(content);
        if (tag == null) break;
        final value = tag.group(1)!;
        final time = _timestamp.firstMatch(value);
        final metadata = _metadata.firstMatch(value);
        if (time != null) {
          final minutes = int.parse(time.group(1)!);
          final seconds = int.parse(time.group(2)!);
          final fraction = time.group(3);
          final milliseconds = fraction == null
              ? 0
              : int.parse(fraction.padRight(3, '0'));
          times.add((minutes * 60 + seconds) * 1000 + milliseconds);
        } else if (metadata != null) {
          if (metadata.group(1)!.toLowerCase() == 'offset') {
            final parsed = int.tryParse(metadata.group(2)!.trim());
            if (parsed != null) offset = parsed;
          }
        } else if (!_malformedTimestamp.hasMatch(value)) {
          // Preserve ordinary section labels such as [Chorus] as lyric text.
          break;
        }
        content = content.substring(tag.end).trimLeft();
      }
      content = content.trimRight();
      if (times.isEmpty) {
        if (content.isNotEmpty) plain.add(content);
      } else {
        for (final time in times) {
          entries.add((
            milliseconds: time,
            text: content,
            order: entries.length,
          ));
        }
      }
    }
    if (entries.isEmpty) {
      return LyricsDocument._(timedLines: const [], plainLines: plain);
    }

    // In LRC a positive offset advances lyrics; a negative offset delays them.
    // BigInt prevents malformed extreme offsets wrapping native 64-bit time.
    final adjustment = BigInt.from(offset);
    final adjusted = entries.map((entry) {
      final shifted = BigInt.from(entry.milliseconds) - adjustment;
      final bounded = shifted < BigInt.zero
          ? BigInt.zero
          : shifted > _maximumMilliseconds
          ? _maximumMilliseconds
          : shifted;
      return (
        milliseconds: bounded.toInt(),
        text: entry.text,
        order: entry.order,
      );
    }).toList();
    adjusted.sort((left, right) {
      final byTime = left.milliseconds.compareTo(right.milliseconds);
      return byTime == 0 ? left.order.compareTo(right.order) : byTime;
    });

    final grouped = <int, Set<String>>{};
    for (final entry in adjusted) {
      final lines = grouped.putIfAbsent(entry.milliseconds, () => <String>{});
      // An empty timed line clears a previous lyric; at a shared timestamp it
      // must not hide non-empty originals or their translations.
      if (entry.text.isNotEmpty) lines.add(entry.text);
    }
    return LyricsDocument._(
      timedLines: [
        for (final entry in grouped.entries)
          LyricsLine(
            timestamp: Duration(milliseconds: entry.key),
            text: entry.value.join('\n'),
          ),
      ],
      plainLines: const [],
    );
  }

  /// Last timestamp at or before playback, or -1 before the first timed line.
  int activeIndex(Duration position) {
    var low = 0;
    var high = timedLines.length;
    while (low < high) {
      final middle = low + (high - low) ~/ 2;
      if (timedLines[middle].timestamp <= position) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low - 1;
  }
}
