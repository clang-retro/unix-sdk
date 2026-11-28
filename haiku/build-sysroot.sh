#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 clang-retro contributors
#
# Build a Haiku sysroot for clang from Haiku's own packages.
#
#   haiku/build-sysroot.sh OUT
#
#   ARCH      x86_64 (default) or x86 (32-bit, the gcc 15 side of the
#             x86_gcc2 hybrid release)
#   BRANCH    the package repositories' branch: master (default), or a
#             release such as r1beta5
#   WORK      directory for the downloaded packages (default:
#             ./build-haiku-$ARCH). The script uses the packages that are
#             already there again.
#
# The script downloads the system packages (haiku, haiku_devel) from the
# Haiku repository and the C++ library packages (gcc, gcc_syslibs,
# gcc_syslibs_devel) from the HaikuPorts repository. It extracts the
# headers and libraries with tools/hpkg.py into the layout that clang's
# Haiku driver uses (pass OUT with --sysroot):
#
#   boot/system/develop/headers/     the system's and libstdc++'s headers
#   boot/system/develop/lib/         start files and static libraries
#   boot/system/lib/                 the shared libraries
#   boot/system/develop/tools/lib/gcc/TRIPLE/VERSION/
#                                    crtbeginS.o, crtendS.o, libgcc.a
#
# For ARCH=x86 the files of the secondary architecture (lib/x86,
# develop/lib/x86, develop/headers/x86) go to the places of the primary
# one, so the driver finds them. The programs run on the x86_gcc2 hybrid
# release, which loads them with its gcc 15 libraries.
#
# It needs curl and Python 3 with the "zstandard" module.
set -e
out=${1:?usage: build-sysroot.sh OUT}
ARCH=${ARCH:-x86_64}
BRANCH=${BRANCH:-master}
here=$(cd "$(dirname "$0")" && pwd)
hpkg="python3 -I $here/tools/hpkg.py"
case $ARCH in
x86_64) REPO_ARCH=x86_64 TRIPLE=x86_64-unknown-haiku ;;
x86) REPO_ARCH=x86_gcc2 TRIPLE=i586-pc-haiku ;;
*) echo "ARCH must be x86_64 or x86" >&2; exit 1 ;;
esac
WORK=${WORK:-$PWD/build-haiku-$ARCH}
BASE=https://eu.hpkg.haiku-os.org
mkdir -p "$out" "$WORK"
out=$(cd "$out" && pwd) WORK=$(cd "$WORK" && pwd)
sys=$out/boot/system

# Downloads the repository index of one repository (haiku or haikuports)
# and gives the file names of the newest packages with the given names.
resolve() {  # repo name...
  repo=$1
  shift
  index=$WORK/$repo.repo
  [ -s "$index" ] || curl -fsSL -o "$index" "$BASE/$repo/$BRANCH/$REPO_ARCH/current/repo"
  $hpkg resolve "$index" "$@"
}

# Downloads one package of a repository, unless it is already there.
fetch() {  # repo file
  [ -s "$WORK/$2" ] || curl -fsSL -o "$WORK/$2" "$BASE/$1/$BRANCH/$REPO_ARCH/current/packages/$2"
  echo "$WORK/$2"
}

if [ "$ARCH" = x86_64 ]; then
  set -- $(resolve haiku haiku haiku_devel)
  haiku=$(fetch haiku "$1") devel=$(fetch haiku "$2")
  set -- $(resolve haikuports gcc gcc_syslibs gcc_syslibs_devel)
  gcc=$(fetch haikuports "$1") syslibs=$(fetch haikuports "$2") syslibs_devel=$(fetch haikuports "$3")
  $hpkg extract "$haiku" "$sys" lib
  $hpkg extract "$devel" "$sys" develop/headers develop/lib lib
  $hpkg extract "$syslibs" "$sys" lib
  $hpkg extract "$syslibs_devel" "$sys" develop
  $hpkg extract "$gcc" "$sys" develop/tools/lib/gcc
else
  set -- $(resolve haiku haiku_x86 haiku_x86_devel haiku_devel)
  haiku=$(fetch haiku "$1") devel=$(fetch haiku "$2") headers=$(fetch haiku "$3")
  set -- $(resolve haikuports gcc_x86 gcc_x86_syslibs gcc_x86_syslibs_devel)
  gcc=$(fetch haikuports "$1") syslibs=$(fetch haikuports "$2") syslibs_devel=$(fetch haikuports "$3")
  map="--map lib/x86=lib --map develop/lib/x86=develop/lib --map develop/headers/x86=develop/headers"
  $hpkg extract "$headers" "$sys" develop/headers
  $hpkg extract $map "$haiku" "$sys" lib/x86
  $hpkg extract $map "$devel" "$sys" develop/lib/x86 lib/x86
  $hpkg extract $map "$syslibs" "$sys" lib/x86
  $hpkg extract $map "$syslibs_devel" "$sys" develop
  $hpkg extract --map develop/tools/x86=develop/tools "$gcc" "$sys" develop/tools/x86/lib/gcc
fi
# Only the headers and the libraries: gcc's own programs and plugin
# headers, the debug files and the private headers are not needed.
for d in "$sys"/develop/tools/lib/gcc/*/*; do
  rm -rf "$d/plugin" "$d/install-tools" "$d"/cc1* "$d"/lto* "$d/collect2" "$d/g++-mapper-server"
done
rm -rf "$sys/lib/debug" "$sys/develop/headers/private"
echo "sysroot for $TRIPLE in $out"
