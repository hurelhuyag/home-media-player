import 'dart:io';

import 'package:flutter/foundation.dart';

import 'config.dart';

/// Standby: the HDMI output is switched off while the box keeps running, so
/// the TV remote can wake it again over CEC (a real shutdown can't be undone
/// from the remote). Entered from the Power menu or when the TV turns off;
/// left when the TV switches back to the box or a remote key is pressed.
class Standby extends ChangeNotifier {
  Standby._();

  static final Standby instance = Standby._();

  bool _active = false;

  bool get isActive => _active;

  Future<void> enter() async {
    if (_active) return;
    _active = true;
    debugPrint('standby: on');
    notifyListeners();
    await _setOutputs(on: false);
  }

  Future<void> exit() async {
    if (!_active) return;
    _active = false;
    debugPrint('standby: off');
    await _setOutputs(on: true);
    notifyListeners();
  }

  /// Through cage's output management, like the session script's mode
  Future<void> _setOutputs({required bool on}) async {
    final mode = Config.instance.outputMode;
    try {
      final list = await Process.run('wlr-randr', []);
      final outputs = (list.stdout as String)
          .split('\n')
          .where((l) => l.isNotEmpty && !l.startsWith(' '))
          .map((l) => l.split(' ').first);
      for (final output in outputs) {
        final result = await Process.run('wlr-randr', [
          '--output', output,
          if (on) '--on' else '--off',
          if (on && mode.isNotEmpty) ...['--mode', mode],
        ]);
        if (result.exitCode != 0) debugPrint('standby: $output: ${(result.stderr as String).trim()}');
      }
    } on ProcessException catch (e) {
      debugPrint('standby: $e');
    }
  }
}
