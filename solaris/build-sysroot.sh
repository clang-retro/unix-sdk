#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 clang-retro contributors
#
# Build the Solaris sysroot for static programs on 32-bit SPARC: picolibc
# with its Solaris layer and the compiler-rt builtins, for SPARC V8.
#
#   BIN=... LLVM_SRC=... PICOLIBC_SRC=... solaris/build-sysroot.sh OUT
#
#   BIN           directory with clang, llvm-ar and the other LLVM tools
#                 (clang-retro/llvm, with the SPARC back end)
#   LLVM_SRC      clang-retro/llvm checkout (compiler-rt)
#   PICOLIBC_SRC  clang-retro/picolibc checkout
#   WORK          build directory (default: ./build-solaris)
#
# OUT gets the layout of a Solaris system, which the driver looks for in
# <bin>/../sparc-sun-solaris or --sysroot:
#
#   usr/include/  picolibc's headers
#   usr/lib/      crt1.o libc.a libm.a libclang_rt.builtins.a
#
# Everything in it can be redistributed. Nothing from Solaris is used.
set -e
out=${1:?usage: build-sysroot.sh OUT}
: "${BIN:?set BIN}" "${LLVM_SRC:?set LLVM_SRC}" "${PICOLIBC_SRC:?set PICOLIBC_SRC}"
WORK=${WORK:-$PWD/build-solaris}
mkdir -p "$out/usr/include" "$out/usr/lib" "$WORK"
out=$(cd "$out" && pwd) WORK=$(cd "$WORK" && pwd)
PATH=$BIN:$PATH
export PATH
triple=sparc-sun-solaris flags=-mcpu=v8

"$BIN/clang" --target=$triple -print-targets | grep -qw sparc ||
  { echo "$BIN/clang has no SPARC back end" >&2; exit 1; }

# picolibc, with its malloc on top of the Solaris layer's sbrk.
pb=$WORK/picolibc pi=$WORK/picolibc-install
rm -rf "$pb" "$pi"
meson setup "$pb" "$PICOLIBC_SRC" \
  --cross-file "$PICOLIBC_SRC/scripts/cross-clang-sparc-sun-solaris.txt" \
  -Dos-solaris=true -Dmultilib=false -Dpicocrt=false \
  -Dsemihost=false -Dtests=false -Dposix-console=true -Dsingle-thread=true \
  -Dthread-local-storage=false -Dspecsdir=none \
  --prefix="$pi" >"$WORK/picolibc.log" 2>&1 ||
  { tail -20 "$WORK/picolibc.log"; exit 1; }
ninja -C "$pb" install >>"$WORK/picolibc.log" 2>&1 ||
  { grep -E 'error|FAILED' "$WORK/picolibc.log" | head -20; exit 1; }
cp -R "$pi/include/." "$out/usr/include/"
for f in crt1.o libc.a libm.a; do
  cp "$pi/lib/$f" "$out/usr/lib/"
done

# compiler-rt builtins: 64-bit division and long double (IEEE quad, which
# picolibc's _Q_ routines call).
bb=$WORK/builtins
rm -rf "$bb"
cmake -G Ninja -S "$LLVM_SRC/compiler-rt/lib/builtins" -B "$bb" \
  -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$BIN/clang" -DCMAKE_ASM_COMPILER="$BIN/clang" \
  -DCMAKE_CXX_COMPILER="$BIN/clang++" \
  -DCMAKE_C_COMPILER_TARGET=$triple \
  -DCMAKE_CXX_COMPILER_TARGET=$triple \
  -DCMAKE_ASM_COMPILER_TARGET=$triple \
  -DCMAKE_C_FLAGS="$flags" -DCMAKE_ASM_FLAGS="$flags" \
  -DCMAKE_AR="$BIN/llvm-ar" -DCMAKE_RANLIB="$BIN/llvm-ranlib" \
  -DCMAKE_NM="$BIN/llvm-nm" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DCOMPILER_RT_BAREMETAL_BUILD=ON \
  -DCOMPILER_RT_OS_DIR=solaris -DLLVM_CMAKE_DIR="$BIN/../lib/cmake/llvm" \
  >"$WORK/builtins.log" 2>&1 ||
  { tail -20 "$WORK/builtins.log"; exit 1; }
ninja -C "$bb" >>"$WORK/builtins.log" 2>&1 ||
  { grep -E 'error|FAILED' "$WORK/builtins.log" | head -20; exit 1; }
cp "$bb"/lib/solaris/libclang_rt.builtins-*.a "$out/usr/lib/libclang_rt.builtins.a"
echo "sysroot written to $out"
