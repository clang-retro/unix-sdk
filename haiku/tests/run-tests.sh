#!/bin/sh
# run-tests.sh - builds the examples against a Haiku sysroot and, with
# HAIKU_IMAGE, runs them in Haiku in QEMU (tools/haiku-vm.py).
#
#   SYSROOT=... [TARGET=x86_64-unknown-haiku] [HAIKU_IMAGE=...] \
#     haiku/tests/run-tests.sh [OUT]
#
# CXX is the compiler (default: clang++); it links with ld.lld.
#
# Part of clang-retro unix-sdk.
# SPDX-License-Identifier: AGPL-3.0-only
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
SYSROOT=${SYSROOT:?set SYSROOT to the Haiku sysroot}
TARGET=${TARGET:-x86_64-unknown-haiku}
CXX=${CXX:-clang++}
HAIKU_IMAGE=${HAIKU_IMAGE:-}
out=${1:-build-haiku-tests}
mkdir -p "$out"
"$CXX" --target="$TARGET" --sysroot="$SYSROOT" -fuse-ld=lld -O2 \
  "$here/examples/hello.cpp" -lbe -o "$out/hello"
echo "built  $out/hello"
[ -n "$HAIKU_IMAGE" ] || exit 0
printf 'cd /tmp && curl -sf -o hello http://10.0.2.2:8765/files/hello && chmod +x hello && ./hello\n' > "$out/hello.sh"
python3 "$here/tools/haiku-vm.py" run "$HAIKU_IMAGE" "$out/hello.sh" --files "$out" | tee "$out/hello.log"
grep -q "Hello from clang on Haiku" "$out/hello.log"
echo "PASS   hello"
