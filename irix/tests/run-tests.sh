#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 clang-retro contributors
#
# Build the examples for IRIX's three ABIs and run them in qemu-irix (user
# mode emulation of IRIX programs; see tools/build-qemu-irix.sh).
#
#   CC=.../bin/clang SYSROOT=... QEMU_DIR=... irix/tests/run-tests.sh [OUT]
#
# CC is clang from clang-retro/llvm, with the sysroot made by
# build-sysroot.sh in <bin>/../mips-sgi-irix or given by SYSROOT. QEMU_DIR
# has qemu-irix, qemu-irixn32 and qemu-irix64 (default: from PATH). OUT
# (default ./tests-out) gets the programs and their output.
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
CC=${CC:-clang}
out=${1:-$PWD/tests-out}
mkdir -p "$out"
out=$(cd "$out" && pwd)
q=${QEMU_DIR:+$QEMU_DIR/}
fail=0

ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# name abi expected-status expected-text program args...
check() {
  name=$1 abi=$2 status=$3 text=$4 prog=$5
  shift 5
  case $abi in o32) emu=qemu-irix ;; n32) emu=qemu-irixn32 ;; n64) emu=qemu-irix64 ;; esac
  set +e
  (cd "$out" && ABITEST=yes "$q$emu" "$prog" "$@") >"$out/$name.log" 2>&1
  got=$?
  set -e
  if [ $got -ne "$status" ]; then
    bad "$name (exit status $got, not $status)"; tail -5 "$out/$name.log"
  elif grep -q FAIL "$out/$name.log"; then
    bad "$name"; grep FAIL "$out/$name.log"
  elif [ -n "$text" ] && ! grep -qF "$text" "$out/$name.log"; then
    bad "$name (no \"$text\")"; tail -5 "$out/$name.log"
  else
    ok "$name"
  fi
}

for abi in o32 n32 n64; do
  case $abi in
    o32) flags="--target=mips-sgi-irix6.5" ;;
    n32) flags="--target=mips64-sgi-irix6.5 -mabi=n32" ;;
    n64) flags="--target=mips64-sgi-irix6.5 -mabi=64" ;;
  esac
  flags="$flags ${SYSROOT:+--sysroot=$SYSROOT} -static -Wall -Werror"
  variants="-O0 -O2 -Os"
  [ $abi = o32 ] || variants="$variants -O2:-march=mips4"
  for v in $variants; do
    n=$abi$(echo "$v" | tr -d ':=' | sed 's/-march/-/')
    if $CC $flags $(echo "$v" | tr ':' ' ') "$here/examples/abitest.c" -o "$out/abitest$n"; then
      ok "build abitest$n"
      check "abitest$n" $abi 0 "abitest: destructor ran" "./abitest$n" one "two words"
    else
      bad "build abitest$n"
    fi
  done
  if $CC $flags -O2 "$here/examples/hello.c" -o "$out/hello-$abi"; then
    ok "build hello-$abi"
    check "hello-$abi" $abi 0 "Hello, world from ./hello-$abi! 42 123456789 3.25" "./hello-$abi"
  else
    bad "build hello-$abi"
  fi
  # The exit status gets back to the caller.
  printf 'int main(void) { return 3; }\n' >"$out/exit3.c"
  if $CC $flags -O2 "$out/exit3.c" -o "$out/exit3-$abi"; then
    check "exit3-$abi" $abi 3 "" "./exit3-$abi"
  else
    bad "build exit3-$abi"
  fi
done
exit $fail
