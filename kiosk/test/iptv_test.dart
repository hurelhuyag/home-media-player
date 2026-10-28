import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_media_player/iptv.dart';

void main() {
  test('parses iptv-org entries with Windows line endings', () {
    const ua = 'Mozilla/5.0 (X11; Linux) AppleWebKit/537.36 (KHTML, like Gecko)';
    final channels = parseM3u('#EXTM3U\r\n'
        '#EXTINF:-1 tvg-id="C1.mn@SD" tvg-logo="https://x/11.png" http-user-agent="$ua" group-title="Business;News",C1 (1080p)\r\n'
        '#EXTVLCOPT:http-user-agent=$ua\r\n'
        '#EXTVLCOPT:http-referrer=https://example.mn/\r\n'
        'https://cdn.example/C1.mpd\r\n'
        '#EXTINF:-1,Plain\r\n'
        'http://example/plain.m3u8\r\n');
    expect(channels, hasLength(2));
    final c1 = channels.first;
    expect(c1.name, 'C1 (1080p)');
    expect(c1.url, 'https://cdn.example/C1.mpd');
    expect(c1.logo, 'https://x/11.png');
    expect(c1.groups, ['Business', 'News']);
    expect(c1.httpHeaders, {'User-Agent': ua, 'Referer': 'https://example.mn/'});
    expect(channels.last.name, 'Plain');
    expect(channels.last.httpHeaders, isEmpty);
  });

  for (final (file, min) in [('mongolia.m3u', 30), ('english.m3u', 500)]) {
    test('reads the repository playlist $file', () {
      final channels = parseM3u(File('../iptv/$file').readAsStringSync());
      expect(channels.length, greaterThan(min));
      for (final c in channels) {
        expect(c.url, startsWith('http'));
        expect(c.name, isNot(contains('http')));
      }
    });
  }
}
