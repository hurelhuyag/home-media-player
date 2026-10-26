import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Key groups for a TV remote coming through cec2uinput (see its keymap).
/// Media keys arrive under different logical keys depending on the XKB
/// keymap, so each action accepts all plausible variants.
abstract final class RemoteKeys {
  static bool isSelect(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter || k == LogicalKeyboardKey.select;

  static bool isBack(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.browserBack;

  static bool isPlayPause(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.mediaPlayPause ||
      k == LogicalKeyboardKey.mediaPlay ||
      k == LogicalKeyboardKey.mediaPause ||
      k == LogicalKeyboardKey.space;

  static bool isStop(LogicalKeyboardKey k) => k == LogicalKeyboardKey.mediaStop;

  static bool isRewind(LogicalKeyboardKey k) => k == LogicalKeyboardKey.mediaRewind;

  static bool isFastForward(LogicalKeyboardKey k) => k == LogicalKeyboardKey.mediaFastForward;

  static bool isNext(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.mediaTrackNext || k == LogicalKeyboardKey.pageDown;

  static bool isPrevious(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.mediaTrackPrevious || k == LogicalKeyboardKey.pageUp;



}

/// Reads the cec2uinput evdev device directly to catch the remote's HOME key
/// even while another Wayland client (Chromium) has keyboard focus.
/// Needs the kiosk user to be in the `input` group.
class GlobalRemoteListener {
  GlobalRemoteListener({required this.deviceName, required this.onHome});

  static const _evKey = 1;
  static const _keyHome = 102;
  static const _eventSize = 24; // struct input_event on 64-bit

  final String deviceName;
  final VoidCallback onHome;
  bool _stopped = false;

  void start() => unawaited(_run());

  void stop() => _stopped = true;

  Future<void> _run() async {
    while (!_stopped) {
      final path = await _findDevice();
      if (path == null) {
        await Future<void>.delayed(const Duration(seconds: 5));
        continue;
      }
      debugPrint('remote: listening on $path');
      RandomAccessFile? file;
      try {
        // A plain read loop, not File.openRead(): its stream never reports
        // the ENODEV a removed device returns, so a cec2uinput restart would
        // leave us waiting on a dead device forever.
        file = await File(path).open();
        while (!_stopped) {
          // evdev only ever returns whole events
          final bytes = await file.read(_eventSize * 64);
          if (bytes.isEmpty) break;
          final data = ByteData.sublistView(bytes);
          for (var off = 0; off + _eventSize <= bytes.length; off += _eventSize) {
            final type = data.getUint16(off + 16, Endian.little);
            final code = data.getUint16(off + 18, Endian.little);
            final value = data.getInt32(off + 20, Endian.little);
            if (type == _evKey && code == _keyHome && value == 1) onHome();
          }
        }
      } catch (e) {
        debugPrint('remote: $path: $e');
      } finally {
        await file?.close();
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<String?> _findDevice() async {
    final dir = Directory('/sys/class/input');
    if (!await dir.exists()) return null;
    await for (final entry in dir.list()) {
      final name = entry.path.split('/').last;
      if (!name.startsWith('event')) continue;
      try {
        final devName = (await File('${entry.path}/device/name').readAsString()).trim();
        if (devName == deviceName) return '/dev/input/$name';
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }
}
