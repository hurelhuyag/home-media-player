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

/// Something the player can play: a local file or a stream.
class PlayItem {
  const PlayItem({required this.uri, required this.title, this.audio = false, this.httpHeaders});

  PlayItem.file(File file) : this(uri: file.path, title: p.basename(file.path), audio: kindOf(file) == MediaKind.audio);

  final String uri;
  final String title;
  final bool audio;
  final Map<String, String>? httpHeaders;
}

/// Plays local videos and music, and live TV streams, with libmpv inside the
/// kiosk process.
///
/// It behaves like the mpv program: keys go to mpv, so its default bindings
/// and the user's input.conf apply, and mpv draws its own OSD/OSC. Only
/// closing the player stays with the app, since mpv's `quit` would shut down
/// the embedded player instead.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.playlist, required this.index, this.live = false});

  final List<PlayItem> playlist;
  final int index;

  /// Live TV: no resume positions, channel up/down switch channels.
  final bool live;

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
  Timer? _saveTimer;

  /// With mpv's save-position-on-quit, saves where each file is so it resumes
  /// there next time: every 30 s while playing (survives a crash or power
  /// cut) and when closing. The embedded player never runs mpv's `quit`, which
  /// is the only time mpv saves by itself.
  static const _saveInterval = Duration(seconds: 30);
  String? _error;
  bool _hwdecCopy = false;

  /// Paused because the TV switched to another source, so switching back
  /// resumes it (but not a video the user paused).
  bool _pausedForTv = false;

  NativePlayer get _mpv => _player.platform as NativePlayer;

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(_player.stream.playlist.listen((pl) {
        // Live TV opens one channel at a time (_tune)
        if (widget.live || pl.index == _index) return;
        _restoreHwdec();
        if (mounted) {
          setState(() {
            _index = pl.index;
            _error = null;
          });
        }
      }))
      ..add(_player.stream.videoParams.listen(_checkHwdec))
      ..add(_player.stream.completed.listen((done) {
        // Last file finished: back to the list
        if (done && !widget.live && _index == widget.playlist.length - 1 && mounted) Navigator.of(context).maybePop();
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
    // mpv's watch-later files: opening a file resumes it where it was left
    await _mpv.setProperty('watch-later-dir', '${config.dataDir}/watch_later');
    await _mpv.setProperty('resume-playback', 'yes');
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
    if (widget.live) {
      // A live stream has no position to come back to
      await _mpv.setProperty('resume-playback', 'no');
      await _mpv.setProperty('save-position-on-quit', 'no');
    }
    _saveTimer = Timer.periodic(_saveInterval, (_) {
      if (_player.state.playing) _savePosition(_mpv);
    });
    if (widget.live) {
      await _tune(widget.index);
    } else {
      await _player.open(Playlist(
        [for (final item in widget.playlist) Media(item.uri, httpHeaders: item.httpHeaders)],
        index: widget.index,
      ));
    }
  }

  /// Live TV: opens one channel at a time. In an mpv playlist a channel that
  /// fails to open is skipped, so every broken channel would show the next
  /// working one; this way its error shows instead.
  Future<void> _tune(int index) async {
    index %= widget.playlist.length;
    final item = widget.playlist[index];
    _restoreHwdec();
    if (mounted) {
      setState(() {
        _index = index;
        _error = null;
      });
    }
    await _player.open(Media(item.uri, httpHeaders: item.httpHeaders));
    // Streams have no useful title of their own: the channel name goes on
    // screen and in the OSC
    await _mpv.setProperty('force-media-title', item.title);
    await _mpv.command(['show-text', item.title, '3000']);
  }

  /// The Amlogic decoder pads HEVC and VP9 rows to 32 bytes, but Panfrost
  /// only imports frames whose rows are a multiple of 64 bytes ("rejecting
  /// image due to unsupported offset or stride alignment" and a blue picture),
  /// e.g. 720 wide. Those videos get their frames copied instead.
  Future<void> _checkHwdec(VideoParams params) async {
    final w = params.w ?? 0;
    if (w == 0 || (w + 31) ~/ 32 % 2 == 0) return;
    try {
      if (await _mpv.getProperty('hwdec-current') != 'v4l2request') return;
      final codec = await _mpv.getProperty('current-tracks/video/codec');
      if (codec != 'hevc' && codec != 'vp9') return;
      debugPrint('player: $codec ${w}px wide, rows not 64-byte aligned: v4l2request-copy');
      _hwdecCopy = true;
      await _mpv.setProperty('hwdec', 'v4l2request-copy');
    } catch (e) {
      debugPrint('player: hwdec check failed: $e');
    }
  }

  /// Back to the configured hwdec for the next file.
  void _restoreHwdec() {
    if (!_hwdecCopy) return;
    _hwdecCopy = false;
    unawaited(_mpv.setProperty('hwdec', Config.instance.hwdec));
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    // Disposing a player that is still decoding/rendering crashes the app
    // (use-after-free in libavcodec or Flutter's raster thread). Stop it
    // first and give mpv a moment to tear down its decoder and renderer.
    _saveTimer?.cancel();
    final player = _player;
    unawaited(() async {
      try {
        await _savePosition(player.platform as NativePlayer);
        await player.stop();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } finally {
        await player.dispose();
      }
    }());
    super.dispose();
  }

  /// Writes mpv's watch-later entry for the current file, if mpv.conf has
  /// save-position-on-quit. Not for a file that has played to the end, or it
  /// would reopen at its last second.
  static Future<void> _savePosition(NativePlayer mpv) async {
    if (mpv.state.completed) return;
    try {
      if (await mpv.getProperty('save-position-on-quit') != 'yes') return;
      await mpv.command(['write-watch-later-config']);
    } catch (e) {
      debugPrint('player: saving position failed: $e');
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.handled;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.home) return KeyEventResult.ignored; // app-wide: back to launcher
    if (RemoteKeys.isBack(k) || RemoteKeys.isStop(k) || event.character == 'q' || event.character == 'Q') {
      if (event is KeyDownEvent) Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    if (widget.live && (RemoteKeys.isNext(k) || RemoteKeys.isPrevious(k))) {
      // Channel up/down (and skip) on the remote
      if (event is! KeyUpEvent) _tune(_index + (k == LogicalKeyboardKey.pageUp || k == LogicalKeyboardKey.mediaTrackNext ? 1 : -1));
      return KeyEventResult.handled;
    }
    if (RemoteKeys.isSourceLost(k)) {
      if (event is KeyDownEvent && _player.state.playing) {
        _pausedForTv = true;
        _player.pause();
      }
      return KeyEventResult.handled;
    }
    if (RemoteKeys.isSourceBack(k)) {
      if (event is KeyDownEvent && _pausedForTv) {
        _pausedForTv = false;
        _player.play();
      }
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
    final item = widget.playlist[_index];
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
            if (item.audio)
              _MusicView(player: _player, title: item.title)
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
