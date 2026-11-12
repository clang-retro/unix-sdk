#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 clang-retro contributors
#
# Build qemu-irix (https://github.com/n64decomp/qemu-irix, GPL), QEMU's
# user mode emulation extended to run IRIX programs on Linux: qemu-irix
# (o32), qemu-irixn32 and qemu-irix64, and qemu-solaris (SPARC).
#
#   irix/tools/build-qemu-irix.sh OUT
#
#   WORK          build directory (default: ./build-qemu-irix)
#   QEMU_IRIX_SHA the commit to build (default: the one the tests use)
#   STATIC=1      link the programs statically
#
# Needs a C compiler, make, python3, pkg-config, and glib, pixman and zlib
# with their headers (Debian and Ubuntu: build-essential python3
# pkg-config libglib2.0-dev libpixman-1-dev zlib1g-dev).
set -e
out=${1:?usage: build-qemu-irix.sh OUT}
WORK=${WORK:-$PWD/build-qemu-irix}
QEMU_IRIX_SHA=${QEMU_IRIX_SHA:-6d7d1fde2f68adf795e51a19ad2572a48931884e}
mkdir -p "$out" "$WORK"
out=$(cd "$out" && pwd) WORK=$(cd "$WORK" && pwd)

if [ ! -d "$WORK/src/.git" ]; then
  git init -q "$WORK/src"
  git -C "$WORK/src" remote add origin https://github.com/n64decomp/qemu-irix
fi
git -C "$WORK/src" fetch -q --depth 1 origin "$QEMU_IRIX_SHA"
git -C "$WORK/src" checkout -q FETCH_HEAD

mkdir -p "$WORK/build"
cd "$WORK/build"
# The submodules (dtc, capstone) are only for system emulation and the
# disassembler, which these targets don't need.
"$WORK/src/configure" --python=python3 \
  --target-list=irix-linux-user,irixn32-linux-user,irix64-linux-user,solaris-linux-user \
  --disable-werror --disable-capstone --disable-docs --disable-tools \
  --disable-git-update --disable-fdt ${STATIC:+--static} >configure.log 2>&1 ||
  { tail -20 configure.log; exit 1; }
make -j"$(nproc)" GIT_SUBMODULES= >make.log 2>&1 ||
  { grep -E 'error' make.log | head -20; exit 1; }
for t in irix irixn32 irix64 solaris; do
  install -m 755 "$t-linux-user/qemu-$t" "$out/qemu-$t"
done
echo "qemu-irix written to $out"
