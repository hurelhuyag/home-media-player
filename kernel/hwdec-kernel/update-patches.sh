#!/bin/bash
# Regenerates userpatches/ from LibreELEC's Amlogic kernel patches:
# applies Armbian's meson64 patches and then the LibreELEC ones to a plain
# kernel tree, one commit each, and exports them with git format-patch.
#
#   update-patches.sh LINUX_GIT_TREE ARMBIAN_BUILD LIBREELEC_TV [KERNEL_MAJOR_MINOR]
#
# LINUX_GIT_TREE: a git repo whose HEAD is the plain kernel release (e.g. the
# v7.3 tarball committed once); it is reset to that commit.
set -euo pipefail

LINUX=$(cd "$1" && pwd)
ARMBIAN=$(cd "$2" && pwd)
LIBREELEC=$(cd "$3" && pwd)
KVER=${4:-7.3}
HERE=$(cd "$(dirname "$0")" && pwd)
A=$ARMBIAN/patch/kernel/archive/meson64-$KVER
LE=$LIBREELEC/projects/Amlogic/patches/linux
OUT=$HERE/userpatches/kernel/archive/meson64-$KVER
# See README.md for what each range is
RANGES="116-129 140-143 147-153 155-157"
git_() { git -C "$LINUX" -c user.name=hmp -c user.email=hmp@localhost "$@"; }

cd "$LINUX"
git tag -f hmp-base "$(git rev-list --max-parents=0 HEAD)" >/dev/null
git_ reset -q --hard hmp-base
git_ clean -q -fdx

for p in $(ls "$A"/*.patch | sort); do
    # the staging decoder is replaced by LibreELEC's amvdec driver (0117+)
    grep -q "drivers/staging/media/meson/vdec" "$p" && continue
    git_ apply --index --whitespace=nowarn "$p" || { echo "Armbian patch fails: $(basename "$p")" >&2; exit 1; }
done
git_ commit -q -m "Armbian meson64-$KVER"
BASE=$(git rev-parse HEAD)

rm -rf "$OUT"
mkdir -p "$OUT"
for r in $RANGES; do
    for n in $(seq "${r%-*}" "${r#*-}"); do
        p=$(ls "$LE"/amlogic-$(printf %04d "$n")-*.patch)
        opts=(--exclude=MAINTAINERS)
        # board device trees: only the shared G12/SM1 files and the ODROID ones
        case $n in 155|157) opts+=(--include='*/meson-g12-common.dtsi' --include='*/meson-sm1.dtsi'
                                    --include='*/meson-sm1-odroid.dtsi' --include='Documentation/*') ;; esac
        # git am keeps the patch's author, date and message
        if ! git_ am -q --committer-date-is-author-date --whitespace=nowarn "${opts[@]}" "$p" 2>/dev/null; then
            git_ am --abort
            git_ am -q --committer-date-is-author-date --whitespace=nowarn -C1 "${opts[@]}" "$p" ||
                { echo "LibreELEC patch fails: $(basename "$p")" >&2; git_ am --abort; exit 1; }
            echo "applied with less context: $(basename "$p")"
        fi
        git_ format-patch -1 --stdout --no-signature --zero-commit HEAD \
            > "$OUT/$(basename "$p" | sed 's/^amlogic-/zz-libreelec-/')"
    done
done

# Empty same-named files disable Armbian's patches to the removed staging driver
for p in $(grep -l "drivers/staging/media/meson/vdec" "$A"/*.patch); do
    : > "$OUT/$(basename "$p")"
done
echo "$(git rev-list --count "$BASE"..HEAD) LibreELEC patches in $OUT"
