import 'package:flutter/material.dart';

import '../config.dart';
import '../iptv.dart';
import '../widgets.dart';
import 'player_screen.dart';

/// Internet TV: the playlists from HMP_IPTV_PLAYLISTS. The menu on the left
/// picks the playlist and a category; the channels of the category are on the
/// right, and channel up/down in the player goes through the same list.
class InternetTvScreen extends StatefulWidget {
  const InternetTvScreen({super.key});

  @override
  State<InternetTvScreen> createState() => _InternetTvScreenState();
}

class _InternetTvScreenState extends State<InternetTvScreen> {
  final _playlists = Config.instance.iptvPlaylists;

  /// The playlist and category last watched, for the next visit
  static String? _lastPlaylist;
  static String? _lastGroup;

  late String? _playlist = _playlists.containsKey(_lastPlaylist) ? _lastPlaylist : _playlists.keys.firstOrNull;
  String? _group = _lastGroup;
  List<Channel>? _channels;
  String? _error;

  /// Changes whenever the list shown changes, to rebuild it from the top
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final name = _playlist;
    if (name == null) return;
    setState(() {
      _channels = null;
      _error = null;
    });
    try {
      final channels = await loadPlaylist(_playlists[name]!);
      if (!mounted || name != _playlist) return;
      setState(() {
        _channels = channels;
        if (_group != null && !channels.any((c) => c.groups.contains(_group))) _group = null;
        _generation++;
      });
    } catch (e) {
      if (mounted && name == _playlist) setState(() => _error = 'Could not load $name: $e');
    }
  }

  void _selectPlaylist(String name) {
    if (name == _playlist) return;
    _lastPlaylist = name;
    _lastGroup = null;
    setState(() {
      _playlist = name;
      _group = null;
    });
    _load();
  }

  void _selectGroup(String? group) {
    _lastGroup = group;
    setState(() {
      _group = group;
      _generation++;
    });
  }

  List<Channel> get _shown {
    final channels = _channels ?? const [];
    final group = _group;
    return group == null ? channels : channels.where((c) => c.groups.contains(group)).toList();
  }

  /// Categories by number of channels
  List<(String, int)> get _groups {
    final counts = <String, int>{};
    for (final c in _channels ?? const <Channel>[]) {
      for (final g in c.groups) {
        counts[g] = (counts[g] ?? 0) + 1;
      }
    }
    return [for (final e in counts.entries) (e.key, e.value)]..sort((a, b) => b.$2.compareTo(a.$2));
  }

  void _play(List<Channel> channels, int index) {
    _lastPlaylist = _playlist;
    final playlist = [
      for (final c in channels) PlayItem(uri: c.url, title: c.name, httpHeaders: c.httpHeaders.isEmpty ? null : c.httpHeaders),
    ];
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(playlist: playlist, index: index, live: true),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 48, 0),
        child: Column(
          children: [
            TvHeader(title: ['Internet TV', ?_playlist, ?_group].join(' › ')),
            Expanded(
              child: TvSideMenuLayout(
                menu: [
                  if (_playlists.length > 1) ...[
                    const TvMenuLabel('Lists'),
                    for (final name in _playlists.keys)
                      TvMenuButton(
                        icon: Icons.playlist_play,
                        label: name,
                        selected: name == _playlist,
                        onSelect: () => _selectPlaylist(name),
                      ),
                  ],
                  const TvMenuLabel('Category'),
                  TvMenuButton(
                    icon: Icons.apps,
                    label: 'All (${_channels?.length ?? 0})',
                    selected: _group == null,
                    onSelect: () => _selectGroup(null),
                  ),
                  for (final (group, count) in _groups)
                    TvMenuButton(
                      icon: _groupIcon(group),
                      label: '$group ($count)',
                      selected: group == _group,
                      onSelect: () => _selectGroup(group),
                    ),
                ],
                content: _error != null
                    ? Center(child: Text(_error!))
                    : _channels == null
                        ? const Center(child: CircularProgressIndicator())
                        : _playlists.isEmpty
                            ? const Center(child: Text('No playlists. Set HMP_IPTV_PLAYLISTS in /etc/default/home-media-player.'))
                            : ListView.builder(
                                key: ValueKey(_generation),
                                itemCount: shown.length,
                                itemBuilder: (context, i) => TvListItem(
                                  autofocus: i == 0,
                                  icon: Icons.live_tv,
                                  leading: _Logo(shown[i].logo),
                                  title: shown[i].name,
                                  subtitle: shown[i].groups.join(', '),
                                  onSelect: () => _play(shown, i),
                                ),
                              ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _groupIcon(String group) => switch (group) {
        'News' => Icons.newspaper,
        'Sports' => Icons.sports_soccer,
        'Movies' || 'Series' || 'Classic' => Icons.movie,
        'Kids' || 'Animation' || 'Family' => Icons.child_care,
        'Music' => Icons.music_note,
        'Documentary' || 'Education' || 'Science' => Icons.school,
        'Business' => Icons.trending_up,
        'Comedy' || 'Entertainment' => Icons.theater_comedy,
        'Cooking' => Icons.restaurant,
        'Travel' || 'Outdoor' => Icons.landscape,
        'Weather' => Icons.cloud,
        _ => Icons.label_outline,
      };
}

/// Channel logo, or a TV icon when there is none or it can't be fetched.
class _Logo extends StatelessWidget {
  const _Logo(this.url);

  final String? url;

  static const _icon = Icon(Icons.live_tv, size: 36);

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    return SizedBox(
      width: 64,
      height: 40,
      child: url == null || url.isEmpty
          ? _icon
          : Image.network(url, fit: BoxFit.contain, cacheWidth: 128, errorBuilder: (_, _, _) => _icon),
    );
  }
}
