import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'config.dart';

/// Runs Chromium with YouTube TV on top of the kiosk. It is the only child
/// process the kiosk starts; everything else is rendered in-process.
class YouTube extends ChangeNotifier {
  YouTube._();

  static final YouTube instance = YouTube._();

  static const _extensionAssets = ['manifest.json', 'background.js', 'bridge.js', 'page.js', 'hide-cursor.css'];

  static const _startupTime = Duration(seconds: 10);

  Process? _process;
  Timer? _startup;

  bool get isRunning => _process != null;

  /// True while Chromium is launched but probably not on screen yet.
  bool get isStarting => _startup?.isActive ?? false;

  Future<void> launch() async {
    if (_process != null) return;
    final config = Config.instance;
    final extensionDir = await _prepareExtension(config);
    final args = [
      '--ozone-platform=wayland',
      '--kiosk',
      '--app=${config.youtubeUrl}',
      '--user-agent=${config.youtubeUserAgent}',
      '--user-data-dir=${config.dataDir}/youtube-profile',
      '--load-extension=$extensionDir',
      // Chromium 137+ ignores --load-extension unless this feature is off
      '--disable-features=DisableLoadExtensionCommandLineSwitch,Translate,MediaRouter',
      '--ignore-gpu-blocklist',
      '--enable-gpu-rasterization',
      '--autoplay-policy=no-user-gesture-required',
      '--no-first-run',
      '--no-default-browser-check',
      '--noerrdialogs',
      '--disable-session-crashed-bubble',
      '--hide-crash-restore-bubble',
      '--password-store=basic',
      '--overscroll-history-navigation=0',
      '--check-for-update-interval=31536000',
      ...config.chromiumExtraFlags,
    ];
    debugPrint('youtube: ${config.chromium} ${args.join(' ')}');
    // Not the player's FFmpeg/libmpv (hmp-hwdec-libs)
    final env = Map.of(Platform.environment)..remove('LD_LIBRARY_PATH');
    final process = await Process.start(config.chromium, args, environment: env, includeParentEnvironment: false);
    _process = process;
    _startup = Timer(_startupTime, notifyListeners);
    notifyListeners();
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => debugPrint('chromium: $l'));
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => debugPrint('chromium: $l'));
    unawaited(process.exitCode.then((code) {
      debugPrint('youtube: chromium exited with $code');
      _process = null;
      _startup?.cancel();
      notifyListeners();
    }));
  }

  void close() {
    final process = _process;
    if (process == null) return;
    process.kill(ProcessSignal.sigterm);
    // Chromium sometimes hangs on shutdown while a video plays
    Timer(const Duration(seconds: 3), () {
      if (_process == process) process.kill(ProcessSignal.sigkill);
    });
  }

  /// Copies the bundled extension next to the profile and writes its config,
  /// since content scripts can't read our environment.
  Future<String> _prepareExtension(Config config) async {
    final dir = Directory('${config.dataDir}/youtube-extension');
    await dir.create(recursive: true);
    for (final name in _extensionAssets) {
      final data = await rootBundle.load('assets/chromium-extension/$name');
      await File('${dir.path}/$name').writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    await File('${dir.path}/config.js').writeAsString(
      'window.__hmpConfig = ${jsonEncode({'forceH264': config.youtubeForceH264})};\n',
      flush: true,
    );
    return dir.path;
  }
}
