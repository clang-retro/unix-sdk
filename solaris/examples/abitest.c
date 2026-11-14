// Checks the code generator and the C library on Solaris: calls
// with mixed argument sizes, struct return, 64-bit, 128-bit and floating
// point arithmetic, varargs, setjmp, static constructors, malloc, files,
// directories, the command line and time. Prints one line per failure and
// a summary.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static int failures, checks;
#define CHECK(c)                                                               \
  do {                                                                         \
    ++checks;                                                                  \
    if (!(c)) {                                                                \
      ++failures;                                                              \
      printf("FAIL line %d: %s\n", __LINE__, #c);                              \
    }                                                                          \
  } while (0)

struct big { long a, b, c; short d; char e; };

__attribute__((noinline)) static struct big make_big(long x, short y, char z) {
  struct big b = {x, x * 2, x * 3, y, z};
  return b;
}

__attribute__((noinline)) static long mix(char a, short b, long c, long long d,
                                          double e, float f) {
  return a + b + c + (long)(d >> 32) + (long)e + (long)f;
}

static long sum(int n, ...) {
  va_list ap;
  long s = 0;
  va_start(ap, n);
  for (int i = 0; i < n; ++i)
    s += va_arg(ap, int);
  va_end(ap);
  return s;
}

static int ctor_ran;
__attribute__((constructor)) static void ctor(void) { ctor_ran = 42; }
// Runs at exit, after main's summary line.
__attribute__((destructor)) static void dtor(void) { puts("abitest: destructor ran"); }

static jmp_buf jb;
__attribute__((noinline)) static void jump(int v) { longjmp(jb, v); }

volatile long long v64 = 0x123456789abcdefLL;
volatile double vd = 2.5;
long data_word = 0x12345678;
char bss_buf[1000];

int main(int argc, char **argv) {
  CHECK(argc == 3 && !strcmp(argv[1], "one") && !strcmp(argv[2], "two words"));
  CHECK(argv[argc] == NULL);
  CHECK(getenv("ABITEST") && !strcmp(getenv("ABITEST"), "yes"));

  // Code generation.
  struct big b = make_big(1000, -5, 'x');
  CHECK(b.a == 1000 && b.b == 2000 && b.c == 3000 && b.d == -5 && b.e == 'x');
  CHECK(mix(1, 2, 3, 4LL << 32, 5.9, 6.5f) == 21);
  CHECK(sum(4, 10, 20, 30, 40) == 100);
  CHECK(v64 / 1000 == 81985529216486LL && v64 % 1000 == 895);
  CHECK((unsigned long long)v64 >> 40 == 0x12345);
  CHECK(vd * 4 == 10.0 && (int)(vd * vd * 100) == 625);
  CHECK(sizeof(long) == sizeof(void *));
#ifdef __SIZEOF_INT128__
  volatile __int128 w = (__int128)v64 * 1000000007;
  CHECK(w / 1000000007 == v64 && (unsigned long long)(w >> 64) == 0x43d11c);
#endif
  volatile long double ld = 1.0L / 3;
  CHECK(ld * 3 > 0.999999L && ld * 3 < 1.000001L);
  char fbuf[32];
  snprintf(fbuf, sizeof fbuf, "%.3f %g %e", 3.14159, 0.5, 12345.0);
  CHECK(!strcmp(fbuf, "3.142 0.5 1.234500e+04"));
  CHECK(ctor_ran == 42);
  CHECK(data_word == 0x12345678);
  int zero = 1;
  for (unsigned i = 0; i < sizeof bss_buf; ++i)
    zero &= bss_buf[i] == 0;
  CHECK(zero);
  int j = setjmp(jb);
  if (!j)
    jump(7);
  CHECK(j == 7);

  // malloc.
  char *p = malloc(100000);
  CHECK(p != NULL);
  if (p) {
    memset(p, 0x5a, 100000);
    p = realloc(p, 200000);
    CHECK(p && p[99999] == 0x5a);
    free(p);
  }

  // Files.
  FILE *f = fopen("abitest.txt", "w");
  CHECK(f != NULL);
  if (f) {
    fprintf(f, "line %d\nsecond line\n", 1);
    fclose(f);
  }
  f = fopen("abitest.txt", "a");
  CHECK(f != NULL);
  if (f) {
    fputs("third\n", f);
    fclose(f);
  }
  struct stat st;
  CHECK(stat("abitest.txt", &st) == 0 && st.st_size == 25 &&
        S_ISREG(st.st_mode));
  f = fopen("abitest.txt", "r");
  char line[64] = "";
  CHECK(f && fgets(line, sizeof line, f) && !strcmp(line, "line 1\n"));
  CHECK(f && fgets(line, sizeof line, f) && !strcmp(line, "second line\n"));
  CHECK(f && fgets(line, sizeof line, f) && !strcmp(line, "third\n"));
  CHECK(f && !fgets(line, sizeof line, f) && feof(f));
  if (f) {
    fseek(f, 5, SEEK_SET);
    CHECK(fgetc(f) == '1' && ftell(f) == 6);
    fclose(f);
  }
  CHECK(fopen("nosuch.txt", "r") == NULL && errno == ENOENT);
  CHECK(mkdir("abidir", 0777) == 0);
  CHECK(stat("abidir", &st) == 0 && S_ISDIR(st.st_mode));
  CHECK(rename("abitest.txt", "abidir/moved.txt") == 0);
  CHECK(chdir("abidir") == 0);
  CHECK(access("moved.txt", R_OK) == 0);
  CHECK(remove("moved.txt") == 0);
  CHECK(chdir("..") == 0);
  CHECK(rmdir("abidir") == 0);
  CHECK(stat("abidir", &st) == -1 && errno == ENOENT);

  // Time.
  time_t t = time(NULL);
  CHECK(t > 946684800); // after 2000
  struct timeval tv;
  CHECK(gettimeofday(&tv, NULL) == 0 && tv.tv_sec >= t && tv.tv_usec < 1000000);
  CHECK(getpid() > 0);

  // Low-level I/O and errors.
  int fd = open("abitest.bin", O_WRONLY | O_CREAT | O_TRUNC, 0644);
  CHECK(fd >= 0 && write(fd, "0123456789", 10) == 10);
  CHECK(lseek(fd, 0, SEEK_END) == 10 && close(fd) == 0);
  CHECK(open("abitest.bin", O_WRONLY | O_CREAT | O_EXCL, 0644) == -1 && errno == EEXIST);
  fd = open("abitest.bin", O_RDONLY);
  char nb[4] = "";
  CHECK(fd >= 0 && lseek(fd, 6, SEEK_SET) == 6 && read(fd, nb, 4) == 4 && !memcmp(nb, "6789", 4));
  CHECK(fstat(fd, &st) == 0 && st.st_size == 10 && !isatty(fd));
  close(fd);
  CHECK(unlink("abitest.bin") == 0 && unlink("abitest.bin") == -1 && errno == ENOENT);
  CHECK(close(1000) == -1 && errno == EBADF);

  fprintf(stderr, "stderr works\n");
  printf("abitest: %d checks, %d failures\n", checks, failures);
  return failures != 0;
}
