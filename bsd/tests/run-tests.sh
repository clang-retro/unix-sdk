#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 clang-retro contributors
#
# Build the examples for FreeBSD on 32-bit x86 and run them in bsdrun
# (bsd/tools/bsdrun.c, which runs static i386 FreeBSD programs on Linux).
#
#   CC=.../bin/clang SYSROOT=... BSDRUN=... bsd/tests/run-tests.sh [OUT]
#
# CC is clang from clang-retro/llvm and SYSROOT the sysroot made by
# build-sysroot.sh. BSDRUN is the bsdrun program (default: built from
# bsd/tools/bsdrun.c with the host's cc into OUT). OUT (default
# ./tests-out) gets the programs and their output.
#
# The tests build for the i486, and a program for clang's default CPU (the
# Pentium 4) too.
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
CC=${CC:-clang}
: "${SYSROOT:?set SYSROOT}"
out=${1:-$PWD/tests-out}
mkdir -p "$out"
out=$(cd "$out" && pwd)
if [ -z "${BSDRUN:-}" ]; then
  BSDRUN=$out/bsdrun
  ${HOSTCC:-cc} -O2 -Wall -o "$BSDRUN" "$here/tools/bsdrun.c"
fi
fail=0

ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# name expected-status expected-text program args...
check() {
  name=$1 status=$2 text=$3 prog=$4
  shift 4
  set +e
  (cd "$out" && ABITEST=yes "$BSDRUN" "$prog" "$@") >"$out/$name.log" 2>&1
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

flags="--target=i386-unknown-freebsd --sysroot=$SYSROOT -static -Wall -Werror"
for o in -O0 -O2 -Os; do
  n=freebsd$o
  if $CC $flags -march=i486 $o "$here/examples/abitest.c" -o "$out/abitest$n"; then
    ok "build abitest$n"
    check "abitest$n" 0 "abitest: destructor ran" "./abitest$n" one "two words"
  else
    bad "build abitest$n"
  fi
done
if $CC $flags -march=i486 -O2 "$here/examples/hello.c" -o "$out/hello-freebsd"; then
  ok "build hello-freebsd"
  check "hello-freebsd" 0 "Hello, world from ./hello-freebsd! 42 123456789 3.25" "./hello-freebsd"
else
  bad "build hello-freebsd"
fi
# The exit status gets back to the caller.
printf 'int main(void) { return 3; }\n' >"$out/exit3.c"
if $CC $flags -march=i486 -O2 "$out/exit3.c" -o "$out/exit3-freebsd"; then
  check "exit3-freebsd" 3 "" "./exit3-freebsd"
else
  bad "build exit3-freebsd"
fi
# clang's default CPU (the Pentium 4) links with the i486 library too.
if $CC $flags -O2 "$here/examples/abitest.c" -o "$out/abitest-p4"; then
  ok "build abitest-p4"
  check "abitest-p4" 0 "abitest: destructor ran" "./abitest-p4" one "two words"
else
  bad "build abitest-p4"
fi
# The programs are branded FreeBSD (ELF OS/ABI 9), as its kernel wants.
if od -An -tx1 -j7 -N1 "$out/hello-freebsd" | grep -q '09'; then
  ok "hello-freebsd is branded FreeBSD"
else
  bad "hello-freebsd is not branded FreeBSD"
fi
exit $fail
