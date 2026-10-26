import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../media.dart';
import '../widgets.dart';
import 'image_screen.dart';
import 'player_screen.dart';

enum SortOrder {
  name('Name', Icons.sort_by_alpha),
  newest('Newest first', Icons.arrow_downward),
  oldest('Oldest first', Icons.arrow_upward),
  random('Shuffle', Icons.shuffle);

  const SortOrder(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _Entry {
  _Entry(this.entity, this.kind, this.stat);

  final FileSystemEntity entity;
  final MediaKind kind;
  final FileStat stat;

  String get name => p.basename(entity.path);
}

class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key, required this.dir, required this.title});

  final Directory dir;
  final String title;

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  // Shared by all folders so the choice sticks while browsing
  static SortOrder _sort = SortOrder.name;
  static bool _foldersFirst = true;

  List<_Entry> _entries = [];

  /// Bumped on every sort, so the list starts again from its first row
  int _sortGeneration = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = <_Entry>[];
      await for (final e in widget.dir.list(followLinks: true)) {
        if (p.basename(e.path).startsWith('.')) continue;
        // `list` reports symlinks as links; resolve to what they point to
        final entity = e is Link
            ? (await FileSystemEntity.isDirectory(e.path) ? Directory(e.path) : File(e.path))
            : e;
        entries.add(_Entry(entity, kindOf(entity), await entity.stat()));
      }
      _sortEntries(entries);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } on FileSystemException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  void _sortEntries(List<_Entry> entries) {
    if (_sort == SortOrder.random) {
      entries.shuffle(Random());
      if (_foldersFirst) {
        // Shuffle folders and files separately (List.sort isn't stable)
        final folders = entries.where((e) => e.kind == MediaKind.directory).toList();
        final files = entries.where((e) => e.kind != MediaKind.directory).toList();
        entries
          ..clear()
          ..addAll(folders)
          ..addAll(files);
      }
      return;
    }
    final int Function(_Entry, _Entry) order = switch (_sort) {
      SortOrder.name => (a, b) => _naturalCompare(a.name, b.name),
      SortOrder.newest => (a, b) => b.stat.modified.compareTo(a.stat.modified),
      SortOrder.oldest => (a, b) => a.stat.modified.compareTo(b.stat.modified),
      SortOrder.random => (a, b) => 0,
    };
    entries.sort((a, b) {
      if (_foldersFirst) {
        final folders = (a.kind == MediaKind.directory ? 0 : 1) - (b.kind == MediaKind.directory ? 0 : 1);
        if (folders != 0) return folders;
      }
      return order(a, b);
    });
  }

  void _setSort({SortOrder? sort, bool? foldersFirst}) {
    setState(() {
      _sort = sort ?? _sort;
      _foldersFirst = foldersFirst ?? _foldersFirst;
      _sortEntries(_entries);
      _sortGeneration++;
    });
  }

  void _cycleSort() => _setSort(sort: SortOrder.values[(_sort.index + 1) % SortOrder.values.length]);

  void _open(_Entry entry) {
    final nav = Navigator.of(context);
    switch (entry.kind) {
      case MediaKind.directory:
        nav.push(MaterialPageRoute(
          builder: (_) => FilesScreen(dir: entry.entity as Directory, title: '${widget.title} › ${entry.name}'),
        ));
      case MediaKind.video:
      case MediaKind.audio:
        final playlist = _entries
            .where((e) => e.kind == MediaKind.video || e.kind == MediaKind.audio)
            .map((e) => e.entity as File)
            .toList();
        nav.push(MaterialPageRoute(
          builder: (_) => PlayerScreen(playlist: playlist, index: playlist.indexWhere((f) => f.path == entry.entity.path)),
        ));
      case MediaKind.image:
        final images = _entries.where((e) => e.kind == MediaKind.image).map((e) => e.entity as File).toList();
        nav.push(MaterialPageRoute(
          builder: (_) => ImageScreen(images: images, index: images.indexWhere((f) => f.path == entry.entity.path)),
        ));
      case MediaKind.other:
        showToast(context, "Can't open ${entry.name}");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Focus(
        // The remote's menu key cycles the sort order from anywhere
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.contextMenu) {
            _cycleSort();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 48, 0),
          child: Column(
            children: [
              TvHeader(title: widget.title),
              Expanded(
                child: TvSideMenuLayout(
                  menu: [
                    const _MenuLabel('Sort by'),
                    for (final sort in SortOrder.values)
                      TvMenuButton(
                        icon: sort.icon,
                        label: sort.label,
                        selected: sort == _sort,
                        onSelect: () => _setSort(sort: sort),
                      ),
                    const _MenuLabel('Folders'),
                    TvMenuButton(
                      icon: Icons.folder_copy,
                      label: 'Folders first',
                      selected: _foldersFirst,
                      onSelect: () => _setSort(foldersFirst: true),
                    ),
                    TvMenuButton(
                      icon: Icons.low_priority,
                      label: 'Mixed with files',
                      selected: !_foldersFirst,
                      onSelect: () => _setSort(foldersFirst: false),
                    ),
                  ],
                  content: _buildList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!));
    if (_entries.isEmpty) return const Center(child: Text('This folder is empty'));
    return ListView.builder(
      key: ValueKey(_sortGeneration),
      itemCount: _entries.length,
      itemBuilder: (context, i) {
        final e = _entries[i];
        return TvListItem(
          autofocus: i == 0,
          icon: switch (e.kind) {
            MediaKind.directory => Icons.folder,
            MediaKind.video => Icons.movie,
            MediaKind.audio => Icons.music_note,
            MediaKind.image => Icons.image,
            MediaKind.other => Icons.insert_drive_file,
          },
          title: e.name,
          subtitle: '${e.kind == MediaKind.directory ? 'Folder' : _humanSize(e.stat.size)} · ${_date(e.stat.modified)}',
          onSelect: () => _open(e),
        );
      },
    );
  }
}

class _MenuLabel extends StatelessWidget {
  const _MenuLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: theme.hintColor)),
    );
  }
}

String _date(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

String _humanSize(int bytes) {
  const units = ['B', 'kB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${size.toStringAsFixed(size < 10 ? 1 : 0)} ${units[unit]}';
}

/// "Episode 2" sorts before "Episode 10".
int _naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final ta = re.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final tb = re.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < min(ta.length, tb.length); i++) {
    final na = int.tryParse(ta[i]);
    final nb = int.tryParse(tb[i]);
    final c = na != null && nb != null ? na.compareTo(nb) : ta[i].compareTo(tb[i]);
    if (c != 0) return c;
  }
  return ta.length - tb.length;
}
