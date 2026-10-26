import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../remote.dart';

/// Full-screen photo viewer. Left/right = previous/next, OK/play = slideshow.
class ImageScreen extends StatefulWidget {
  const ImageScreen({super.key, required this.images, required this.index});

  final List<File> images;
  final int index;

  @override
  State<ImageScreen> createState() => _ImageScreenState();
}

class _ImageScreenState extends State<ImageScreen> {
  static const _slideshowInterval = Duration(seconds: 5);

  late int _index = widget.index;
  Timer? _slideshow;
  bool _showName = true;
  Timer? _nameTimer;

  @override
  void dispose() {
    _slideshow?.cancel();
    _nameTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _precacheAround();
  }

  /// Decode at screen size, a 24MP photo at full size takes ~100MB of RAM.
  ImageProvider _provider(File f) {
    final size = MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
    return ResizeImage(FileImage(f), width: size.width.round(), height: size.height.round(), policy: ResizeImagePolicy.fit);
  }

  void _precacheAround() {
    for (final i in [_index - 1, _index + 1]) {
      if (i >= 0 && i < widget.images.length) precacheImage(_provider(widget.images[i]), context);
    }
  }

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.images.length) {
      if (_slideshow != null && next >= widget.images.length) _toggleSlideshow();
      return;
    }
    setState(() {
      _index = next;
      _showName = true;
    });
    _precacheAround();
    _nameTimer?.cancel();
    _nameTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showName = false);
    });
  }

  void _toggleSlideshow() {
    setState(() {
      if (_slideshow != null) {
        _slideshow!.cancel();
        _slideshow = null;
      } else {
        _slideshow = Timer.periodic(_slideshowInterval, (_) => _go(1));
      }
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft || RemoteKeys.isPrevious(k) || RemoteKeys.isRewind(k)) {
      _go(-1);
    } else if (k == LogicalKeyboardKey.arrowRight || RemoteKeys.isNext(k) || RemoteKeys.isFastForward(k)) {
      _go(1);
    } else if (RemoteKeys.isSelect(k) || RemoteKeys.isPlayPause(k)) {
      _toggleSlideshow();
    } else if (RemoteKeys.isStop(k)) {
      Navigator.of(context).maybePop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.images[_index];
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image(
              key: ValueKey(file.path),
              image: _provider(file),
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (context, error, _) => Center(child: Text("Can't show ${p.basename(file.path)}")),
            ),
            if (_showName || _slideshow != null)
              Align(
                alignment: Alignment.bottomLeft,
                child: Container(
                  margin: const EdgeInsets.all(32),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                  child: Text(
                    '${_slideshow != null ? '▶  ' : ''}${p.basename(file.path)}   ${_index + 1}/${widget.images.length}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
