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

  /// The remote's play/pause button. Not mediaPlay/mediaPause: cec2uinput
  /// sends those when the TV switches away from or back to the box
  /// ([isSourceLost], [isSourceBack]).
  static bool isPlayPause(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.mediaPlayPause || k == LogicalKeyboardKey.space;

  /// The TV switched to its tuner or another input (cec2uinput KEY_PAUSECD).
  static bool isSourceLost(LogicalKeyboardKey k) => k == LogicalKeyboardKey.mediaPause;

  /// The TV switched back to the box (cec2uinput KEY_PLAYCD).
  static bool isSourceBack(LogicalKeyboardKey k) => k == LogicalKeyboardKey.mediaPlay;

  static bool isStop(LogicalKeyboardKey k) => k == LogicalKeyboardKey.mediaStop;

  static bool isRewind(LogicalKeyboardKey k) => k == LogicalKeyboardKey.mediaRewind;

  static bool isFastForward(LogicalKeyboardKey k) => k == LogicalKeyboardKey.mediaFastForward;

  static bool isNext(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.mediaTrackNext || k == LogicalKeyboardKey.pageDown;

  static bool isPrevious(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.mediaTrackPrevious || k == LogicalKeyboardKey.pageUp;



}

/// Reads the cec2uinput evdev device directly to see remote keys and TV
/// events even while another Wayland client (Chromium) has keyboard focus.
/// Needs the kiosk user to be in the `input` group.
class GlobalRemoteListener {
  GlobalRemoteListener({required this.deviceName, required this.onKeyDown});

  /// Linux key codes (input-event-codes.h)
  static const keyHome = 102;
  static const keyPlayCd = 200; // cec2uinput: the TV switched back to us
  static const keyPauseCd = 201; // cec2uinput: the TV switched away
  static const keyScreenSaver = 0x245; // cec2uinput: the TV turned off

  static const _evKey = 1;
  static const _eventSize = 24; // struct input_event on 64-bit

  final String deviceName;
  final void Function(int code) onKeyDown;
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
            if (type == _evKey && value == 1) onKeyDown(code);
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
