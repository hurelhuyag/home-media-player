import 'dart:io';

/// Runtime settings. The systemd unit loads them from
/// /etc/default/home-media-player, so the box can be tuned without a rebuild.
class Config {
  Config._(this._env);

  static final Config instance = Config._(Platform.environment);

  final Map<String, String> _env;

  String _str(String key, String fallback) {
    final v = _env[key];
    return v == null || v.isEmpty ? fallback : v;
  }

  bool _bool(String key, bool fallback) {
    final v = _env[key];
    if (v == null || v.isEmpty) return fallback;
    return v == '1' || v.toLowerCase() == 'true' || v.toLowerCase() == 'yes';
  }

  String get youtubeUrl => _str('HMP_YOUTUBE_URL', 'https://www.youtube.com/tv');

  /// youtube.com/tv only serves the TV UI to TV-like browsers.
  String get youtubeUserAgent => _str(
        'HMP_YOUTUBE_USER_AGENT',
        'Mozilla/5.0 (PS4; Leanback Shell) Gecko/20100101 Firefox/65.0 '
            'LeanbackShell/01.00.01.75 Sony PS4/ (PS4, , no, CH)',
      );

  /// Hide VP9/AV1 from YouTube so it serves H.264, which the CPU can decode
  /// in software at 1080p. Chromium has no hardware decoder on this SoC.
  bool get youtubeForceH264 => _bool('HMP_YOUTUBE_FORCE_H264', true);

  String get chromium => _str('HMP_CHROMIUM', '/usr/bin/chromium');

  List<String> get chromiumExtraFlags =>
      _str('HMP_CHROMIUM_FLAGS', '').split(' ').where((s) => s.isNotEmpty).toList();

  /// mpv hwdec value. Software decoding by default: the Amlogic V4L2 decoder
  /// (`v4l2m2m-copy`, staging driver meson_vdec) saves CPU but can hang inside
  /// the kernel and freeze the player until a reboot. Zero-copy `v4l2m2m`
  /// doesn't work with media_kit's GL renderer at all.
  String get hwdec => _str('HMP_HWDEC', 'no');

  /// mpv.conf, input.conf and scripts/ for the player, like ~/.config/mpv.
  String get mpvConfigDir => _str('HMP_MPV_CONFIG_DIR', '/etc/home-media-player/mpv');

  /// Extra mpv properties, `name=value` separated by `;`,
  /// e.g. `audio-device=alsa/hdmi;audio-channels=auto`.
  Map<String, String> get mpvOptions => _pairs(_str('HMP_MPV_OPTIONS', ''));

  /// Folders shown next to the disks, `Name=/path` separated by `;`,
  /// e.g. `Downloads=/srv/torrents`.
  Map<String, String> get bookmarks => _pairs(_str('HMP_BOOKMARKS', ''));

  double get textScale => double.tryParse(_str('HMP_TEXT_SCALE', '')) ?? 1.5;

  /// Log every key event, handy for mapping a new TV remote.
  bool get debugKeys => _bool('HMP_DEBUG_KEYS', false);

  /// Name of the virtual keyboard created by cec2uinput.
  String get remoteDeviceName => _str('HMP_REMOTE_DEVICE', 'cec2uinput');

  String get dataDir {
    final xdg = _env['XDG_DATA_HOME'];
    final base = xdg != null && xdg.isNotEmpty ? xdg : '${_env['HOME'] ?? '/tmp'}/.local/share';
    return '$base/home-media-player';
  }

  static Map<String, String> _pairs(String s) {
    final result = <String, String>{};
    for (final part in s.split(';')) {
      final i = part.indexOf('=');
      if (i > 0) result[part.substring(0, i).trim()] = part.substring(i + 1).trim();
    }
    return result;
  }
}
