# The BSDs

Programs for FreeBSD 3.0 and later and NetBSD 1.5 and later on 32-bit
x86, built with clang from
[clang-retro/llvm](https://github.com/clang-retro/llvm). This directory
has:

- `build-sysroot.sh`: builds the sysroot for static programs, with
  [picolibc](https://github.com/clang-retro/picolibc) and its BSD layer
  (startup code, files, `stat`, `malloc`, time, errors) and the
  compiler-rt builtins;
- `examples/`: `hello.c`, and `abitest.c`, which checks the code generator
  and the C library;
- `tools/bsdrun.c`: runs static i386 FreeBSD and NetBSD programs on
  Linux, for testing;
- `tests/run-tests.sh`: builds the examples and runs them in bsdrun.

OpenBSD, which drops old system calls rather than keeping them, comes
later.

## The target

| Target | CPU | Runs on |
|---|---|---|
| `--target=i386-unknown-freebsd -march=i486` | i486, x87 | every PC FreeBSD runs on |
| `--target=i386-unknown-freebsd` | Pentium 4 (SSE2) | Pentium 4 and later |
| `--target=i386-unknown-netbsd` | i486, x87 | every PC NetBSD runs on |

The library is built for the i486, and links with both; without
`-march`, clang builds for the Pentium 4 on FreeBSD and the i486 on
NetBSD. `long` and pointers are 32 bits, `off_t` is 64 bits in the system
calls, and `long double` is the x87's 80-bit format, as on the BSDs.

## Using it

Build the sysroot (a minute or two) anywhere, and pass it with
`--sysroot`:

    BIN=.../bin LLVM_SRC=.../llvm PICOLIBC_SRC=.../picolibc \
      bsd/build-sysroot.sh .../i386-unknown-freebsd
    BSD=netbsd BIN=.../bin LLVM_SRC=.../llvm PICOLIBC_SRC=.../picolibc \
      bsd/build-sysroot.sh .../i386-unknown-netbsd

`BIN` is the toolchain's `bin/` directory (clang and the LLVM tools, with
the X86 back end), `LLVM_SRC` a clang-retro/llvm checkout (for
compiler-rt) and `PICOLIBC_SRC` a clang-retro/picolibc checkout. It needs
meson, ninja and cmake. Then:

    clang --target=i386-unknown-freebsd -march=i486 \
      --sysroot=.../i386-unknown-freebsd -static -O2 hello.c -o hello
    clang --target=i386-unknown-netbsd -fuse-ld=lld \
      --sysroot=.../i386-unknown-netbsd -static -O2 hello.c -o hello

clang's FreeBSD driver links with `ld.lld`, as on FreeBSD itself: `crt1.o`,
`libc.a` and `libgcc.a`, which is compiler-rt's builtins, as it is on
FreeBSD. The NetBSD driver needs `-fuse-ld=lld` (it looks for GNU ld
otherwise) and links `crt0.o` and `libc.a`, which has the builtins in it,
as NetBSD's does. The program is an ordinary static ELF executable,
branded FreeBSD in its ELF header or NetBSD by its ident note: copy it to
a FreeBSD or NetBSD machine and run it.

### What works

- `printf` and the rest of stdio, with floating point and `long double`,
  `malloc`, the string and math functions, `setjmp`, static constructors
  and destructors, `argv`, `environ` and the exit status.
- Files: `open`, `read`, `write`, `lseek`, `close`, `stat`, `fstat`,
  `lstat`, `isatty`, `unlink`, `rename`, `mkdir`, `rmdir`, `chdir`,
  `access`. The BSD error numbers become `errno` values.
- `time`, `gettimeofday`, `getpid`, `kill`, `raise`.
- 64-bit arithmetic, from the builtins.
- FreeBSD 3.0 to the current releases: the C library makes the 4.4BSD
  system calls, with the old `stat` and `lseek`, which FreeBSD 12 and 7
  and later keep under `COMPAT_FREEBSD11` and `COMPAT_FREEBSD6` (in the
  GENERIC kernel). A 64-bit FreeBSD runs them too (`COMPAT_FREEBSD32`).
- NetBSD 1.5 to the current releases: the old `stat` (`__stat13`) and a
  32-bit `gettimeofday`, which NetBSD 3.0 and 5.0 and later keep under
  `COMPAT_30` and `COMPAT_50` (in GENERIC).

### Not there yet

- No `getcwd`, directories (`opendir`), `fork`/`exec`, signals from the
  kernel, sockets or threads: the BSD layer makes only the system calls
  above.
- Tested only in bsdrun, not yet on a real FreeBSD or NetBSD machine.
- FreeBSD 2.x and NetBSD 1.4 and earlier used a.out, not ELF: not
  supported.
- Linking against the BSDs' own shared libraries isn't done.
- C++ (libc++) isn't built for the BSDs yet.

## Running programs

bsdrun runs static 32-bit FreeBSD and NetBSD programs on an x86 Linux
machine, without a BSD system. It tells them apart by the FreeBSD ELF
brand or the NetBSD note. Linux loads the program itself (a static i386
ELF program needs nothing from the OS to load), and bsdrun follows it with
`ptrace`: at each system call it puts the Linux call that does the same
work in the registers, then gives the result back the BSD way, with the
carry flag, BSD error numbers and BSD structures. It needs a Linux host
that runs 32-bit programs (most x86-64 ones do) and allows `ptrace`.

    cc -O2 -o bsdrun bsd/tools/bsdrun.c
    ./bsdrun ./hello
    ./bsdrun -v ./hello      # print each system call

It translates only the calls the C library above makes; any other fails
with `ENOSYS`. To run programs on a whole BSD system, QEMU's
`qemu-system-i386` (or a virtual machine) runs FreeBSD or NetBSD itself.

The tests build `abitest` at -O0, -O2 and -Os, `hello` and a program that
exits with status 3 for the i486, `abitest` for the Pentium 4, and run
them in bsdrun (which they build with the host's `cc`):

    CC=.../bin/clang SYSROOT=.../i386-unknown-freebsd bsd/tests/run-tests.sh
    BSD=netbsd CC=.../bin/clang SYSROOT=.../i386-unknown-netbsd bsd/tests/run-tests.sh
