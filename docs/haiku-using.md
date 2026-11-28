# Using the Haiku SDK

## The targets

| Target | Architecture | Runs on |
|---|---|---|
| `--target=x86_64-unknown-haiku` | x86_64 | the x86_64 release of Haiku |
| `--target=i586-pc-haiku` | 32-bit x86 | the x86_gcc2 hybrid release of Haiku (its gcc 15 libraries) |

Upstream clang has a Haiku driver. clang 18 and later can build programs
for Haiku. Use `-fuse-ld=lld`: the driver does not find a Haiku linker
otherwise.

## The sysroot

Haiku's headers and libraries are free software, so the script gets them
from Haiku's package repositories. You do not need a copy of Haiku.

    haiku/build-sysroot.sh OUT

| Variable | Default | Meaning |
|---|---|---|
| `ARCH` | `x86_64` | `x86_64`, or `x86` for the 32-bit hybrid release |
| `BRANCH` | `master` | the branch of the repositories, for example `r1beta5` |
| `WORK` | `./build-haiku-$ARCH` | the directory for the downloaded packages |

The script needs curl and Python 3 with the `zstandard` module. It
downloads these packages:

- From the Haiku repository: `haiku` and `haiku_devel` (for `x86`:
  `haiku_x86`, `haiku_x86_devel`, and `haiku_devel` for the headers).
- From the HaikuPorts repository: `gcc`, `gcc_syslibs` and
  `gcc_syslibs_devel` (for `x86`: the `gcc_x86` packages). These give
  libstdc++, its headers, `libgcc.a` and the start files.

The script extracts the files into the layout of clang's Haiku driver:

| Directory | Contents |
|---|---|
| `boot/system/develop/headers/` | the system headers and the libstdc++ headers |
| `boot/system/develop/lib/` | the start files and the static libraries |
| `boot/system/lib/` | the shared libraries (`libroot.so`, `libbe.so` and others) |
| `boot/system/develop/tools/lib/gcc/TRIPLE/VERSION/` | `crtbeginS.o`, `crtendS.o`, `libgcc.a` |

For `x86`, the files of the secondary architecture (`lib/x86`,
`develop/lib/x86`, `develop/headers/x86`) go into the places of the
primary architecture. The script removes the compiler programs of gcc,
the debug files and the private headers. The result is about 80 MB.

## Building programs

    clang++ --target=x86_64-unknown-haiku --sysroot=OUT -fuse-ld=lld \
      prog.cpp -lbe -o prog

- `libroot` (the C library, the math library and the POSIX threads) is
  always linked. Add `-lbe` for the Be API, `-lnetwork` for sockets and
  `-lbsd` for the BSD functions.
- Some BSD and GNU functions (for example `timegm` and
  `dl_iterate_phdr`) are declared only with `-D_DEFAULT_SOURCE`.
- Programs link dynamically. Haiku has no static `libroot`.

## The package tool

`tools/hpkg.py` reads Haiku packages (HPKG version 2) and package
repository files. It needs no Haiku tools.

| Command | What it does |
|---|---|
| `hpkg.py list PACKAGE` | lists the files of the package |
| `hpkg.py extract [--map FROM=TO]... PACKAGE DIR [PREFIX...]` | extracts the files under each PREFIX (or all files) into DIR; `--map` moves a directory |
| `hpkg.py resolve REPO NAME...` | gives the file name of the newest package with each name in the repository file REPO |

## Testing

    SYSROOT=OUT [TARGET=...] [HAIKU_IMAGE=IMAGE] haiku/tests/run-tests.sh [DIR]

The script builds `examples/hello.cpp`. With `HAIKU_IMAGE`, it also runs
the program in Haiku in QEMU (see
[Running programs in Haiku](haiku-running.md)).
