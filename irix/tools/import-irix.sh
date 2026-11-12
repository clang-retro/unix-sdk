#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 clang-retro contributors
#
# Make a sysroot for programs that link dynamically against IRIX's own
# libraries, from the files of an IRIX system that you have the right to
# use: a copy of an installed system's / (from tar or NFS), or the
# installed files of the IRIS Development Option.
#
#   irix/tools/import-irix.sh IRIX_ROOT OUT
#
# IRIX_ROOT is the root of the IRIX files (it has usr/include and
# usr/lib32). OUT gets usr/include and, for each ABI found, the C
# runtime objects, the shared and static libraries and rld from usr/lib
# (o32), usr/lib32 (n32) and usr/lib64 (64), in the same places. Then:
#
#   clang --target=mips64-sgi-irix6.5 -mabi=n32 --sysroot=OUT hello.c
#
# Nothing from IRIX is part of this SDK, and OUT must not be redistributed:
# the files in it are SGI's. Programs linked against them load IRIX's
# libraries at run time and carry none of their code.
set -e
root=${1:?usage: import-irix.sh IRIX_ROOT OUT}
out=${2:?usage: import-irix.sh IRIX_ROOT OUT}
[ -d "$root/usr/include" ] ||
  { echo "$root/usr/include not found: is $root an IRIX root?" >&2; exit 1; }
[ -f "$root/usr/include/sgidefs.h" ] ||
  echo "warning: no usr/include/sgidefs.h; these may not be IRIX headers" >&2
mkdir -p "$out/usr"

# Headers, as they are (symbolic links kept).
rm -rf "$out/usr/include"
cp -R -P "$root/usr/include" "$out/usr/include"

found=
for lib in lib lib32 lib64; do
  src=$root/usr/$lib
  [ -d "$src" ] || continue
  dst=$out/usr/$lib
  mkdir -p "$dst"
  n=0
  # The C runtime objects, libraries and the run-time linker. Libraries in
  # subdirectories (mips3/, mips4/, the old ABI's internal/) are left out:
  # the linker uses the plain ones.
  for f in "$src"/crt1.o "$src"/crtn.o "$src"/mcrt1.o "$src"/rld \
           "$src"/*.so "$src"/*.so.* "$src"/*.a; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    cp -P "$f" "$dst/"
    n=$((n + 1))
  done
  [ $n -eq 0 ] && continue
  case $lib in lib) abi=o32 ;; lib32) abi=n32 ;; lib64) abi=64 ;; esac
  echo "usr/$lib ($abi): $n files"
  found="$found $abi"
done
[ -n "$found" ] || { echo "no libraries found in $root/usr/lib*" >&2; exit 1; }
echo "IRIX sysroot written to $out (ABIs:$found)"
