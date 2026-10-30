import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/lyrics.dart';

void main() {
  test('BOM, metadata, line endings and timestamp precision are accepted', () {
    final document = LyricsDocument.parse(
      '\uFEFF[ti:歌名]\r\n[ar:歌手]\r[al:专辑]\n[by:编辑者]\n'
      '[re:播放器][ve:1.0][length:03:00]\n'
      '[001:02.3] 十分之一秒\n'
      '[1:03.45]百分之一秒\n'
      '[001:04.567]毫秒\n'
      '[123:05]长音频',
    );

    expect(document.isTimed, isTrue);
    expect(document.plainLines, isEmpty);
    expect(document.timedLines.map((line) => line.timestamp.inMilliseconds), [
      62300,
      63450,
      64567,
      7385000,
    ]);
    expect(document.timedLines.map((line) => line.text), [
      '十分之一秒',
      '百分之一秒',
      '毫秒',
      '长音频',
    ]);
  });

  test(
    'multiple timestamps are sorted and duplicate translations are merged',
    () {
      final document = LyricsDocument.parse(
        '[00:03][00:01]原文\n'
        '[00:01.000]译文\n'
        '[00:01.00]原文\n'
        '[00:01]\n'
        '[00:02]中间一句',
      );

      expect(document.timedLines.map((line) => line.text), [
        '原文\n译文',
        '中间一句',
        '原文',
      ]);
      expect(document.timedLines.map((line) => line.timestamp.inSeconds), [
        1,
        2,
        3,
      ]);
    },
  );

  test(
    'last valid global offset advances positive and delays negative time',
    () {
      final advanced = LyricsDocument.parse(
        '[offset:-100]\n[00:02]第一句\n[offset:+500]\n'
        '[offset:invalid]\n[00:03]第二句',
      );
      expect(advanced.timedLines.map((line) => line.timestamp.inMilliseconds), [
        1500,
        2500,
      ]);

      final delayed = LyricsDocument.parse('[00:02]延后\n[OFFSET: -750]');
      expect(delayed.timedLines.single.timestamp.inMilliseconds, 2750);
    },
  );

  test('offset clamps before zero and retains merged text in source order', () {
    final document = LyricsDocument.parse(
      '[00:00.200]先出现的文本\n[00:00.100]后出现的文本\n[offset:+500]',
    );

    expect(document.timedLines, hasLength(1));
    expect(document.timedLines.single.timestamp, Duration.zero);
    expect(document.timedLines.single.text, '先出现的文本\n后出现的文本');
  });

  test(
    'out-of-range offset text is ignored and extreme native values do not wrap',
    () {
      final ignored = LyricsDocument.parse(
        '[offset:250]\n[offset:9999999999999999999999999999999999]\n'
        '[00:01]保留有效偏移',
      );
      expect(ignored.timedLines.single.timestamp.inMilliseconds, 750);

      final extreme = LyricsDocument.parse(
        '[offset:-9223372036854775808]\n[00:01]不会溢出',
      );
      expect(extreme.timedLines.single.timestamp, greaterThan(Duration.zero));
      expect(extreme.activeIndex(const Duration(hours: 24)), -1);
    },
  );

  test('empty, whitespace and metadata-only input contain no lyric', () {
    for (final source in [
      '',
      '\uFEFF\r\n  \n',
      '[ar:Artist]\n[ti:Title]\n[au:Author]\n[by:Editor]\n[offset:0]',
    ]) {
      final document = LyricsDocument.parse(source);
      expect(document.isTimed, isFalse);
      expect(document.timedLines, isEmpty);
      expect(document.plainLines, isEmpty);
      expect(document.activeIndex(const Duration(seconds: 10)), -1);
    }
  });

  test('plain lyrics retain text and section headings without metadata', () {
    final document = LyricsDocument.parse(
      '\uFEFF[ar:歌手]\n\n 第一行 \n[Chorus]\n第二行\n',
    );

    expect(document.isTimed, isFalse);
    expect(document.plainLines, ['第一行', '[Chorus]', '第二行']);
    expect(document.activeIndex(Duration.zero), -1);
  });

  test(
    'malformed timestamps fall back to readable text rather than timing',
    () {
      final document = LyricsDocument.parse(
        '[00:61]秒超限\n[1000:01]分钟超限\n[00:01.1234]精度超限\n'
        '[1:2]秒不足两位\n[00:bad]时间无效\n[offset:bad]',
      );

      expect(document.isTimed, isFalse);
      expect(document.timedLines, isEmpty);
      expect(document.plainLines, ['秒超限', '分钟超限', '精度超限', '秒不足两位', '时间无效']);
    },
  );

  test('invalid tags never become timed events alongside valid timestamps', () {
    final document = LyricsDocument.parse(
      '[00:61]无效时间\n[00:02][00:90]有效时间的正文\n普通说明\n[00:04]尾句',
    );

    expect(document.timedLines.map((line) => line.text), ['有效时间的正文', '尾句']);
    expect(document.timedLines.map((line) => line.timestamp.inSeconds), [2, 4]);
    expect(document.plainLines, isEmpty);
  });

  test(
    'active index handles before, exact, between, after and backwards seek',
    () {
      final document = LyricsDocument.parse('[00:01]一\n[00:03]三\n[00:05]五');

      expect(document.activeIndex(const Duration(milliseconds: -1)), -1);
      expect(document.activeIndex(Duration.zero), -1);
      expect(document.activeIndex(const Duration(milliseconds: 999)), -1);
      expect(document.activeIndex(const Duration(seconds: 1)), 0);
      expect(document.activeIndex(const Duration(milliseconds: 2999)), 0);
      expect(document.activeIndex(const Duration(seconds: 3)), 1);
      expect(document.activeIndex(const Duration(hours: 1)), 2);
      expect(document.activeIndex(const Duration(seconds: 1)), 0);
    },
  );

  test('empty timed lines remain explicit clearing events', () {
    final document = LyricsDocument.parse('[00:01]前句\n[00:02]\n[00:03]后句');

    expect(document.timedLines, hasLength(3));
    expect(document.activeIndex(const Duration(milliseconds: 2500)), 1);
    expect(document.timedLines[1].text, isEmpty);
  });

  test('parsed lists are immutable snapshots', () {
    final timed = LyricsDocument.parse('[00:01]歌词');
    final plain = LyricsDocument.parse('普通歌词');

    expect(() => timed.timedLines.clear(), throwsUnsupportedError);
    expect(() => timed.plainLines.add('内容'), throwsUnsupportedError);
    expect(() => plain.plainLines.clear(), throwsUnsupportedError);
    expect(
      () => plain.timedLines.add(
        const LyricsLine(timestamp: Duration.zero, text: '内容'),
      ),
      throwsUnsupportedError,
    );
  });
}
