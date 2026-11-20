/*
 * SPDX-License-Identifier: AGPL-3.0-only
 * Copyright (c) 2026 clang-retro contributors
 *
 * bsdrun: run a static 32-bit x86 FreeBSD or NetBSD program on Linux, for
 * testing.
 *
 *   bsdrun [-v] PROGRAM [ARGS...]
 *
 * Linux loads the program itself (it ignores the ELF OS/ABI byte, and a
 * static i386 program has no interpreter), and bsdrun follows it with
 * ptrace. At each system call (int $0x80, the number in eax and the
 * arguments on the stack, as on every BSD for x86) it puts the Linux call
 * that does the same work in the registers. The kernel runs that, in the
 * program, so memory, files and brk are the program's own. On the way out
 * bsdrun gives the result back the BSD way: eax (and edx), with the carry
 * flag set and a BSD error number on failure, and BSD structures (stat)
 * converted in place. The ELF header (OS/ABI FreeBSD) or a NetBSD ident
 * note says which BSD the program is for.
 *
 * Only what the C library in the sysroot uses is translated; any other
 * call fails with ENOSYS, and -v prints each call. Needs an x86-64 or i386
 * Linux host that runs 32-bit programs.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/personality.h>
#include <sys/ptrace.h>
#include <sys/uio.h>
#include <sys/user.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__x86_64__)
#define R_NR(r)  ((r).orig_rax)
#define R_AX(r)  ((r).rax)
#define R_BX(r)  ((r).rbx)
#define R_CX(r)  ((r).rcx)
#define R_DX(r)  ((r).rdx)
#define R_SI(r)  ((r).rsi)
#define R_DI(r)  ((r).rdi)
#define R_BP(r)  ((r).rbp)
#define R_SP(r)  ((r).rsp)
#define R_FL(r)  ((r).eflags)
#define R_IP(r)  ((r).rip)
#elif defined(__i386__)
#define R_NR(r)  ((r).orig_eax)
#define R_AX(r)  ((r).eax)
#define R_BX(r)  ((r).ebx)
#define R_CX(r)  ((r).ecx)
#define R_DX(r)  ((r).edx)
#define R_SI(r)  ((r).esi)
#define R_DI(r)  ((r).edi)
#define R_BP(r)  ((r).ebp)
#define R_SP(r)  ((r).esp)
#define R_FL(r)  ((r).eflags)
#define R_IP(r)  ((r).eip)
#else
#error "bsdrun needs an x86 Linux host"
#endif

/* Linux i386 system call numbers. */
enum {
    L_read = 3, L_write = 4, L_open = 5, L_close = 6, L_unlink = 10,
    L_chdir = 12, L_getpid = 20, L_access = 33, L_kill = 37,
    L_rename = 38, L_mkdir = 39, L_rmdir = 40, L_brk = 45, L_ioctl = 54,
    L_getppid = 64, L_gettimeofday = 78, L_llseek = 140, L_mmap2 = 192,
    L_stat64 = 195, L_lstat64 = 196, L_fstat64 = 197, L_getuid32 = 199,
    L_exit_group = 252,
};

/* FreeBSD system call numbers (the 4.4BSD ones, which FreeBSD 3 and later
 * all have, with the old lseek, mmap and stat kept for compatibility). */
enum {
    B_exit = 1, B_read = 3, B_write = 4, B_open = 5, B_close = 6,
    B_unlink = 10, B_chdir = 12, B_break = 17, B_getpid = 20,
    B_getuid = 24, B_access = 33, B_kill = 37, B_getppid = 39,
    B_ioctl = 54, B_gettimeofday = 116, B_rename = 128, B_mkdir = 136,
    B_rmdir = 137, B_stat = 188, B_fstat = 189, B_lstat = 190,
    B_mmap = 197, B_lseek = 199,
};

enum { X_none, X_break, X_stat, X_lseek };

static int    verbose;
static pid_t  child;

static uint32_t peek32(uint32_t addr)
{
    errno = 0;
    long w = ptrace(PTRACE_PEEKDATA, child, (void *)(uintptr_t)(addr & ~3u), 0);
    if (addr & 3) {
        long w2 = ptrace(PTRACE_PEEKDATA, child, (void *)(uintptr_t)((addr & ~3u) + 4), 0);
        uint64_t both = (uint32_t)w | ((uint64_t)(uint32_t)w2 << 32);
        return (uint32_t)(both >> ((addr & 3) * 8));
    }
    return (uint32_t)w;
}

/* ptrace words are 8 bytes on an x86-64 host: read and write memory with
 * process_vm calls instead, which take any size. */
static int rmem(uint32_t addr, void *buf, size_t n)
{
    struct iovec l = { buf, n }, r = { (void *)(uintptr_t)addr, n };
    return process_vm_readv(child, &l, 1, &r, 1, 0) == (ssize_t)n ? 0 : -1;
}

static int wmem(uint32_t addr, const void *buf, size_t n)
{
    struct iovec l = { (void *)buf, n }, r = { (void *)(uintptr_t)addr, n };
    if (process_vm_writev(child, &l, 1, &r, 1, 0) == (ssize_t)n)
        return 0;
    /* Read-only pages: fall back to ptrace, a word at a time. */
    for (size_t i = 0; i < n; i += sizeof(long)) {
        long w = ptrace(PTRACE_PEEKDATA, child, (void *)(uintptr_t)(addr + i), 0);
        size_t k = n - i < sizeof(long) ? n - i : sizeof(long);
        memcpy(&w, (const char *)buf + i, k);
        if (ptrace(PTRACE_POKEDATA, child, (void *)(uintptr_t)(addr + i), (void *)w) < 0)
            return -1;
    }
    return 0;
}

/* Linux error numbers to BSD ones. 1 to 34 are the same but for 11. */
static uint32_t bsd_errno(int e)
{
    switch (e) {
    case 11: return 35;  /* EAGAIN */
    case 35: return 11;  /* EDEADLK */
    case 36: return 63;  /* ENAMETOOLONG */
    case 37: return 77;  /* ENOLCK */
    case 38: return 78;  /* ENOSYS */
    case 39: return 66;  /* ENOTEMPTY */
    case 40: return 62;  /* ELOOP */
    case 75: return 84;  /* EOVERFLOW */
    case 88: return 38;  /* ENOTSOCK */
    case 95: return 45;  /* EOPNOTSUPP */
    case 110: return 60; /* ETIMEDOUT */
    default: return e <= 34 ? (uint32_t)e : 22; /* else EINVAL */
    }
}

/* BSD open flags to Linux ones. */
static uint32_t open_flags(uint32_t f)
{
    uint32_t l = f & 3;          /* O_RDONLY, O_WRONLY, O_RDWR */
    if (f & 0x0004) l |= 04000;  /* O_NONBLOCK */
    if (f & 0x0008) l |= 02000;  /* O_APPEND */
    if (f & 0x0080) l |= 010000; /* O_SYNC (O_FSYNC) */
    if (f & 0x0200) l |= 0100;   /* O_CREAT */
    if (f & 0x0400) l |= 01000;  /* O_TRUNC */
    if (f & 0x0800) l |= 0200;   /* O_EXCL */
    if (f & 0x8000) l |= 0400;   /* O_NOCTTY */
    return l;
}

/* BSD signal numbers to Linux ones, for kill. */
static uint32_t linux_sig(uint32_t s)
{
    static const unsigned char map[32] = {
        0, 1, 2, 3, 4, 5, 6, 0 /* EMT */, 8, 9, 7 /* BUS */, 11, 31 /* SYS */,
        13, 14, 15, 23 /* URG */, 19 /* STOP */, 20 /* TSTP */, 18 /* CONT */,
        17 /* CHLD */, 21, 22, 29 /* IO */, 24, 25, 26, 27, 28 /* WINCH */,
        0 /* INFO */, 10 /* USR1 */, 12 /* USR2 */,
    };
    return s < 32 ? map[s] : 0;
}

enum { OS_FREEBSD, OS_NETBSD };
static int os = OS_FREEBSD;

/* NetBSD's __stat13 calls (compat_30 in NetBSD 3.0 and later). */
enum { N_stat = 278, N_fstat = 279, N_lstat = 280 };

/* Size of the BSD struct stat, which the Linux struct stat64 (96 bytes)
 * is written into first. */
#define BSD_STAT_SIZE (os == OS_NETBSD ? 100 : 96)

/* Linux struct stat64 (i386) to the BSD's struct stat, in place. */
static void stat_to_bsd(unsigned char *b)
{
    unsigned char l[96];
    memcpy(l, b, 96);
    memset(b, 0, BSD_STAT_SIZE);
#define G32(o) (*(uint32_t *)(l + (o)))
#define G64(o) (*(uint64_t *)(l + (o)))
#define P32(o, v) (*(uint32_t *)(b + (o)) = (uint32_t)(v))
#define P16(o, v) (*(uint16_t *)(b + (o)) = (uint16_t)(v))
#define P64(o, v) (*(uint64_t *)(b + (o)) = (uint64_t)(v))
    if (os == OS_NETBSD) {
        /* 32-bit mode and nlink, then everything 4 bytes on. */
        P32(0, G64(0));             /* st_dev */
        P32(4, G64(88));            /* st_ino */
        P32(8, G32(16));            /* st_mode */
        P32(12, G32(20));           /* st_nlink */
        P32(16, G32(24));           /* st_uid */
        P32(20, G32(28));           /* st_gid */
        P32(24, G64(32));           /* st_rdev */
        P32(28, G32(64)); P32(32, G32(68)); /* st_atimespec */
        P32(36, G32(72)); P32(40, G32(76)); /* st_mtimespec */
        P32(44, G32(80)); P32(48, G32(84)); /* st_ctimespec */
        P64(52, G64(44));           /* st_size */
        P64(60, G64(56));           /* st_blocks */
        P32(68, G32(52));           /* st_blksize */
        return;
    }
    P32(0, G64(0));                 /* st_dev */
    P32(4, G64(88));                /* st_ino */
    P16(8, G32(16));                /* st_mode */
    P16(10, G32(20));               /* st_nlink */
    P32(12, G32(24));               /* st_uid */
    P32(16, G32(28));               /* st_gid */
    P32(20, G64(32));               /* st_rdev */
    P32(24, G32(64)); P32(28, G32(68)); /* st_atimespec */
    P32(32, G32(72)); P32(36, G32(76)); /* st_mtimespec */
    P32(40, G32(80)); P32(44, G32(84)); /* st_ctimespec */
    P64(48, G64(44));               /* st_size */
    P64(56, G64(56));               /* st_blocks */
    P32(64, G32(52));               /* st_blksize */
}

/* FreeBSD programs say so in the ELF header; NetBSD ones have a
 * .note.netbsd.ident note. */
static int detect_os(const char *path)
{
    unsigned char buf[65536];
    FILE         *f = fopen(path, "rb");
    if (!f)
        return OS_FREEBSD;
    size_t n = fread(buf, 1, sizeof buf, f);
    fclose(f);
    if (n < 52 || memcmp(buf, "\177ELF", 4) != 0)
        return OS_FREEBSD;
    if (buf[7] == 9) /* ELFOSABI_FREEBSD */
        return OS_FREEBSD;
    uint32_t phoff = *(uint32_t *)(buf + 28);
    uint16_t phentsize = *(uint16_t *)(buf + 42), phnum = *(uint16_t *)(buf + 44);
    for (unsigned i = 0; i < phnum; i++) {
        size_t ph = phoff + (size_t)i * phentsize;
        if (ph + 32 > n || *(uint32_t *)(buf + ph) != 4) /* PT_NOTE */
            continue;
        uint32_t off = *(uint32_t *)(buf + ph + 4), sz = *(uint32_t *)(buf + ph + 16);
        for (uint32_t o = off; o + 12 <= off + sz && o + 12 <= n;) {
            uint32_t namesz = *(uint32_t *)(buf + o), descsz = *(uint32_t *)(buf + o + 4);
            if (namesz == 7 && o + 19 <= n && memcmp(buf + o + 12, "NetBSD", 7) == 0)
                return OS_NETBSD;
            o += 12 + ((namesz + 3) & ~3u) + ((descsz + 3) & ~3u);
        }
    }
    return OS_FREEBSD;
}

int main(int argc, char **argv)
{
    int a = 1;
    if (a < argc && strcmp(argv[a], "-v") == 0) {
        verbose = 1;
        a++;
    }
    if (a >= argc) {
        fprintf(stderr, "usage: bsdrun [-v] PROGRAM [ARGS...]\n");
        return 2;
    }

    os = detect_os(argv[a]);
    if (verbose)
        fprintf(stderr, "bsdrun: a %s program\n", os == OS_NETBSD ? "NetBSD" : "FreeBSD");
    child = fork();
    if (child < 0) {
        perror("fork");
        return 2;
    }
    if (child == 0) {
        /* No address randomization: the heap then starts right after the
         * bss, where a BSD kernel puts it, and break() can grow it. */
        personality(ADDR_NO_RANDOMIZE);
        ptrace(PTRACE_TRACEME, 0, 0, 0);
        raise(SIGSTOP);
        execv(argv[a], argv + a);
        perror(argv[a]);
        _exit(127);
    }

    int st;
    waitpid(child, &st, 0);
    ptrace(PTRACE_SETOPTIONS, child, 0,
           (void *)(long)(PTRACE_O_TRACESYSGOOD | PTRACE_O_EXITKILL | PTRACE_O_TRACEEXEC));

    int      started = 0, skip = 0, in_call = 0, extra = X_none, sig = 0;
    uint32_t bnr = 0, arg[8], scratch = 0;
    struct user_regs_struct saved;

    for (;;) {
        if (ptrace(PTRACE_SYSCALL, child, 0, (void *)(long)sig) < 0)
            break;
        sig = 0;
        if (waitpid(child, &st, 0) < 0)
            break;
        if (WIFEXITED(st))
            return WEXITSTATUS(st);
        if (WIFSIGNALED(st)) {
            fprintf(stderr, "bsdrun: program killed by signal %d\n", WTERMSIG(st));
            return 128 + WTERMSIG(st);
        }
        if (!WIFSTOPPED(st))
            continue;
        if (WSTOPSIG(st) == SIGTRAP && (st >> 16) == PTRACE_EVENT_EXEC) {
            /* The next stop is the way out of execve, a Linux call. */
            started = 1;
            skip = 1;
            continue;
        }
        if (WSTOPSIG(st) != (SIGTRAP | 0x80)) {
            sig = WSTOPSIG(st) == SIGTRAP ? 0 : WSTOPSIG(st);
            continue;
        }
        if (!started)
            continue; /* the execve itself */
        if (skip) {
            skip = 0;
            continue;
        }

        struct user_regs_struct r;
        ptrace(PTRACE_GETREGS, child, 0, &r);

        if (!in_call) {
            in_call = 1;
            extra = X_none;
            bnr = (uint32_t)R_NR(r);
            uint32_t sp = (uint32_t)R_SP(r);
            for (int i = 0; i < 8; i++)
                arg[i] = peek32(sp + 4 + 4 * i);
            long     nr = -1;
            uint32_t la[6] = { 0 };
            switch (bnr) {
            case B_exit: nr = L_exit_group; la[0] = arg[0]; break;
            case B_read: nr = L_read; goto three;
            case B_write: nr = L_write; goto three;
            case B_open:
                nr = L_open; la[0] = arg[0]; la[1] = open_flags(arg[1]); la[2] = arg[2];
                break;
            case B_close: nr = L_close; goto one;
            case B_unlink: nr = L_unlink; goto one;
            case B_chdir: nr = L_chdir; goto one;
            case B_break: nr = L_brk; la[0] = arg[0]; extra = X_break; break;
            case B_getpid: nr = L_getpid; break;
            case B_getuid: nr = L_getuid32; break;
            case B_getppid: nr = L_getppid; break;
            case B_access: nr = L_access; goto two;
            case B_kill: nr = L_kill; la[0] = arg[0]; la[1] = linux_sig(arg[1]); break;
            case B_ioctl:
                nr = L_ioctl; la[0] = arg[0]; la[1] = arg[1]; la[2] = arg[2];
                if (arg[1] == 0x402c7413) /* TIOCGETA, for isatty */
                    la[1] = 0x5401;       /* TCGETS */
                else
                    nr = -1;
                break;
            case B_gettimeofday: nr = L_gettimeofday; goto two;
            case B_rename: nr = L_rename; goto two;
            case B_mkdir: nr = L_mkdir; goto two;
            case B_rmdir: nr = L_rmdir; goto one;
            case B_stat: case N_stat:
                if ((bnr == B_stat) != (os == OS_FREEBSD))
                    break;
                nr = L_stat64; extra = X_stat; goto two;
            case B_lstat: case N_lstat:
                if ((bnr == B_lstat) != (os == OS_FREEBSD))
                    break;
                nr = L_lstat64; extra = X_stat; goto two;
            case B_fstat: case N_fstat:
                if ((bnr == B_fstat) != (os == OS_FREEBSD))
                    break;
                nr = L_fstat64; extra = X_stat; goto two;
            case B_lseek:
                /* lseek(fd, pad, off_t, whence) -> _llseek(fd, hi, lo, &res,
                 * whence), with the result below the program's stack. */
                scratch = (sp - 256) & ~7u;
                nr = L_llseek; la[0] = arg[0]; la[1] = arg[3]; la[2] = arg[2];
                la[3] = scratch; la[4] = arg[4]; extra = X_lseek;
                break;
            case B_mmap: {
                /* mmap(addr, len, prot, flags, fd, pad, off_t) */
                uint32_t f = arg[3], lf = f & 0x13; /* SHARED, PRIVATE, FIXED */
                if (f & 0x1000)
                    lf |= 0x20; /* MAP_ANON */
                nr = L_mmap2; la[0] = arg[0]; la[1] = arg[1]; la[2] = arg[2];
                la[3] = lf; la[4] = (f & 0x1000) ? (uint32_t)-1 : arg[4];
                la[5] = (uint32_t)(((uint64_t)arg[7] << 32 | arg[6]) >> 12);
                break;
            }
            default: break;
            three: la[2] = arg[2]; /* fall through */
            two: la[1] = arg[1];   /* fall through */
            one: la[0] = arg[0]; break;
            }
            saved = r;
            if (verbose)
                fprintf(stderr, "bsdrun: syscall %u(%#x, %#x, %#x, %#x)%s\n", bnr,
                        arg[0], arg[1], arg[2], arg[3], nr < 0 ? " not translated" : "");
            R_NR(r) = (unsigned long)nr;
            R_BX(r) = la[0]; R_CX(r) = la[1]; R_DX(r) = la[2];
            R_SI(r) = la[3]; R_DI(r) = la[4]; R_BP(r) = la[5];
            ptrace(PTRACE_SETREGS, child, 0, &r);
            /* Keep the registers the program passed for the way out. */
            continue;
        }

        in_call = 0;
        int32_t res = (int32_t)R_AX(r);
        uint32_t edx = 0;
        int      err = 0;
        if (res < 0 && res > -4096) {
            err = -res;
        } else {
            switch (extra) {
            case X_break:
                /* Linux's brk returns the break it now has. */
                if ((uint32_t)res < arg[0])
                    err = 12; /* ENOMEM */
                res = 0;
                break;
            case X_stat: {
                unsigned char b[100];
                uint32_t      p = arg[1];
                if (rmem(p, b, BSD_STAT_SIZE) == 0) {
                    stat_to_bsd(b);
                    wmem(p, b, BSD_STAT_SIZE);
                }
                break;
            }
            case X_lseek: {
                uint64_t off = 0;
                rmem(scratch, &off, 8);
                res = (int32_t)(uint32_t)off;
                edx = (uint32_t)(off >> 32);
                break;
            }
            }
        }
        if (err) {
            R_AX(r) = bsd_errno(err);
            R_FL(r) |= 1;
            if (verbose)
                fprintf(stderr, "bsdrun:   error %u\n", (unsigned)R_AX(r));
        } else {
            R_AX(r) = (uint32_t)res;
            R_DX(r) = edx;
            R_FL(r) &= ~1ul;
        }
        /* The other registers come back as the program left them. */
        R_IP(saved) = R_IP(r);
        R_NR(saved) = R_NR(r);
        R_AX(saved) = R_AX(r);
        R_DX(saved) = err ? R_DX(saved) : R_DX(r);
        R_FL(saved) = R_FL(r);
        ptrace(PTRACE_SETREGS, child, 0, &saved);
    }
    return 1;
}
