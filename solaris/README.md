# Solaris

Programs for Solaris 2.5 to 11.4 on 32-bit SPARC, built with clang from
[clang-retro/llvm](https://github.com/clang-retro/llvm). This directory
has:

- `build-sysroot.sh`: builds the sysroot for static programs, with
  [picolibc](https://github.com/clang-retro/picolibc) and its Solaris
  layer (startup code, files, `stat`, `malloc`, time, errors, `long
  double`) and the compiler-rt builtins;
- `examples/`: `hello.c`, and `abitest.c`, which checks the code generator
  and the C library;
- `tests/run-tests.sh`: builds the examples and runs them in qemu-solaris.

x86 Solaris and 64-bit SPARC come later.

## The target

| Target | CPU | Runs on |
|---|---|---|
| `--target=sparc-sun-solaris -mcpu=v8` | SPARC V8 | every SPARC machine: SPARCstation, Ultra, Sun Blade |
| `--target=sparc-sun-solaris` | V8+ (V9 in 32 bits) | UltraSPARC and later |

The library is built for V8, and links with both. Without `-mcpu`, clang
builds for V8+; use `-mcpu=v8` for SPARCstations (sun4m and sun4d) and for
qemu-solaris.
`long` and pointers are 32 bits, and `long double` is IEEE quad precision
(in software), as on Solaris.

## Using it

Build the sysroot (a minute or two) into `sparc-sun-solaris/`, next to the
`bin/` directory with clang, where the driver looks for it, or anywhere
else and pass `--sysroot`:

    BIN=.../bin LLVM_SRC=.../llvm PICOLIBC_SRC=.../picolibc \
      solaris/build-sysroot.sh .../sparc-sun-solaris

`BIN` is the toolchain's `bin/` directory (clang and the LLVM tools, with
the SPARC back end), `LLVM_SRC` a clang-retro/llvm checkout (for
compiler-rt) and `PICOLIBC_SRC` a clang-retro/picolibc checkout. It needs
meson, ninja and cmake. Then:

    clang --target=sparc-sun-solaris -mcpu=v8 -static -O2 hello.c -o hello

When it runs on a system that isn't Solaris and finds no GCC for Solaris,
the driver links with `ld.lld`: `crt1.o`, `libc.a` and the builtins,
entry point `_start`, text at 0x10000, as Solaris's own linker does. The
program is an ordinary Solaris ELF executable: copy it to a Solaris
machine (by FTP in binary mode, NFS or a CD) and run it.

### What works

- `printf` and the rest of stdio, with floating point and `long double`,
  `malloc`, the string and math functions, `setjmp`, static constructors
  and destructors, `argv`, `environ` and the exit status.
- Files: `open`, `read`, `write`, `lseek`, `close`, `stat`, `fstat`,
  `lstat`, `isatty`, `unlink`, `rename`, `mkdir`, `rmdir`, `chdir`,
  `access`. Solaris's error numbers become `errno` values.
- `time`, `gettimeofday`, `getpid`, `kill`, `raise`.
- 64-bit arithmetic, from the builtins.
- Solaris 11: it dropped `open`, `stat`, `unlink`, `mkdir` and other
  system calls for `openat`, `fstatat` and the other `*at` calls. The C
  library asks the kernel its release, and on SunOS 5.11 and later
  (Solaris 11, and illumos) it uses the `*at` calls, so the same program
  runs on Solaris 2.5 and on 11.4. Solaris 11 runs 32-bit SPARC programs
  on every machine it supports.

### Not there yet

- No `getcwd`, directories (`opendir`), `fork`/`exec`, signals from the
  kernel, sockets or threads: the Solaris layer makes only the system
  calls above.
- Solaris 11 is tested only in qemu-solaris run as SunOS 5.11, not yet on
  a real Solaris 11 machine.
- `lseek` offsets are limited to 32 bits.
- Linking against Solaris's own shared libraries (`libc.so.1`) isn't
  done yet.
- C++ (libc++) isn't built for Solaris yet.

## Running programs

qemu-solaris, which is built with qemu-irix, is QEMU's user mode
emulation extended with Solaris's system calls. It runs 32-bit SPARC V8
Solaris programs directly on Linux, without a Solaris system:

    irix/tools/build-qemu-irix.sh qemu
    qemu/qemu-solaris ./hello           # as SunOS 5.7
    qemu/qemu-solaris -r 5.11 ./hello   # as Solaris 11

[IRIX](../irix/README.md) says what the build needs, under "Running
programs". V8+ programs need a real UltraSPARC, or a whole emulated
machine: QEMU's `qemu-system-sparc` (a SPARCstation 5 with Solaris 2.5
to 9) or `qemu-system-sparc64` (a Sun Ultra 5), with a Solaris
installation.

The tests build `abitest` at -O0, -O2 and -Os, `hello` and a program that
exits with status 3, for V8, run each as Solaris 2.x and as Solaris 11,
and link `abitest` for V8+:

    CC=.../bin/clang SYSROOT=.../sparc-sun-solaris QEMU_DIR=qemu \
      solaris/tests/run-tests.sh
