#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 clang-retro contributors
#
# Build the examples for Solaris on 32-bit SPARC and run them in
# qemu-solaris (user mode emulation of Solaris programs, built with
# qemu-irix; see irix/tools/build-qemu-irix.sh).
#
#   CC=.../bin/clang SYSROOT=... QEMU_DIR=... solaris/tests/run-tests.sh [OUT]
#
# CC is clang from clang-retro/llvm, with the sysroot made by
# build-sysroot.sh in <bin>/../sparc-sun-solaris or given by SYSROOT.
# QEMU_DIR has qemu-solaris (default: from PATH). OUT (default
# ./tests-out) gets the programs and their output.
#
# qemu-solaris runs SPARC V8 programs only, so the tests build with
# -mcpu=v8; programs for V9 CPUs (V8+, clang's default) are only linked.
# Each program runs twice: as on Solaris 2.x to 10, and with -r 5.11 as on
# Solaris 11, which has the *at system calls in place of open, stat and
# others.
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

# name expected-status expected-text program args...
check() {
  check1 "$1" "" "$@"
  check1 "$1-sol11" "-r 5.11" "$@"
}
check1() {
  name=$1 qargs=$2 status=$4 text=$5 prog=$6
  shift 6
  set +e
  # shellcheck disable=SC2086
  (cd "$out" && ABITEST=yes "${q}qemu-solaris" $qargs "$prog" "$@") >"$out/$name.log" 2>&1
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

flags="--target=sparc-sun-solaris ${SYSROOT:+--sysroot=$SYSROOT} -static -Wall -Werror"
for o in -O0 -O2 -Os; do
  n=sparc$o
  if $CC $flags -mcpu=v8 $o "$here/examples/abitest.c" -o "$out/abitest$n"; then
    ok "build abitest$n"
    check "abitest$n" 0 "abitest: destructor ran" "./abitest$n" one "two words"
  else
    bad "build abitest$n"
  fi
done
if $CC $flags -mcpu=v8 -O2 "$here/examples/hello.c" -o "$out/hello-sparc"; then
  ok "build hello-sparc"
  check "hello-sparc" 0 "Hello, world from ./hello-sparc! 42 123456789 3.25" "./hello-sparc"
else
  bad "build hello-sparc"
fi
# The exit status gets back to the caller.
printf 'int main(void) { return 3; }\n' >"$out/exit3.c"
if $CC $flags -mcpu=v8 -O2 "$out/exit3.c" -o "$out/exit3-sparc"; then
  check "exit3-sparc" 3 "" "./exit3-sparc"
else
  bad "build exit3-sparc"
fi
# V8+ (for UltraSPARC): links with the V8 library; the output is V8+.
if $CC $flags -O2 "$here/examples/abitest.c" -o "$out/abitest-v8plus" &&
   od -An -tx1 -j18 -N2 "$out/abitest-v8plus" | grep -q '00 12'; then
  ok "build abitest-v8plus (EM_SPARC32PLUS)"
else
  bad "build abitest-v8plus"
fi
exit $fail
