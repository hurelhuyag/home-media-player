import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../config.dart';
import '../media.dart';
import '../remote.dart';

/// Plays local videos and music with libmpv inside the kiosk process.
///
/// It behaves like the mpv program: keys go to mpv, so its default bindings
/// and the user's input.conf apply, and mpv draws its own OSD/OSC. Only
/// closing the player stays with the app, since mpv's `quit` would shut down
/// the embedded player instead.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.playlist, required this.index});

  final List<File> playlist;
  final int index;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final _player = Player(configuration: const PlayerConfiguration(title: 'Home Media Player', osc: true));
  late final _video = VideoController(
    _player,
    configuration: VideoControllerConfiguration(hwdec: Config.instance.hwdec),
  );
  final _subscriptions = <StreamSubscription<Object?>>[];

  late int _index = widget.index;
  String? _error;

  NativePlayer get _mpv => _player.platform as NativePlayer;

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(_player.stream.playlist.listen((pl) {
        if (mounted && pl.index != _index) setState(() => _index = pl.index);
      }))
      ..add(_player.stream.completed.listen((done) {
        // Last file finished: back to the list
        if (done && _index == widget.playlist.length - 1 && mounted) Navigator.of(context).maybePop();
      }))
      ..add(_player.stream.error.listen((e) {
        if (mounted) setState(() => _error = e);
      }));
    _start();
  }

  Future<void> _start() async {
    final config = Config.instance;
    // libmpv starts without config files and key bindings; load them the way
    // the mpv program would from ~/.config/mpv.
    await _mpv.setProperty('input-default-bindings', 'yes');
    // No direct rendering: with it the decoder writes frames straight into
    // GPU-mapped buffers, and when the player closes they can be unmapped
    // under a decoder thread (SIGBUS/SIGSEGV in libavcodec, Panfrost GPU
    // page faults). Costs one frame copy.
    await _mpv.setProperty('vd-lavc-dr', 'no');
    final dir = config.mpvConfigDir;
    if (File('$dir/mpv.conf').existsSync()) await _mpv.command(['load-config-file', '$dir/mpv.conf']);
    if (File('$dir/input.conf').existsSync()) await _mpv.command(['load-input-conf', '$dir/input.conf']);
    final scripts = Directory('$dir/scripts');
    if (scripts.existsSync()) {
      for (final f in scripts.listSync()..sort((a, b) => a.path.compareTo(b.path))) {
        if (f.path.endsWith('.lua') || f.path.endsWith('.js')) await _mpv.command(['load-script', f.path]);
      }
    }
    for (final o in config.mpvOptions.entries) {
      await _mpv.setProperty(o.key, o.value);
    }
    await _player.open(Playlist(
      [for (final f in widget.playlist) Media(f.path)],
      index: widget.index,
    ));
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    // Disposing a player that is still decoding/rendering crashes the app
    // (use-after-free in libavcodec or Flutter's raster thread). Stop it
    // first and give mpv a moment to tear down its decoder and renderer.
    final player = _player;
    unawaited(() async {
      try {
        await player.stop();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } finally {
        await player.dispose();
      }
    }());
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.handled;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.home) return KeyEventResult.ignored; // app-wide: back to launcher
    if (RemoteKeys.isBack(k) || RemoteKeys.isStop(k) || event.character == 'q' || event.character == 'Q') {
      if (event is KeyDownEvent) Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    final name = mpvKeyName(event);
    if (name != null) {
      _mpv.command(['keypress', name]);
    } else if (Config.instance.debugKeys) {
      debugPrint('player: no mpv name for ${k.debugName}');
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = widget.playlist[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // mpv has no frame to draw its OSC on for music, and the video
            // surface would keep showing the previous video's last frame
            if (kindOf(file) == MediaKind.audio)
              _MusicView(player: _player, title: p.basename(file.path))
            else
              Video(controller: _video, controls: NoVideoControls, fill: Colors.black),
            if (_error != null)
              Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.all(48),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
                  child: Text(_error!, style: theme.textTheme.titleMedium),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MusicView extends StatelessWidget {
  const _MusicView({required this.player, required this.title});

  final Player player;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 160),
      child: StreamBuilder<Duration>(
        stream: player.stream.position,
        builder: (context, _) {
          final s = player.state;
          final total = s.duration.inMilliseconds;
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.music_note, size: 160),
              const SizedBox(height: 24),
              Text(title, maxLines: 2, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 32),
              LinearProgressIndicator(
                value: total > 0 ? (s.position.inMilliseconds / total).clamp(0.0, 1.0) : 0,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(s.playing ? Icons.play_arrow : Icons.pause),
                  const Spacer(),
                  Text('${_fmt(s.position)} / ${_fmt(s.duration)}', style: theme.textTheme.titleMedium),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

final _mpvNames = <LogicalKeyboardKey, String>{
  LogicalKeyboardKey.arrowLeft: 'LEFT',
  LogicalKeyboardKey.arrowRight: 'RIGHT',
  LogicalKeyboardKey.arrowUp: 'UP',
  LogicalKeyboardKey.arrowDown: 'DOWN',
  LogicalKeyboardKey.enter: 'ENTER',
  LogicalKeyboardKey.select: 'ENTER',
  LogicalKeyboardKey.numpadEnter: 'KP_ENTER',
  LogicalKeyboardKey.space: 'SPACE',
  LogicalKeyboardKey.backspace: 'BS',
  LogicalKeyboardKey.tab: 'TAB',
  LogicalKeyboardKey.delete: 'DEL',
  LogicalKeyboardKey.insert: 'INS',
  LogicalKeyboardKey.end: 'END',
  LogicalKeyboardKey.pageUp: 'PGUP',
  LogicalKeyboardKey.pageDown: 'PGDWN',
  LogicalKeyboardKey.contextMenu: 'MENU',
  LogicalKeyboardKey.mediaPlayPause: 'PLAYPAUSE',
  LogicalKeyboardKey.mediaPlay: 'PLAY',
  LogicalKeyboardKey.mediaPause: 'PAUSE',
  LogicalKeyboardKey.mediaRewind: 'REWIND',
  LogicalKeyboardKey.mediaFastForward: 'FORWARD',
  LogicalKeyboardKey.mediaTrackNext: 'NEXT',
  LogicalKeyboardKey.mediaTrackPrevious: 'PREV',
  LogicalKeyboardKey.audioVolumeUp: 'VOLUME_UP',
  LogicalKeyboardKey.audioVolumeDown: 'VOLUME_DOWN',
  LogicalKeyboardKey.audioVolumeMute: 'MUTE',
  LogicalKeyboardKey.f1: 'F1',
  LogicalKeyboardKey.f2: 'F2',
  LogicalKeyboardKey.f3: 'F3',
  LogicalKeyboardKey.f4: 'F4',
  LogicalKeyboardKey.f5: 'F5',
  LogicalKeyboardKey.f6: 'F6',
  LogicalKeyboardKey.f7: 'F7',
  LogicalKeyboardKey.f8: 'F8',
  LogicalKeyboardKey.f9: 'F9',
  LogicalKeyboardKey.f10: 'F10',
  LogicalKeyboardKey.f11: 'F11',
  LogicalKeyboardKey.f12: 'F12',
};

/// The key's name in mpv's input.conf syntax, e.g. `RIGHT`, `Ctrl+LEFT`, `#`.
String? mpvKeyName(KeyEvent event) {
  final keyboard = HardwareKeyboard.instance;
  final named = _mpvNames[event.logicalKey];
  if (named == null) {
    // Printable keys: the character already includes Shift (`#`, `J`)
    final ch = event.character;
    if (ch == null || ch.isEmpty || ch.codeUnitAt(0) < 0x20 || ch.codeUnitAt(0) == 0x7f) return null;
    final prefix = '${keyboard.isControlPressed ? 'Ctrl+' : ''}${keyboard.isAltPressed ? 'Alt+' : ''}';
    return '$prefix$ch';
  }
  return '${keyboard.isControlPressed ? 'Ctrl+' : ''}'
      '${keyboard.isAltPressed ? 'Alt+' : ''}'
      '${keyboard.isShiftPressed ? 'Shift+' : ''}$named';
}
