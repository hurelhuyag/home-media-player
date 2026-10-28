# Internet TV playlists

The launcher's **Internet TV** downloads its channel lists (M3U) each time it
opens; by default `mongolia.m3u` and `english.m3u` from this repository on
GitHub, so a dead or
moved channel is fixed with a commit, without touching the box. The last good
copy is kept in `~kiosk/.local/share/home-media-player/iptv/` for when the
network or GitHub is down.

`mongolia.m3u` is iptv-org's [countries/mn.m3u](https://iptv-org.github.io/iptv/countries/mn.m3u)
(public domain) with Unix line endings, cleaner names (no `(1080p)`,
`(Mongolia)`) and without channels that don't play here. The streams need the
browser User-Agent given in each entry; the player sends it. Most are DASH
(`.mpd`), which needs FFmpeg with libxml2 (`hmp-hwdec-libs` and Debian's
FFmpeg both have it). All are H.264, so they decode in hardware.

```sh
iptv/check.sh iptv/mongolia.m3u     # test every stream (on the box: needs ffprobe)
```

`english.m3u` is iptv-org's [languages/eng.m3u](https://iptv-org.github.io/iptv/languages/eng.m3u)
(3,015 entries) without channels marked geo-blocked or not 24/7 and the
Religious, Legislative and Shop categories, keeping the 942 that played from
the box at 480p or better, one feed per channel. Free streams come and go, so
rerun the check now and then and drop what fails.

In the app the menu on the left picks the list and a category (iptv-org's
`group-title`); channel up/down in the player stays within that category.

It tests the streams one at a time: the skygo.mn CDN refuses bursts of
parallel requests. Other lists, from iptv-org (by country, language,
category) or anywhere else, go in `HMP_IPTV_PLAYLISTS` in
`/etc/default/home-media-player`, e.g.

```sh
HMP_IPTV_PLAYLISTS="Mongolia=https://raw.githubusercontent.com/hurelhuyag/home-media-player/main/iptv/mongolia.m3u;News=https://iptv-org.github.io/iptv/categories/news.m3u"
```

A local file works too (`Name=/srv/tv.m3u`). Supported: `#EXTINF` with
`tvg-logo`, `group-title`, `http-user-agent`, `http-referrer`, and
`#EXTVLCOPT:http-user-agent=` / `http-referrer=`.
