#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 clang-retro contributors
#
# Build qemu-irix (https://github.com/n64decomp/qemu-irix, GPL), QEMU's
# user mode emulation extended to run IRIX programs on Linux: qemu-irix
# (o32), qemu-irixn32 and qemu-irix64, qemu-solaris (SPARC) and
# qemu-solarisx86 (x86); with -r 5.11 the Solaris ones run programs as
# Solaris 11.
#
#   irix/tools/build-qemu-irix.sh OUT
#
#   WORK          build directory (default: ./build-qemu-irix)
#   QEMU_IRIX_SHA the commit to build (default: the one the tests use)
#   STATIC=1      link the programs statically
#
# Needs a C compiler, make, python3, pkg-config, and glib, pixman and zlib
# with their headers (Debian and Ubuntu: build-essential python3
# pkg-config libglib2.0-dev libpixman-1-dev zlib1g-dev).
set -e
out=${1:?usage: build-qemu-irix.sh OUT}
WORK=${WORK:-$PWD/build-qemu-irix}
QEMU_IRIX_SHA=${QEMU_IRIX_SHA:-6d7d1fde2f68adf795e51a19ad2572a48931884e}
mkdir -p "$out" "$WORK"
out=$(cd "$out" && pwd) WORK=$(cd "$WORK" && pwd)

if [ ! -d "$WORK/src/.git" ]; then
  git init -q "$WORK/src"
  git -C "$WORK/src" remote add origin https://github.com/n64decomp/qemu-irix
fi
git -C "$WORK/src" fetch -q --depth 1 origin "$QEMU_IRIX_SHA"
git -C "$WORK/src" checkout -q -f FETCH_HEAD
git -C "$WORK/src" clean -q -fdx

# qemu-solaris knows Solaris 11's *at calls (openat, fstatat, ...) but
# passes their AT_FDCWD and flags to Linux as they are, writes fstatat's
# result to the wrong argument and always says SunOS 5.7. This makes it
# run programs as Solaris 11 does with -r 5.11, which also turns away the
# calls Solaris 11 dropped (open, stat and the others) with ENOSYS.
# qemu-solarisx86 is a new target for Solaris programs on x86 (32-bit),
# made of the Solaris system calls and the i386 CPU: it takes the
# lcall $7,$0 and int $0x91 system call gates, and returns results the
# Solaris way (eax and edx, the carry flag set on error).
src=$WORK/src/linux-user
mkdir -p "$src/solarisx86"
cp "$src/solaris/syscall_nr.h" "$src/solaris/termbits.h" \
  "$src/solaris/target_structs.h" "$src/solarisx86/"
cp "$src/i386/target_cpu.h" "$src/i386/target_elf.h" \
  "$src/i386/target_syscall.h" "$src/solarisx86/"
git -C "$WORK/src" apply <<'PATCH'
diff --git a/configure b/configure
index bbf8956..a5e615c 100755
--- a/configure
+++ b/configure
@@ -6839,6 +6839,13 @@ case "$target_name" in
     TARGET_BASE_ARCH=sparc
     echo "TARGET_ABI_SOLARIS=y" >> $config_target_mak
   ;;
+  solarisx86)
+    TARGET_ARCH=i386
+    TARGET_ABI_DIR=solarisx86
+    TARGET_BASE_ARCH=i386
+    gdb_xml_files="i386-32bit.xml i386-32bit-core.xml i386-32bit-sse.xml"
+    echo "TARGET_ABI_SOLARIS=y" >> $config_target_mak
+  ;;
   solaris64)
     TARGET_ARCH=sparc64
     TARGET_ABI_DIR=solaris
diff --git a/default-configs/solarisx86-linux-user.mak b/default-configs/solarisx86-linux-user.mak
new file mode 100644
index 0000000..79d3595
--- /dev/null
+++ b/default-configs/solarisx86-linux-user.mak
@@ -0,0 +1 @@
+# Default configuration for solarisx86-linux-user (i386 Solaris)
diff --git a/linux-user/main.c b/linux-user/main.c
index 5bc019c..cb46ed4 100644
--- a/linux-user/main.c
+++ b/linux-user/main.c
@@ -230,6 +230,9 @@ void cpu_loop(CPUX86State *env)
     abi_ulong pc;
     abi_ulong ret;
     target_siginfo_t info;
+#ifdef TARGET_ABI_SOLARIS
+    int sol_len = 7;
+#endif
 
     for(;;) {
         cpu_exec_start(cs);
@@ -282,7 +285,57 @@ void cpu_loop(CPUX86State *env)
             info._sifields._sigfault._addr = 0;
             queue_signal(env, info.si_signo, QEMU_SI_FAULT, &info);
             break;
+#ifdef TARGET_ABI_SOLARIS
+        sol_syscall:
+            {
+                abi_ulong sp = env->regs[R_ESP], a[8];
+                int i;
+
+                for (i = 0; i < 8; i++) {
+                    if (get_user_ual(a[i], sp + 4 + i * 4)) {
+                        a[i] = 0;
+                    }
+                }
+                ret = do_syscall(env, env->regs[R_EAX], a[0], a[1], a[2],
+                                 a[3], a[4], a[5], a[6], a[7]);
+                if (ret == -TARGET_ERESTARTSYS) {
+                    break;  /* re-execute the trap */
+                }
+                if (ret == -TARGET_QEMU_ESIGRETURN) {
+                    break;
+                }
+                /* Between cpu_exec calls the flags are all in eflags. */
+                if ((abi_ulong)ret >= (abi_ulong)(-515)) {
+                    env->eflags |= CC_C;
+                    ret = -ret;
+                } else {
+                    env->eflags &= ~CC_C;
+                }
+                env->regs[R_EAX] = ret;
+                env->eip += sol_len;
+            }
+            break;
+#endif
         case EXCP0D_GPF:
+#ifdef TARGET_ABI_SOLARIS
+            {
+                /* lcall $7,$0 (or $0x27,$0) is the Solaris syscall gate */
+                uint8_t insn[7];
+                if (copy_from_user(insn, env->eip, 7) == 0 &&
+                    insn[0] == 0x9a && insn[1] == 0 && insn[2] == 0 &&
+                    insn[3] == 0 && insn[4] == 0 &&
+                    (insn[5] == 0x07 || insn[5] == 0x27) && insn[6] == 0) {
+                    sol_len = 7;
+                    goto sol_syscall;
+                }
+                /* int $0x91 is the Solaris 10+ fast trap */
+                if (copy_from_user(insn, env->eip, 2) == 0 &&
+                    insn[0] == 0xcd && insn[1] == 0x91) {
+                    sol_len = 2;
+                    goto sol_syscall;
+                }
+            }
+#endif
             /* XXX: potential problem if ABI32 */
 #ifndef TARGET_X86_64
             if (env->eflags & VM_MASK) {
@@ -5047,6 +5100,11 @@ int main(int argc, char **argv, char **envp)
     env->regs[R_ESP] = regs->esp;
     env->eip = regs->eip;
 #endif
+#ifdef TARGET_ABI_SOLARIS
+    /* Empty LDT, so the lcall $7 syscall gate raises #GP for cpu_loop. */
+    env->ldt.base = 0;
+    env->ldt.limit = 0;
+#endif
 
     /* linux interrupt setup */
 #ifndef TARGET_ABI32
diff --git a/linux-user/signal.c b/linux-user/signal.c
index 827180e..6906104 100644
--- a/linux-user/signal.c
+++ b/linux-user/signal.c
@@ -842,7 +842,71 @@ int do_sigaction(CPUArchState *env, int sig, const struct target_sigaction *act,
     return ret;
 }
 
-#if defined(TARGET_I386)
+#if defined(TARGET_ABI_SOLARIS) && defined(TARGET_I386)
+
+/*
+ * Solaris on i386: getcontext and setcontext work on the general
+ * registers. Signal handlers aren't called yet: a caught signal stops the
+ * program, as an uncaught one would.
+ */
+int save_context(CPUX86State *env, struct target_mcontext *sc, int setret)
+{
+    static const int map[] = {
+        [TARGET_SOL_EDI] = R_EDI, [TARGET_SOL_ESI] = R_ESI,
+        [TARGET_SOL_EBP] = R_EBP, [TARGET_SOL_ESP] = R_ESP,
+        [TARGET_SOL_EBX] = R_EBX, [TARGET_SOL_EDX] = R_EDX,
+        [TARGET_SOL_ECX] = R_ECX, [TARGET_SOL_EAX] = R_EAX,
+    };
+    int i;
+
+    for (i = TARGET_SOL_EDI; i <= TARGET_SOL_EAX; i++) {
+        __put_user(env->regs[map[i]], &sc->gregs[i]);
+    }
+    __put_user(env->regs[R_ESP], &sc->gregs[TARGET_SOL_UESP]);
+    __put_user(env->eip, &sc->gregs[TARGET_SOL_EIP]);
+    __put_user(cpu_compute_eflags(env), &sc->gregs[TARGET_SOL_EFL]);
+    if (setret) {
+        __put_user(0, &sc->gregs[TARGET_SOL_EAX]);
+    }
+    return 0;
+}
+
+int restore_context(CPUX86State *env, struct target_mcontext *sc)
+{
+    static const int map[] = {
+        [TARGET_SOL_EDI] = R_EDI, [TARGET_SOL_ESI] = R_ESI,
+        [TARGET_SOL_EBP] = R_EBP, [TARGET_SOL_ESP] = R_ESP,
+        [TARGET_SOL_EBX] = R_EBX, [TARGET_SOL_EDX] = R_EDX,
+        [TARGET_SOL_ECX] = R_ECX, [TARGET_SOL_EAX] = R_EAX,
+    };
+    abi_ulong v;
+    int i;
+
+    for (i = TARGET_SOL_EDI; i <= TARGET_SOL_EAX; i++) {
+        __get_user(v, &sc->gregs[i]);
+        env->regs[map[i]] = v;
+    }
+    __get_user(v, &sc->gregs[TARGET_SOL_UESP]);
+    env->regs[R_ESP] = v;
+    __get_user(v, &sc->gregs[TARGET_SOL_EIP]);
+    env->eip = v;
+    return 0;
+}
+
+static void setup_frame(int sig, struct target_sigaction *ka,
+                        target_sigset_t *set, CPUX86State *env)
+{
+    force_sigsegv(env, sig);
+}
+
+static void setup_rt_frame(int sig, struct target_sigaction *ka,
+                           target_siginfo_t *info,
+                           target_sigset_t *set, CPUX86State *env)
+{
+    force_sigsegv(env, sig);
+}
+
+#elif defined(TARGET_I386)
 /* from the Linux kernel - /arch/x86/include/uapi/asm/sigcontext.h */
 
 struct target_fpreg {
diff --git a/linux-user/solarisx86/target_signal.h b/linux-user/solarisx86/target_signal.h
new file mode 100644
index 0000000..0d125c2
--- /dev/null
+++ b/linux-user/solarisx86/target_signal.h
@@ -0,0 +1,63 @@
+#ifndef SOLARISX86_TARGET_SIGNAL_H
+#define SOLARISX86_TARGET_SIGNAL_H
+
+#include "cpu.h"
+
+/* Solaris on i386 (32-bit programs). */
+
+typedef struct target_sigaltstack {
+	abi_ulong ss_sp;
+	abi_ulong ss_size;
+	abi_long ss_flags;
+} target_stack_t;
+
+#define TARGET_SS_ONSTACK	1
+#define TARGET_SS_DISABLE	2
+
+#define TARGET_MINSIGSTKSZ	2048
+#define TARGET_SIGSTKSZ		8192
+
+static inline abi_ulong get_sp_from_cpustate(CPUX86State *state)
+{
+    return state->regs[R_ESP];
+}
+
+/* <sys/regset.h>: the 19 general registers, then the FPU state. */
+#define TARGET_SOL_GS     0
+#define TARGET_SOL_FS     1
+#define TARGET_SOL_ES     2
+#define TARGET_SOL_DS     3
+#define TARGET_SOL_EDI    4
+#define TARGET_SOL_ESI    5
+#define TARGET_SOL_EBP    6
+#define TARGET_SOL_ESP    7
+#define TARGET_SOL_EBX    8
+#define TARGET_SOL_EDX    9
+#define TARGET_SOL_ECX    10
+#define TARGET_SOL_EAX    11
+#define TARGET_SOL_TRAPNO 12
+#define TARGET_SOL_ERR    13
+#define TARGET_SOL_EIP    14
+#define TARGET_SOL_CS     15
+#define TARGET_SOL_EFL    16
+#define TARGET_SOL_UESP   17
+#define TARGET_SOL_SS     18
+
+struct target_mcontext {
+	uint32_t gregs[19];
+	uint32_t fpregs[95];
+};
+
+struct target_ucontext {
+	abi_ulong           tuc_flags;
+	abi_ulong           tuc_link;
+	target_sigset_t     tuc_sigmask;
+	struct target_sigaltstack  tuc_stack;
+	struct target_mcontext tuc_mcontext;
+	abi_long            tuc_filler[5];
+};
+
+int save_context(CPUX86State *regs, struct target_mcontext *sc, int setret);
+int restore_context(CPUX86State *regs, struct target_mcontext *sc);
+
+#endif /* SOLARISX86_TARGET_SIGNAL_H */
diff --git a/linux-user/syscall.c b/linux-user/syscall.c
index f9bc06a..a69b8e3 100644
--- a/linux-user/syscall.c
+++ b/linux-user/syscall.c
@@ -120,6 +120,14 @@
 #include "uname.h"
 
 #include "qemu.h"
+#ifdef TARGET_ABI_SOLARIS
+/* Solaris returns a second result in %o1 (SPARC) or %edx (x86). */
+#ifdef TARGET_SPARC
+#define SOL_RV2(env) ((env)->regwptr[1])
+#else
+#define SOL_RV2(env) ((env)->regs[R_EDX])
+#endif
+#endif
 
 #ifndef CLONE_IO
 #define CLONE_IO                0x80000000      /* Clone io context */
@@ -1680,6 +1688,9 @@ static abi_long do_pipe(void *cpu_env, abi_ulong pipedes,
 #elif defined(TARGET_SPARC)
         ((CPUSPARCState*)cpu_env)->regwptr[1] = host_pipe[1];
         return host_pipe[0];
+#elif defined(TARGET_ABI_SOLARIS) && defined(TARGET_I386)
+        ((CPUX86State*)cpu_env)->regs[R_EDX] = host_pipe[1];
+        return host_pipe[0];
 #endif
     }
 
@@ -6616,7 +6627,7 @@ static int do_fork(CPUArchState *env, unsigned int flags, abi_ulong newsp,
         }
 #ifdef TARGET_ABI_SOLARIS
         if (ret >= 0)
-            env->regwptr[1] = (ret == 0);
+            SOL_RV2(env) = (ret == 0);
         if (ret == 0)
             ret = getppid();
 #endif
@@ -8320,6 +8331,31 @@ static int qemu_execve(const char *filename, char **argv, char **envp)
 /* do_syscall() should always have a single exit point at the end so
    that actions, such as logging of syscall results, can be performed.
    All errnos that do_syscall() returns must be -TARGET_<errcode>. */
+#ifdef TARGET_ABI_SOLARIS
+/* Solaris's AT_FDCWD and *at flags differ from Linux's. */
+static int sol_dirfd(abi_long fd)
+{
+    return (abi_ulong)fd == 0xffd19553u ? AT_FDCWD : (int)fd;
+}
+static int sol_atflags(abi_long f)
+{
+    int r = 0;
+    if (f & 0x1000) r |= AT_SYMLINK_NOFOLLOW;
+    if (f & 0x2000) r |= AT_SYMLINK_FOLLOW;
+    if (f & 0x1) r |= AT_REMOVEDIR;
+    if (f & 0x4) r |= AT_EACCESS;
+    return r;
+}
+static int sol_is_11(void)
+{
+    const char *r = qemu_uname_release;
+    return r && r[0] == '5' && r[1] == '.' && atoi(r + 2) >= 11;
+}
+#else
+#define sol_dirfd(fd) (fd)
+#define sol_atflags(f) (f)
+#endif
+
 abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
                     abi_long arg2, abi_long arg3, abi_long arg4,
                     abi_long arg5, abi_long arg6, abi_long arg7,
@@ -8356,6 +8392,19 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
     if(do_strace)
         print_syscall(num, arg1, arg2, arg3, arg4, arg5, arg6);
 
+#ifdef TARGET_ABI_SOLARIS
+    /* Solaris 11 (-r 5.11 or later) has no open, stat and the others. */
+    if (sol_is_11() &&
+        (num == TARGET_NR_open || num == TARGET_NR_stat ||
+         num == TARGET_NR_lstat || num == TARGET_NR_fstat ||
+         num == TARGET_NR_unlink || num == TARGET_NR_rmdir ||
+         num == TARGET_NR_mkdir || num == TARGET_NR_rename ||
+         num == TARGET_NR_access)) {
+        ret = -TARGET_ENOSYS;
+        goto fail;
+    }
+#endif
+
     switch(num) {
     case TARGET_NR_exit:
 #if defined(TARGET_ABI_IRIX) && defined(__NR_exit_group)
@@ -8422,7 +8471,7 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
     case TARGET_NR_openat:
         if (!(p = lock_user_string(arg2)))
             goto efault;
-        ret = get_errno(do_openat(cpu_env, arg1, p,
+        ret = get_errno(do_openat(cpu_env, sol_dirfd(arg1), p,
                                   target_to_host_bitmask(arg3, fcntl_flags_tbl),
                                   arg4));
         fd_trans_unregister(ret);
@@ -8574,7 +8623,7 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
     case TARGET_NR_unlinkat:
         if (!(p = lock_user_string(arg2)))
             goto efault;
-        ret = get_errno(unlinkat(arg1, p, arg3));
+        ret = get_errno(unlinkat(sol_dirfd(arg1), p, sol_atflags(arg3)));
         unlock_user(p, arg2, 0);
         break;
 #endif
@@ -8787,7 +8836,7 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
 #ifdef TARGET_NR_getpid
     case TARGET_NR_getpid:
 #ifdef TARGET_ABI_SOLARIS
-        ((CPUSPARCState*)cpu_env)->regwptr[1] = getppid();
+        SOL_RV2((CPUArchState *)cpu_env) = getppid();
 #endif
 #ifdef TARGET_ABI_IRIX
         ((CPUMIPSState*)cpu_env)->active_tc.gpr[3] = getppid();
@@ -8977,7 +9026,7 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
     case TARGET_NR_faccessat:
         if (!(p = lock_user_string(arg2)))
             goto efault;
-        ret = get_errno(faccessat(arg1, p, arg3, 0));
+        ret = get_errno(faccessat(sol_dirfd(arg1), p, arg3, 0));
         unlock_user(p, arg2, 0);
         break;
 #endif
@@ -9026,7 +9075,7 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
             if (!p || !p2)
                 ret = -TARGET_EFAULT;
             else
-                ret = get_errno(renameat(arg1, p, arg3, p2));
+                ret = get_errno(renameat(sol_dirfd(arg1), p, sol_dirfd(arg3), p2));
             unlock_user(p2, arg4, 0);
             unlock_user(p, arg2, 0);
         }
@@ -9060,7 +9109,7 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
     case TARGET_NR_mkdirat:
         if (!(p = lock_user_string(arg2)))
             goto efault;
-        ret = get_errno(mkdirat(arg1, p, arg3));
+        ret = get_errno(mkdirat(sol_dirfd(arg1), p, arg3));
         unlock_user(p, arg2, 0);
         break;
 #endif
@@ -10659,11 +10708,21 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
         break;
 #ifdef TARGET_NR_fstatat
     case TARGET_NR_fstatat:
-        if (!(p = lock_user_string(arg2)))
-            goto efault;
-        ret = get_errno(fstatat(arg1, path(p), &st, arg4));
-        unlock_user(p, arg2, 0);
-        goto do_stat;
+        /* Solaris: fstatat(fd, NULL, ...) is fstat(fd). */
+        if (arg2 == 0) {
+            ret = get_errno(fstat(arg1, &st));
+        } else {
+            if (!(p = lock_user_string(arg2)))
+                goto efault;
+            ret = get_errno(fstatat(sol_dirfd(arg1), path(p), &st,
+                                    sol_atflags(arg4)));
+            unlock_user(p, arg2, 0);
+        }
+        /* The buffer is the third argument. */
+        if (!is_error(ret)) {
+            ret = host_to_target_stat(cpu_env, arg3, &st);
+        }
+        break;
 #endif
 #ifdef TARGET_NR_olduname
     case TARGET_NR_olduname:
@@ -10877,7 +10936,7 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
         }
         break;
 #endif
-#ifdef TARGET_I386
+#if defined(TARGET_I386) && !defined(TARGET_ABI_SOLARIS)
     case TARGET_NR_modify_ldt:
         ret = do_modify_ldt(cpu_env, arg1, arg2, arg3);
         break;
@@ -11901,7 +11960,7 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
 #ifdef TARGET_NR_getuid
     case TARGET_NR_getuid:
 #ifdef TARGET_ABI_SOLARIS
-        ((CPUSPARCState*)cpu_env)->regwptr[1] = high2lowuid(geteuid());
+        SOL_RV2((CPUArchState *)cpu_env) = high2lowuid(geteuid());
 #endif
 #ifdef TARGET_ABI_IRIX
         ((CPUMIPSState*)cpu_env)->active_tc.gpr[3] = high2lowuid(geteuid());
@@ -11912,7 +11971,7 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
 #ifdef TARGET_NR_getgid
     case TARGET_NR_getgid:
 #ifdef TARGET_ABI_SOLARIS
-        ((CPUSPARCState*)cpu_env)->regwptr[1] = high2lowuid(getegid());
+        SOL_RV2((CPUArchState *)cpu_env) = high2lowuid(getegid());
 #endif
 #ifdef TARGET_ABI_IRIX
         ((CPUMIPSState*)cpu_env)->active_tc.gpr[3] = high2lowuid(getegid());
@@ -14054,7 +14113,8 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
             strncpy(target_buf, "SunOS", arg3-1);
             break;
         case TARGET_NR_sysinfo_release:
-            strncpy(target_buf, "5.7", arg3-1);
+            strncpy(target_buf, qemu_uname_release && *qemu_uname_release ?
+                    qemu_uname_release : "5.7", arg3-1);
             break;
         case TARGET_NR_sysinfo_version:
             strncpy(target_buf, "Generic", arg3-1);
diff --git a/linux-user/syscall_defs.h b/linux-user/syscall_defs.h
index b2c0940..ec081e1 100644
--- a/linux-user/syscall_defs.h
+++ b/linux-user/syscall_defs.h
@@ -1504,9 +1504,9 @@ struct target_winsize {
 #define TARGET_MAP_UNINITIALIZED 0x4000000	/* for anonymous mmap, memory could be uninitialized */
 #endif
 
-#if (defined(TARGET_I386) && defined(TARGET_ABI32)) \
+#if !defined(TARGET_ABI_SOLARIS) && ((defined(TARGET_I386) && defined(TARGET_ABI32)) \
     || (defined(TARGET_ARM) && defined(TARGET_ABI32)) \
-    || defined(TARGET_CRIS) || defined(TARGET_UNICORE32)
+    || defined(TARGET_CRIS) || defined(TARGET_UNICORE32))
 struct target_stat {
 	unsigned short st_dev;
 	unsigned short __pad1;
PATCH

mkdir -p "$WORK/build"
cd "$WORK/build"
# The submodules (dtc, capstone) are only for system emulation and the
# disassembler, which these targets don't need.
"$WORK/src/configure" --python=python3 \
  --target-list=irix-linux-user,irixn32-linux-user,irix64-linux-user,solaris-linux-user,solarisx86-linux-user \
  --disable-werror --disable-capstone --disable-docs --disable-tools \
  --disable-git-update --disable-fdt ${STATIC:+--static} >configure.log 2>&1 ||
  { tail -20 configure.log; exit 1; }
make -j"$(nproc)" GIT_SUBMODULES= >make.log 2>&1 ||
  { grep -E 'error' make.log | head -20; exit 1; }
for t in irix irixn32 irix64 solaris solarisx86; do
  install -m 755 "$t-linux-user/qemu-$t" "$out/qemu-$t"
done
echo "qemu-irix written to $out"
