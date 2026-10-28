import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'config.dart';

/// A live TV channel from an M3U playlist.
class Channel {
  const Channel({required this.name, required this.url, this.groups = const [], this.logo, this.httpHeaders = const {}});

  final String name;
  final String url;

  /// Categories (`group-title`, `;`-separated in iptv-org's lists)
  final List<String> groups;
  final String? logo;

  /// User-Agent / Referer some streams need (`http-user-agent` and
  /// `http-referrer` in the playlist)
  final Map<String, String> httpHeaders;
}

/// Parses an extended M3U playlist as published by iptv-org:
/// `#EXTINF:-1 tvg-logo=".." group-title="..",Name`, optional
/// `#EXTVLCOPT:http-user-agent=..` lines, then the stream URL.
List<Channel> parseM3u(String text) {
  final channels = <Channel>[];
  final attr = RegExp(r'([\w-]+)="([^"]*)"');
  String? name;
  var attrs = <String, String>{};
  var headers = <String, String>{};

  void header(String key, String value) {
    if (value.isEmpty) return;
    if (key == 'http-user-agent') headers['User-Agent'] = value;
    if (key == 'http-referrer') headers['Referer'] = value;
  }

  // Playlists often have Windows line endings
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.startsWith('#EXTINF:')) {
      attrs = {};
      headers = {};
      var end = 0;
      for (final m in attr.allMatches(line)) {
        attrs[m.group(1)!] = m.group(2)!;
        end = m.end;
      }
      // The name follows the first comma after the attributes (whose values,
      // like a User-Agent, can contain commas themselves)
      final comma = line.indexOf(',', end);
      name = comma < 0 ? null : line.substring(comma + 1).trim();
      attrs.forEach(header);
    } else if (line.startsWith('#EXTVLCOPT:')) {
      final opt = line.substring('#EXTVLCOPT:'.length);
      final i = opt.indexOf('=');
      if (i > 0) header(opt.substring(0, i), opt.substring(i + 1));
    } else if (line.isNotEmpty && !line.startsWith('#')) {
      channels.add(Channel(
        name: name == null || name.isEmpty ? line : name,
        url: line,
        groups: [
          for (final g in (attrs['group-title'] ?? '').split(';'))
            if (g.trim().isNotEmpty && g.trim() != 'Undefined') g.trim(),
        ],
        logo: attrs['tvg-logo'],
        httpHeaders: headers,
      ));
      name = null;
      attrs = {};
      headers = {};
    }
  }
  return channels;
}

/// Downloads a playlist, keeping the last good copy for when the network or
/// GitHub is down. A path or file:// URL is read from disk.
Future<List<Channel>> loadPlaylist(String url) async {
  if (url.startsWith('/') || url.startsWith('file://')) {
    return parseM3u(await File(url.startsWith('/') ? url : Uri.parse(url).toFilePath()).readAsString());
  }
  final cache = File('${Config.instance.dataDir}/iptv/${_cacheName(url)}.m3u');
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      final text = await response.transform(utf8.decoder).join();
      final channels = parseM3u(text);
      if (channels.isEmpty) throw const FormatException('no channels in the playlist');
      await cache.parent.create(recursive: true);
      await cache.writeAsString(text);
      return channels;
    } finally {
      client.close();
    }
  } catch (e) {
    debugPrint('iptv: $url: $e');
    if (await cache.exists()) return parseM3u(await cache.readAsString());
    rethrow;
  }
}

String _cacheName(String url) {
  final name = url.replaceFirst(RegExp(r'^\w+://'), '').replaceAll(RegExp(r'[^\w.-]+'), '_');
  return name.length > 120 ? name.substring(name.length - 120) : name;
}
