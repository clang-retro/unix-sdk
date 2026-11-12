# unix-sdk

Sysroots, examples and tests for classic commercial UNIX systems, built with
clang from [clang-retro/llvm](https://github.com/clang-retro/llvm). Each
system has its own directory:

| Directory | System | Targets | State |
|---|---|---|---|
| [`irix/`](irix/README.md) | SGI IRIX 5.3 and 6.x | `mips-sgi-irix` (o32), `mips64-sgi-irix` (n32, 64) | static programs work, tested in qemu-irix |

Solaris (SPARC and x86), the older BSDs and SCO UnixWare and OpenServer
are next, in that order.

Everything here was written for this project and is under the AGPL (see
[License](#license)), so it can be redistributed. The C library is
[picolibc](https://github.com/clang-retro/picolibc) with a layer for each
system that makes its system calls directly, so static programs need
nothing from the vendor. Programs that link against the system's own
shared libraries need its headers and libraries, which can't be
redistributed: each system has a script that copies them from your own
copy of the system into a separate sysroot.

## IRIX in short

    BIN=.../bin LLVM_SRC=llvm PICOLIBC_SRC=picolibc \
      irix/build-sysroot.sh <bin>/../mips-sgi-irix
    clang --target=mips-sgi-irix6.5 -static hello.c -o hello           # o32
    clang --target=mips64-sgi-irix6.5 -mabi=n32 -static hello.c -o hello
    clang --target=mips64-sgi-irix6.5 -mabi=64 -static hello.c -o hello
    irix/tools/build-qemu-irix.sh qemu && qemu/qemu-irixn32 ./hello

See [irix/README.md](irix/README.md).

## License

Copyright (C) clang-retro contributors.

The clang-retro UNIX SDK is free software under the GNU Affero General
Public License, version 3 only (`AGPL-3.0-only`); the full text is in
[LICENSE](LICENSE). If you distribute a program built with it, or let
people use a modified version over a network, you must offer the
program's complete source under the same license.

Each contributor keeps the copyright in their own work and contributes
it under the same license; see [CONTRIBUTING.md](CONTRIBUTING.md).

picolibc, compiler-rt and qemu-irix, which the scripts build, have their
own licenses (BSD-style, Apache 2.0 with LLVM exceptions, and GPL 2). IRIX
is SGI's: none of it is in this repository.
