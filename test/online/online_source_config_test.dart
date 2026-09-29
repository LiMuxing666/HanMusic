import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/online_source_config.dart';

import 'online_test_support.dart';

void main() {
  test('versioned configuration round-trips and encodes query parameters', () {
    final config = source();
    final restored = OnlineSourceConfig.fromJsonText(
      jsonEncode(config.toJson()),
    );
    final uri = restored.endpoint('search', {'q': '中文 & ? + /', 'page': '0'});
    expect(uri.queryParameters['q'], '中文 & ? + /');
    expect(uri.host, '127.0.0.1');
    expect(restored.toJson(), config.toJson());
  });

  test('only schema 1 and anonymous configurations are accepted', () {
    for (final extra in ['token', 'headers', 'script', 'authorization']) {
      expect(
        () => OnlineSourceConfig.fromJson({...sourceJson(), extra: 'secret'}),
        throwsFormatException,
      );
    }
    expect(
      () => OnlineSourceConfig.fromJson({...sourceJson(), 'schemaVersion': 2}),
      throwsA(isA<UnsupportedOnlineSourceVersion>()),
    );
    final nested = sourceJson();
    (nested['search'] as Map)['headers'] = {};
    expect(() => OnlineSourceConfig.fromJson(nested), throwsFormatException);
  });

  test(
    'base URLs reject credentials query fragments and non-HTTP protocols',
    () {
      for (final base in [
        'file:///D:/data',
        'https://user:secret@host.test/',
        'http://@host.test/',
        'http://host.test/?q=secret',
        'http://host.test/#fragment',
        'http://host.test:99999/',
        'http://host.test\\evil/',
      ]) {
        expect(
          () => OnlineSourceConfig.fromJson(sourceJson(baseUrl: base)),
          throwsFormatException,
          reason: base,
        );
      }
    },
  );

  test(
    'endpoints reject redirects traversal nested encoding and query text',
    () {
      for (final path in [
        'https://other.test/search',
        '//other.test/search',
        '../search',
        'safe/../search',
        '%2e%2e/search',
        '%252e%252e/search',
        '%252525252e%252525252e/search',
        '%2f%2fother.test/search',
        'search?q=1',
        'search%3fq=1',
        'search#x',
        'safe\\search',
      ]) {
        final json = sourceJson();
        (json['search'] as Map)['path'] = path;
        expect(
          () => OnlineSourceConfig.fromJson(json),
          throwsFormatException,
          reason: path,
        );
      }
    },
  );

  test('field paths permit object keys and indices but never scripts', () {
    for (final path in [
      r'$.data',
      'items[0]',
      'data..items',
      'items.*.id',
      'eval(secret)',
      'data.000.id',
    ]) {
      final json = sourceJson();
      (json['search'] as Map)['itemsPath'] = path;
      expect(
        () => OnlineSourceConfig.fromJson(json),
        throwsFormatException,
        reason: path,
      );
    }
    expect(source().search.fields.title, 'info.0.title');
  });

  test('bounded numeric options and unique parameter names', () {
    for (final timeout in [0, 31, -1]) {
      expect(
        () => OnlineSourceConfig.fromJson(sourceJson(timeout: timeout)),
        throwsFormatException,
      );
    }
    final json = sourceJson();
    (json['search'] as Map)['limitParameter'] = 'p';
    expect(() => OnlineSourceConfig.fromJson(json), throwsFormatException);
    final huge = sourceJson();
    (huge['search'] as Map)['pageSize'] = 101;
    expect(() => OnlineSourceConfig.fromJson(huge), throwsFormatException);
  });
}
