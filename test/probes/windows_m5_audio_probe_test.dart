import 'package:flutter_test/flutter_test.dart';

import '../../tool/windows_m5_audio_probe.dart' show summarize;

void main() {
  test('ten startup samples report the slowest sample as nearest-rank p95', () {
    final samples = [
      9,
      1,
      5,
      2,
      6,
      3,
      7,
      4,
      8,
      1000,
    ].map((value) => <String, Object?>{'ms': value}).toList();
    expect(summarize(samples, 'ms'), {
      'count': 10,
      'minimum': 1.0,
      'maximum': 1000.0,
      'median': 5.5,
      'p95NearestRank': 1000.0,
    });
  });

  test('a cold-only phase has no invented warm latency percentiles', () {
    expect(summarize([], 'ms'), {'count': 0});
    expect(
      summarize([
        {'ms': 123.25},
      ], 'ms')['median'],
      123.25,
    );
  });
}
