#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 clang-retro contributors
#
# Build the FreeBSD or NetBSD sysroot for static programs on 32-bit x86:
# picolibc with its BSD layer and the compiler-rt builtins, for the i486.
#
#   BIN=... LLVM_SRC=... PICOLIBC_SRC=... bsd/build-sysroot.sh OUT
#
#   BSD           freebsd (default) or netbsd
#   BIN           directory with clang, llvm-ar and the other LLVM tools
#                 (clang-retro/llvm, with the X86 back end)
#   LLVM_SRC      clang-retro/llvm checkout (compiler-rt)
#   PICOLIBC_SRC  clang-retro/picolibc checkout
#   WORK          build directory (default: ./build-$BSD)
#
# OUT gets the layout clang's FreeBSD or NetBSD driver links against (pass
# it with --sysroot):
#
#   usr/include/  picolibc's headers
#   usr/lib/      FreeBSD: crt1.o libc.a libm.a; libgcc.a, which is
#                 compiler-rt's builtins (as on FreeBSD itself), and empty
#                 crti.o, crtn.o, crtbeginT.o, crtend.o and libgcc_eh.a,
#                 which the driver asks for.
#                 NetBSD: crt0.o (the start code), libc.a with the builtins
#                 in it (as on NetBSD itself), libm.a, and empty crti.o,
#                 crtn.o, crtbegin.o and crtend.o.
#
# Everything in it can be redistributed. Nothing from either BSD is used.
set -e
out=${1:?usage: build-sysroot.sh OUT}
: "${BIN:?set BIN}" "${LLVM_SRC:?set LLVM_SRC}" "${PICOLIBC_SRC:?set PICOLIBC_SRC}"
BSD=${BSD:-freebsd}
case $BSD in
freebsd|netbsd) ;;
*) echo "BSD must be freebsd or netbsd" >&2; exit 1 ;;
esac
WORK=${WORK:-$PWD/build-$BSD}
mkdir -p "$out/usr/include" "$out/usr/lib" "$WORK"
out=$(cd "$out" && pwd) WORK=$(cd "$WORK" && pwd)
PATH=$BIN:$PATH
export PATH
triple=i386-unknown-$BSD flags=-march=i486

"$BIN/clang" --target=$triple -print-targets | grep -qw x86 ||
  { echo "$BIN/clang has no x86 back end" >&2; exit 1; }

# picolibc, with its malloc on top of the BSD layer's sbrk.
pb=$WORK/picolibc pi=$WORK/picolibc-install
rm -rf "$pb" "$pi"
meson setup "$pb" "$PICOLIBC_SRC" \
  --cross-file "$PICOLIBC_SRC/scripts/cross-clang-$triple.txt" \
  -Dos-bsd=true -Dmultilib=false -Dpicocrt=false \
  -Dsemihost=false -Dtests=false -Dposix-console=true -Dsingle-thread=true \
  -Dthread-local-storage=false -Dspecsdir=none \
  --prefix="$pi" >"$WORK/picolibc.log" 2>&1 ||
  { tail -20 "$WORK/picolibc.log"; exit 1; }
ninja -C "$pb" install >>"$WORK/picolibc.log" 2>&1 ||
  { grep -E 'error|FAILED' "$WORK/picolibc.log" | head -20; exit 1; }
cp -R "$pi/include/." "$out/usr/include/"
for f in libc.a libm.a; do
  cp "$pi/lib/$f" "$out/usr/lib/"
done
if [ "$BSD" = netbsd ]; then
  cp "$pi/lib/crt1.o" "$out/usr/lib/crt0.o"
else
  cp "$pi/lib/crt1.o" "$out/usr/lib/crt1.o"
fi

# compiler-rt builtins: 64-bit division and the like. They are built with
# the sysroot, so the driver finds picolibc's headers, not the host's.
bb=$WORK/builtins
rm -rf "$bb"
cmake -G Ninja -S "$LLVM_SRC/compiler-rt/lib/builtins" -B "$bb" \
  -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$BIN/clang" -DCMAKE_ASM_COMPILER="$BIN/clang" \
  -DCMAKE_CXX_COMPILER="$BIN/clang++" \
  -DCMAKE_C_COMPILER_TARGET=$triple \
  -DCMAKE_CXX_COMPILER_TARGET=$triple \
  -DCMAKE_ASM_COMPILER_TARGET=$triple \
  -DCMAKE_C_FLAGS="$flags --sysroot=$out" -DCMAKE_ASM_FLAGS="$flags --sysroot=$out" \
  -DCMAKE_AR="$BIN/llvm-ar" -DCMAKE_RANLIB="$BIN/llvm-ranlib" \
  -DCMAKE_NM="$BIN/llvm-nm" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DCOMPILER_RT_BAREMETAL_BUILD=ON \
  -DCOMPILER_RT_OS_DIR=$BSD -DLLVM_CMAKE_DIR="$BIN/../lib/cmake/llvm" \
  >"$WORK/builtins.log" 2>&1 ||
  { tail -20 "$WORK/builtins.log"; exit 1; }
ninja -C "$bb" >>"$WORK/builtins.log" 2>&1 ||
  { grep -E 'error|FAILED' "$WORK/builtins.log" | head -20; exit 1; }
lib=$(ls "$bb"/lib/$BSD/libclang_rt.builtins-*.a)
# compiler-rt's x86 assembly for these conversions uses SSE2, which an
# i486 or Pentium has not got. Put the C versions in their place.
for f in floatdidf floatdisf floatdixf floatundidf floatundisf floatundixf; do
  "$BIN/clang" --target=$triple $flags --sysroot="$out" -O2 -c \
    "$LLVM_SRC/compiler-rt/lib/builtins/$f.c" -o "$bb/$f.o"
  "$BIN/llvm-ar" d "$lib" $("$BIN/llvm-ar" t "$lib" | grep "^$f\.S\.")
  "$BIN/llvm-ar" r "$lib" "$bb/$f.o"
done
! "$BIN/llvm-objdump" -d "$lib" | grep -qw 'xmm[0-9]*' ||
  { echo "SSE instructions left in $lib" >&2; exit 1; }
if [ "$BSD" = netbsd ]; then
  # NetBSD's driver links no runtime library on x86: NetBSD's libc has the
  # builtins in it. So does this one.
  mkdir -p "$bb/objs"
  (cd "$bb/objs" && "$BIN/llvm-ar" x "$lib")
  "$BIN/llvm-ar" q "$out/usr/lib/libc.a" "$bb"/objs/*
  "$BIN/llvm-ranlib" "$out/usr/lib/libc.a"
  crts="crti crtn crtbegin crtend"
else
  cp "$lib" "$out/usr/lib/libgcc.a"
  rm -f "$out/usr/lib/libgcc_eh.a"
  "$BIN/llvm-ar" rc "$out/usr/lib/libgcc_eh.a"
  crts="crti crtn crtbeginT crtend"
fi

# What else the driver links: the C++ runtime's start and end files (and
# on FreeBSD libgcc_eh), which a static C program doesn't need. picolibc's
# start code runs the constructors itself.
for f in $crts; do
  : | "$BIN/clang" --target=$triple $flags -x c -c - -o "$out/usr/lib/$f.o"
done
echo "sysroot written to $out"
