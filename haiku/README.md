# Haiku

Programs for [Haiku](https://www.haiku-os.org/) R1 on x86_64 and 32-bit
x86, built with clang. This directory has a script that makes a Haiku
sysroot from Haiku's own packages, an example, and a tool that runs
Haiku in QEMU and runs programs in it from the host.

    haiku/build-sysroot.sh haiku-sysroot
    clang++ --target=x86_64-unknown-haiku --sysroot=haiku-sysroot -fuse-ld=lld \
      haiku/examples/hello.cpp -lbe -o hello
    haiku/tools/haiku-vm.py run haiku-master-x86_64-anyboot.iso script.sh

For 32-bit x86, use `ARCH=x86` and `--target=i586-pc-haiku`.

See [Using the Haiku SDK](../docs/haiku-using.md) and
[Running programs in Haiku](../docs/haiku-running.md).
