// The smallest IRIX program: prints a line with printf and exits.
#include <stdio.h>

int main(int argc, char **argv) {
  printf("Hello, world from %s! %d %ld %.2f\n", argc > 0 ? argv[0] : "?", 42,
         123456789L, 3.25);
  return 0;
}
