import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../config.dart';
import '../disks.dart';
import '../widgets.dart';
import 'files_screen.dart';

class DisksScreen extends StatefulWidget {
  const DisksScreen({super.key});

  @override
  State<DisksScreen> createState() => _DisksScreenState();
}

class _DisksScreenState extends State<DisksScreen> {
  List<Volume> _volumes = [];
  bool _loading = true;
  StreamSubscription<FileSystemEvent>? _devWatch;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _refresh();
    // Re-list when a USB disk is plugged in or removed
    _devWatch = Directory('/dev').watch().listen((event) {
      final name = event.path.split('/').last;
      if (!name.startsWith('sd') && !name.startsWith('nvme') && !name.startsWith('mmcblk')) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 1), _refresh);
    });
  }

  @override
  void dispose() {
    _devWatch?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final volumes = await listVolumes();
    final bookmarks = Config.instance.bookmarks.entries
        .map((e) => Volume(title: e.key, mountpoint: e.value))
        .toList();
    if (!mounted) return;
    setState(() {
      _volumes = [...bookmarks, ...volumes];
      _loading = false;
    });
  }

  Future<void> _open(Volume volume) async {
    var path = volume.mountpoint;
    if (path == null) {
      try {
        path = await mountVolume(volume);
      } catch (e) {
        if (mounted) showToast(context, 'Mount failed: $e');
        return;
      }
      unawaited(_refresh());
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FilesScreen(dir: Directory(path!), title: volume.title),
    ));
  }

  Future<void> _eject(Volume volume) async {
    try {
      await unmountVolume(volume);
      if (mounted) showToast(context, '${volume.title} can be removed now');
    } catch (e) {
      if (mounted) showToast(context, 'Unmount failed: $e');
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Column(
          children: [
            const TvHeader(title: 'Media'),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _volumes.isEmpty
                      ? const Center(child: Text('No disks found. Plug in a USB drive.'))
                      : ListView.builder(
                          itemCount: _volumes.length,
                          itemBuilder: (context, i) {
                            final v = _volumes[i];
                            return TvListItem(
                              autofocus: i == 0,
                              icon: v.isBookmark ? Icons.folder_special : Icons.storage,
                              title: v.title,
                              subtitle: v.subtitle,
                              onSelect: () => _open(v),
                              trailing: v.isMounted && !v.isBookmark && v.mountpoint!.startsWith('/media/')
                                  ? Padding(
                                      padding: const EdgeInsets.only(left: 12),
                                      child: SizedBox(
                                        width: 88,
                                        height: 72,
                                        child: TvFocusable(
                                          borderRadius: 12,
                                          onSelect: () => _eject(v),
                                          child: const Icon(Icons.eject, size: 40),
                                        ),
                                      ),
                                    )
                                  : null,
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
