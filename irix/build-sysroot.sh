#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 clang-retro contributors
#
# Build the SGI IRIX sysroot for static programs: picolibc with its IRIX
# layer and the compiler-rt builtins, for each of IRIX's three ABIs.
#
#   BIN=... LLVM_SRC=... PICOLIBC_SRC=... irix/build-sysroot.sh OUT
#
#   BIN           directory with clang, llvm-ar and the other LLVM tools
#                 (clang-retro/llvm, with the MIPS back end)
#   LLVM_SRC      clang-retro/llvm checkout (compiler-rt)
#   PICOLIBC_SRC  clang-retro/picolibc checkout
#   WORK          build directory (default: ./build-irix)
#   ABIS          the ABIs to build (default: o32 n32 n64)
#
# OUT gets the layout of an IRIX system, which the driver looks for in
# <bin>/../mips-sgi-irix or --sysroot:
#
#   usr/include/                 picolibc's headers (the same for every ABI)
#   usr/lib/    crt1.o libc.a libm.a libclang_rt.builtins.a   o32 (MIPS II)
#   usr/lib32/  the same                                      n32 (MIPS III)
#   usr/lib64/  the same                                      64  (MIPS III)
#
# Everything in it can be redistributed. Nothing from IRIX is used.
set -e
out=${1:?usage: build-sysroot.sh OUT}
: "${BIN:?set BIN}" "${LLVM_SRC:?set LLVM_SRC}" "${PICOLIBC_SRC:?set PICOLIBC_SRC}"
WORK=${WORK:-$PWD/build-irix}
ABIS=${ABIS:-o32 n32 n64}
mkdir -p "$out/usr/include" "$WORK"
out=$(cd "$out" && pwd) WORK=$(cd "$WORK" && pwd)
PATH=$BIN:$PATH
export PATH

"$BIN/clang" --target=mips-sgi-irix -print-targets | grep -qw mips ||
  { echo "$BIN/clang has no MIPS back end" >&2; exit 1; }

for abi in $ABIS; do
  case $abi in
    o32) triple=mips-sgi-irix flags="-mabi=32 -march=mips2" lib=lib ;;
    n32) triple=mips64-sgi-irix flags="-mabi=n32 -march=mips3" lib=lib32 ;;
    n64) triple=mips64-sgi-irix flags="-mabi=64 -march=mips3" lib=lib64 ;;
    *) echo "unknown ABI $abi" >&2; exit 1 ;;
  esac
  echo "== $abi ($triple $flags)"
  mkdir -p "$out/usr/$lib"

  # picolibc, with its malloc on top of the IRIX layer's sbrk.
  pb=$WORK/picolibc-$abi pi=$WORK/picolibc-install-$abi
  rm -rf "$pb" "$pi"
  meson setup "$pb" "$PICOLIBC_SRC" \
    --cross-file "$PICOLIBC_SRC/scripts/cross-clang-mips-sgi-irix-$abi.txt" \
    -Dos-irix=true -Dmultilib=false -Dpicocrt=false \
    -Dsemihost=false -Dtests=false -Dposix-console=true -Dsingle-thread=true \
    -Dthread-local-storage=false -Dspecsdir=none \
    --prefix="$pi" >"$WORK/picolibc-$abi.log" 2>&1 ||
    { tail -20 "$WORK/picolibc-$abi.log"; exit 1; }
  ninja -C "$pb" install >>"$WORK/picolibc-$abi.log" 2>&1 ||
    { grep -E 'error|FAILED' "$WORK/picolibc-$abi.log" | head -20; exit 1; }
  cp -R "$pi/include/." "$out/usr/include/"
  for f in crt1.o libc.a libm.a; do
    cp "$pi/lib/$f" "$out/usr/$lib/"
  done

  # compiler-rt builtins: 64-bit division for o32, 128-bit arithmetic and
  # long double (IEEE quad) for n32 and 64. PIC, like everything on IRIX.
  bb=$WORK/builtins-$abi
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
    -DCOMPILER_RT_OS_DIR=irix-$abi -DLLVM_CMAKE_DIR="$BIN/../lib/cmake/llvm" \
    >"$WORK/builtins-$abi.log" 2>&1 ||
    { tail -20 "$WORK/builtins-$abi.log"; exit 1; }
  ninja -C "$bb" >>"$WORK/builtins-$abi.log" 2>&1 ||
    { grep -E 'error|FAILED' "$WORK/builtins-$abi.log" | head -20; exit 1; }
  cp "$bb"/lib/irix-$abi/libclang_rt.builtins-*.a "$out/usr/$lib/libclang_rt.builtins.a"
done
echo "sysroot written to $out"
