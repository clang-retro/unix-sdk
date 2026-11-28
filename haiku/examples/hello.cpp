// hello.cpp - a small Haiku program: C++ (libstdc++), the C library, and
// a call into libbe (BString), to check the sysroot.
//
// Part of clang-retro unix-sdk.
// SPDX-License-Identifier: AGPL-3.0-only
#include <String.h>
#include <stdio.h>

#include <string>
#include <vector>

// Writes a line with each part of the toolchain and returns 0 when the
// results are correct.
int main() {
  std::vector<std::string> words = {"Hello", "from", "clang"};
  std::string line;
  for (const std::string& w : words) line += (line.empty() ? "" : " ") + w;
  BString be(line.c_str());
  be << " on Haiku";
  printf("%s\n", be.String());
  return be.Length() == 25 ? 0 : 1;
}
