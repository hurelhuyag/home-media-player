#!/bin/sh
# Tests every stream of an M3U playlist with ffprobe, one at a time (the
# Mongolian CDN rejects bursts of parallel requests), and prints the video
# codec and size or FAIL with the error:
#
#   iptv/check.sh iptv/mongolia.m3u
#
# Needs ffprobe built with libxml2 for DASH (.mpd), e.g. Debian's.
set -u
tr -d '\r' < "${1:?usage: check.sh PLAYLIST}" | awk '
    /^#EXTINF/ { name = $0; sub(/.*,/, "", name); ua = "" }
    /http-user-agent=/ { u = $0; sub(/.*http-user-agent=/, "", u); sub(/".*/, "", u); ua = u }
    /^[a-z]+:\/\// { print name "\t" ua "\t" $0 }
' | while IFS="$(printf '\t')" read -r name ua url; do
    out=$(timeout 30 ffprobe -v error ${ua:+-user_agent "$ua"} -select_streams v \
        -show_entries stream=codec_name,width,height -of csv=p=0 "$url" 2>&1 < /dev/null)
    video=$(printf '%s\n' "$out" | grep -E '^[a-z0-9]+,[0-9]+,[0-9]+' | sort -t, -k3 -n | tail -1)
    printf '%-40s %s\n' "$name" "${video:-FAIL $(printf '%s' "$out" | tail -1 | cut -c1-80)}"
    sleep 1
done
