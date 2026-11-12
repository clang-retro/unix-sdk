# IRIX

Programs for SGI IRIX 5.3 and 6.x on MIPS, built with clang from
[clang-retro/llvm](https://github.com/clang-retro/llvm). This directory
has:

- `build-sysroot.sh`: builds the sysroot for static programs, with
  [picolibc](https://github.com/clang-retro/picolibc) and its IRIX layer
  (startup code, files, `stat`, `malloc`, time, errors) and the
  compiler-rt builtins, for each of IRIX's three ABIs;
- `examples/`: `hello.c`, and `abitest.c`, which checks the code generator
  and the C library;
- `tests/run-tests.sh`: builds the examples in every ABI and runs them in
  qemu-irix;
- `tools/build-qemu-irix.sh`: builds
  [qemu-irix](https://github.com/n64decomp/qemu-irix), which runs IRIX
  programs on Linux;
- `tools/import-irix.sh`: makes a sysroot of IRIX's own headers and
  libraries from your copy of IRIX, for programs that link against
  `libc.so.1`.

## The ABIs

| ABI | Target | CPU by default | `long`, pointers | Libraries in |
|---|---|---|---|---|
| o32 | `--target=mips-sgi-irix6.5` | MIPS II | 32 bits | `usr/lib` |
| n32 | `--target=mips64-sgi-irix6.5 -mabi=n32` | MIPS III | 32 bits | `usr/lib32` |
| 64 | `--target=mips64-sgi-irix6.5 -mabi=64` | MIPS III | 64 bits | `usr/lib64` |

n32 is the usual ABI on IRIX 6.x; o32 runs on IRIX 5.3 too, and on every
MIPS CPU. `-march=mips4` (R5000, R8000, R10000 and later) works with n32
and 64. Code is big-endian and position-independent, like everything on
IRIX. The `irix6.5` in the target is optional.

## Using it

Build the sysroot (a few minutes) into `mips-sgi-irix/`, next to the
`bin/` directory with clang, where the driver looks for it, or anywhere
else and pass `--sysroot`:

    BIN=.../bin LLVM_SRC=.../llvm PICOLIBC_SRC=.../picolibc \
      irix/build-sysroot.sh .../mips-sgi-irix

`BIN` is the toolchain's `bin/` directory (clang and the LLVM tools, with
the MIPS back end), `LLVM_SRC` a clang-retro/llvm checkout (for
compiler-rt) and `PICOLIBC_SRC` a clang-retro/picolibc checkout. It needs
meson, ninja and cmake. Then:

    clang --target=mips64-sgi-irix6.5 -mabi=n32 -static -O2 hello.c -o hello

The driver compiles with IRIX's predefined macros (`sgi`, `__sgi`,
`_SGI_SOURCE`, `_MIPS_SIM`, `_MIPS_ISA`, `_LANGUAGE_C`, ...) and links
with `ld.lld`: `crt1.o`, `libc.a` and the builtins, entry point `__start`,
text at 0x400000 (o32) or 0x10000000 (n32 and 64), as IRIX's own linker
does. The program is an ordinary IRIX ELF executable: copy it to an IRIX
machine (by FTP in binary mode, NFS or a CD) and run it.

### What works

- `printf` and the rest of stdio, with floating point, `malloc`, the
  string and math functions, `setjmp`, static constructors and
  destructors, `argv`, `environ` and the exit status.
- Files: `open`, `read`, `write`, `lseek`, `close`, `stat`, `fstat`,
  `lstat`, `isatty`, `unlink`, `rename`, `mkdir`, `rmdir`, `chdir`,
  `access`. IRIX's error numbers become `errno` values.
- `time`, `gettimeofday`, `getpid`, `kill`, `raise`.
- 64-bit arithmetic in o32 and 128-bit (`__int128`) in n32 and 64, from
  the builtins.

### Not there yet

- No `getcwd`, directories (`opendir`), `fork`/`exec`, signals from the
  kernel, sockets or threads: the IRIX layer makes only the system calls
  above.
- `long double` is IEEE quad precision in n32 and 64 (in software), not
  MIPSpro's double-double, so it can't be passed to IRIX's own libraries.
  It is the same as `double` in o32, as on IRIX.
- On n32, `lseek` offsets are limited to 32 bits.
- Linking against IRIX's shared libraries (`libc.so.1` and the others)
  with `tools/import-irix.sh` is not tested yet.
- C++ (libc++) isn't built for IRIX yet.

## Running programs

qemu-irix is QEMU's user mode emulation extended with IRIX's system
calls. It runs IRIX programs directly on Linux (x86_64 or any other
host), without an IRIX system or ROM:

    irix/tools/build-qemu-irix.sh qemu
    qemu/qemu-irix ./hello-o32
    qemu/qemu-irixn32 ./hello-n32
    qemu/qemu-irix64 ./hello-64

It needs a C compiler, python3, pkg-config, and glib, pixman and zlib with
their headers (Debian and Ubuntu: `build-essential python3 pkg-config
libglib2.0-dev libpixman-1-dev zlib1g-dev`). It takes about a minute.
`qemu-solaris` (SPARC) is built too.

For a whole IRIX system, MAME emulates SGI Indy and Indigo2 machines,
which need an IRIX installation and the machine's PROM.

The tests build `abitest` at -O0, -O2 and -Os (and -march=mips4 for n32
and 64), `hello` and a program that exits with status 3, in each ABI, and
run them:

    CC=.../bin/clang SYSROOT=.../mips-sgi-irix QEMU_DIR=qemu \
      irix/tests/run-tests.sh

## IRIX's own headers and libraries

Programs that need more than picolibc has, or that should use IRIX's
shared libraries (and so stay small), link dynamically against IRIX's
`libc.so.1`. That needs the headers and libraries of an IRIX system
(`usr/include`, and `usr/lib32` with `crt1.o`, `crtn.o`, `libc.so` and
`rld`, from the IRIS Development Option on 6.x). They are SGI's and can't
be redistributed, so they aren't here. If you have the right to use a copy
of IRIX, copy its files (`/usr/include`, `/usr/lib`, `/usr/lib32`,
`/usr/lib64`) to a directory, then:

    irix/tools/import-irix.sh irix-root irix-sysroot
    clang --target=mips64-sgi-irix6.5 -mabi=n32 --sysroot=irix-sysroot hello.c

Without `-static`, the driver links with IRIX's `crt1.o`, `libc.so` and
`crtn.o`, and sets `/usr/lib32/rld` (or `/usr/lib/rld`, `/usr/lib64/rld`)
as the program interpreter. Keep that sysroot to yourself: the files in it
are SGI's.
