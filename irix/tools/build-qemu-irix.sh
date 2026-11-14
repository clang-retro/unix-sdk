#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 clang-retro contributors
#
# Build qemu-irix (https://github.com/n64decomp/qemu-irix, GPL), QEMU's
# user mode emulation extended to run IRIX programs on Linux: qemu-irix
# (o32), qemu-irixn32 and qemu-irix64, and qemu-solaris (SPARC; with
# -r 5.11 it runs programs as Solaris 11).
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

# qemu-solaris knows Solaris 11's *at calls (openat, fstatat, ...) but
# passes their AT_FDCWD and flags to Linux as they are, writes fstatat's
# result to the wrong argument and always says SunOS 5.7. This makes it
# run programs as Solaris 11 does with -r 5.11, which also turns away the
# calls Solaris 11 dropped (open, stat and the others) with ENOSYS.
git -C "$WORK/src" apply <<'PATCH'
diff --git a/linux-user/syscall.c b/linux-user/syscall.c
index f9bc06a..dccac83 100644
--- a/linux-user/syscall.c
+++ b/linux-user/syscall.c
@@ -8320,6 +8320,31 @@ static int qemu_execve(const char *filename, char **argv, char **envp)
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
@@ -8356,6 +8381,19 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
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
@@ -8422,7 +8460,7 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
     case TARGET_NR_openat:
         if (!(p = lock_user_string(arg2)))
             goto efault;
-        ret = get_errno(do_openat(cpu_env, arg1, p,
+        ret = get_errno(do_openat(cpu_env, sol_dirfd(arg1), p,
                                   target_to_host_bitmask(arg3, fcntl_flags_tbl),
                                   arg4));
         fd_trans_unregister(ret);
@@ -8574,7 +8612,7 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
     case TARGET_NR_unlinkat:
         if (!(p = lock_user_string(arg2)))
             goto efault;
-        ret = get_errno(unlinkat(arg1, p, arg3));
+        ret = get_errno(unlinkat(sol_dirfd(arg1), p, sol_atflags(arg3)));
         unlock_user(p, arg2, 0);
         break;
 #endif
@@ -8977,7 +9015,7 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
     case TARGET_NR_faccessat:
         if (!(p = lock_user_string(arg2)))
             goto efault;
-        ret = get_errno(faccessat(arg1, p, arg3, 0));
+        ret = get_errno(faccessat(sol_dirfd(arg1), p, arg3, 0));
         unlock_user(p, arg2, 0);
         break;
 #endif
@@ -9026,7 +9064,7 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
             if (!p || !p2)
                 ret = -TARGET_EFAULT;
             else
-                ret = get_errno(renameat(arg1, p, arg3, p2));
+                ret = get_errno(renameat(sol_dirfd(arg1), p, sol_dirfd(arg3), p2));
             unlock_user(p2, arg4, 0);
             unlock_user(p, arg2, 0);
         }
@@ -9060,7 +9098,7 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
     case TARGET_NR_mkdirat:
         if (!(p = lock_user_string(arg2)))
             goto efault;
-        ret = get_errno(mkdirat(arg1, p, arg3));
+        ret = get_errno(mkdirat(sol_dirfd(arg1), p, arg3));
         unlock_user(p, arg2, 0);
         break;
 #endif
@@ -10659,11 +10697,21 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
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
@@ -14054,7 +14102,8 @@ abi_long do_syscall(void *cpu_env, int num, abi_long arg1,
             strncpy(target_buf, "SunOS", arg3-1);
             break;
         case TARGET_NR_sysinfo_release:
-            strncpy(target_buf, "5.7", arg3-1);
+            strncpy(target_buf, qemu_uname_release && *qemu_uname_release ?
+                    qemu_uname_release : "5.7", arg3-1);
             break;
         case TARGET_NR_sysinfo_version:
             strncpy(target_buf, "Generic", arg3-1);
PATCH

mkdir -p "$WORK/build"
cd "$WORK/build"
# The submodules (dtc, capstone) are only for system emulation and the
# disassembler, which these targets don't need.
"$WORK/src/configure" --python=python3 \
  --target-list=irix-linux-user,irixn32-linux-user,irix64-linux-user,solaris-linux-user \
  --disable-werror --disable-capstone --disable-docs --disable-tools \
  --disable-git-update --disable-fdt ${STATIC:+--static} >configure.log 2>&1 ||
  { tail -20 configure.log; exit 1; }
make -j"$(nproc)" GIT_SUBMODULES= >make.log 2>&1 ||
  { grep -E 'error' make.log | head -20; exit 1; }
for t in irix irixn32 irix64 solaris; do
  install -m 755 "$t-linux-user/qemu-$t" "$out/qemu-$t"
done
echo "qemu-irix written to $out"
