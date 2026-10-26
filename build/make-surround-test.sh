#!/bin/bash
# Makes 5.1 speaker-identification test files: each speaker's name is spoken
# on its own channel only (front left, center, front right, rear right,
# rear left), then a 50 Hz tone on the subwoofer. Two rounds after 3 s of
# silence, so an AV receiver has time to lock onto the format.
#
#   build/make-surround-test.sh [OUTDIR]    (needs ffmpeg built with libflite)
#
# Copy the results to the box and play them from the Media screen.
set -euo pipefail

OUT=${1:-$(cd "$(dirname "$0")/.." && pwd)/dist/surround-test}
mkdir -p "$OUT"
cd "$OUT"

speak() { echo "flite=text='$1':voice=slt"; }

# One channel: the clip at slot START (seconds), again 18 s later, padded to 39 s
channel() { # input-index start
    echo "[$1]aresample=48000,asplit[a$1][b$1];[a$1]adelay=$(($2 * 1000))[x$1];[b$1]adelay=$((($2 + 18) * 1000))[y$1];[x$1][y$1]amix=normalize=0,apad,atrim=end=39[c$1];"
}

ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "$(speak 'front left')" \
    -f lavfi -i "$(speak 'front right')" \
    -f lavfi -i "$(speak 'center')" \
    -f lavfi -i "sine=frequency=50:duration=2" \
    -f lavfi -i "$(speak 'rear left')" \
    -f lavfi -i "$(speak 'rear right')" \
    -filter_complex "$(channel 0 3)$(channel 1 9)$(channel 2 6)$(channel 3 18)$(channel 4 15)$(channel 5 12)
        [c0][c1][c2][c3][c4][c5]join=inputs=6:channel_layout=5.1:map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-BL|5.0-BR[out]" \
    -map "[out]" -t 39 -c:a flac "5.1-test-pcm.flac"

ffmpeg -hide_banner -loglevel error -y -i 5.1-test-pcm.flac -c:a ac3 -b:a 448k 5.1-test-dolby-digital.mka
ffmpeg -hide_banner -loglevel error -y -i 5.1-test-pcm.flac -c:a eac3 -b:a 640k 5.1-test-dolby-digital-plus.mka
ffmpeg -hide_banner -loglevel error -y -i 5.1-test-pcm.flac -strict -2 -c:a dca -b:a 1509k 5.1-test-dts.mka

for f in *.flac *.mka; do
    printf '%-34s %s\n' "$f" "$(ffprobe -v error -show_entries stream=codec_name,channel_layout -of csv=p=0 "$f")"
done
