#!/bin/sh
# fetch-image.sh - downloads the newest nightly anyboot image of Haiku and
# gives its path.
#
#   haiku/tools/fetch-image.sh [ARCH] [DIR]
#
# ARCH is x86_64 (default) or x86_gcc2h (the 32-bit hybrid release). DIR
# (default: .) keeps the images; an image that is already there is used
# again. The script writes the path of the .iso file on standard output.
# With LIST=1 it writes only the name of the newest image, so that a CI
# cache can use it as a key.
#
# Part of clang-retro unix-sdk.
# SPDX-License-Identifier: AGPL-3.0-only
set -eu
ARCH=${1:-x86_64}
DIR=${2:-.}
INDEX=https://download.haiku-os.org/nightly-images/$ARCH/
CDN=https://haiku-nightly.cdn.haiku-os.org/$ARCH
zip=$(curl -fsSL "$INDEX" | grep -o "haiku-master-hrev[0-9]*-$ARCH-anyboot\.zip" | sort -uV | tail -1)
[ -n "$zip" ] || { echo "fetch-image.sh: no image in $INDEX" >&2; exit 1; }
iso=${zip%.zip}.iso
if [ "${LIST:-}" = 1 ]; then echo "${zip%.zip}"; exit 0; fi
mkdir -p "$DIR"
if [ ! -s "$DIR/$iso" ]; then
  curl -fsSL -o "$DIR/$zip" "$CDN/$zip"
  python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); n = [m for m in z.namelist() if m.endswith(".iso")][0]; open(sys.argv[2], "wb").write(z.read(n))' "$DIR/$zip" "$DIR/$iso"
  rm -f "$DIR/$zip"
fi
echo "$DIR/$iso"
