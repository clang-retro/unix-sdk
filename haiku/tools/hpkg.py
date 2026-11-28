#!/usr/bin/env python3
# hpkg.py - extracts Haiku package files (.hpkg) on a host that is not Haiku.
#
# Usage: hpkg.py list PACKAGE
#        hpkg.py extract [--map FROM=TO]... PACKAGE DIRECTORY [PREFIX...]
#        hpkg.py resolve REPO NAME...
#
# "resolve" reads a repository index file (the "repo" file of a Haiku
# package repository) and writes the file name of the newest package with
# each NAME, one on each line.
#
# "extract" writes the files, directories and symbolic links of the package
# into DIRECTORY. When you give PREFIX values, it writes only the entries
# whose path starts with one of them (for example "develop/headers").
# --map moves the entries whose path starts with FROM to TO instead (for
# example "lib/x86=lib", which puts the libraries of Haiku's secondary
# x86 architecture where those of the primary one go). Symbolic links
# that point into a moved directory are changed to match.
#
# The format is version 2 of the Haiku package format. The heap is in
# chunks of 64 KiB, compressed with zlib or zstd. zstd needs the Python
# module "zstandard".
#
# Part of clang-retro unix-sdk.
# SPDX-License-Identifier: AGPL-3.0-only
import os
import struct
import sys
import zlib

ATTR_DIRECTORY_ENTRY = 0
ATTR_FILE_TYPE = 1
ATTR_FILE_PERMISSIONS = 2
ATTR_DATA = 13
ATTR_SYMLINK_PATH = 14

TYPE_INT, TYPE_UINT, TYPE_STRING, TYPE_RAW = 1, 2, 3, 4
FILE_TYPE_FILE, FILE_TYPE_DIRECTORY, FILE_TYPE_SYMLINK = 0, 1, 2


class Heap:
    """Gives access to the uncompressed bytes of the package heap."""

    def __init__(self, data, offset, compression, chunk_size, compressed_size, size):
        """Reads the chunk table at the end of the compressed heap."""
        self.data = data
        self.offset = offset
        self.compression = compression
        self.chunk_size = chunk_size
        self.size = size
        count = (size + chunk_size - 1) // chunk_size
        table_size = (count - 1) * 2
        table_at = offset + compressed_size - table_size
        sizes = [struct.unpack_from(">H", data, table_at + 2 * i)[0] + 1 for i in range(count - 1)]
        used = sum(sizes)
        sizes.append(compressed_size - table_size - used)
        self.starts = []
        at = offset
        for s in sizes:
            self.starts.append((at, s))
            at += s
        self.cache = {}

    def chunk(self, index):
        """Returns the uncompressed bytes of one chunk."""
        if index in self.cache:
            return self.cache[index]
        at, length = self.starts[index]
        want = min(self.chunk_size, self.size - index * self.chunk_size)
        raw = self.data[at:at + length]
        if length == want:
            out = raw
        elif self.compression == 1:
            out = zlib.decompress(raw)
        elif self.compression == 2:
            import zstandard
            out = zstandard.ZstdDecompressor().decompress(raw, max_output_size=want)
        else:
            raise ValueError("unknown heap compression %d" % self.compression)
        if len(self.cache) > 64:
            self.cache.clear()
        self.cache[index] = out
        return out

    def read(self, offset, length):
        """Returns length uncompressed bytes from offset in the heap."""
        parts = []
        while length > 0:
            index, inside = divmod(offset, self.chunk_size)
            c = self.chunk(index)[inside:inside + length]
            parts.append(c)
            offset += len(c)
            length -= len(c)
        return b"".join(parts)


def uleb(buf, at):
    """Decodes an unsigned LEB128 number. Returns the value and the next offset."""
    value, shift = 0, 0
    while True:
        b = buf[at]
        at += 1
        value |= (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            return value, at


class Package:
    """Reads the table of contents of a package file."""

    def __init__(self, path):
        """Reads the header, the heap and the table of contents."""
        with open(path, "rb") as f:
            self.data = f.read()
        d = self.data
        if d[:4] != b"hpkg":
            raise ValueError("%s is not a Haiku package" % path)
        header_size, version = struct.unpack_from(">HH", d, 4)
        if version != 2:
            raise ValueError("package format version %d is not supported" % version)
        (_total, _minor, compression, chunk_size, heap_compressed, heap_size,
         attr_length, _attr_strings, _attr_count, _reserved, toc_length,
         toc_strings_length, toc_strings_count) = struct.unpack_from(">QHHIQQIIIIQQQ", d, 8)
        self.heap = Heap(d, header_size, compression, chunk_size, heap_compressed, heap_size)
        toc_at = heap_size - attr_length - toc_length
        toc = self.heap.read(toc_at, toc_length)
        self.strings = []
        at = 0
        for _ in range(toc_strings_count):
            end = toc.index(b"\0", at)
            self.strings.append(toc[at:end].decode("utf-8", "surrogateescape"))
            at = end + 1
        self.toc = toc
        self.at = toc_strings_length

    def attribute(self):
        """Decodes one attribute. Returns None at the end of a list."""
        tag, self.at = uleb(self.toc, self.at)
        if tag == 0:
            return None
        # The tag, less one, holds the ID in bits 0 to 6, the type in bits
        # 7 to 9, the "has children" flag in bit 10 and the encoding from
        # bit 11.
        tag -= 1
        ident = tag & 0x7F
        kind = (tag >> 7) & 7
        children = (tag >> 10) & 1
        encoding = tag >> 11
        toc = self.toc
        if kind in (TYPE_INT, TYPE_UINT):
            n = 1 << encoding
            fmt = {1: "b", 2: "h", 4: "i", 8: "q"}[n]
            if kind == TYPE_UINT:
                fmt = fmt.upper()
            value = struct.unpack_from(">" + fmt, toc, self.at)[0]
            self.at += n
        elif kind == TYPE_STRING:
            if encoding == 0:
                end = toc.index(b"\0", self.at)
                value = toc[self.at:end].decode("utf-8", "surrogateescape")
                self.at = end + 1
            else:
                index, self.at = uleb(toc, self.at)
                value = self.strings[index]
        elif kind == TYPE_RAW:
            # Encoding 0 keeps the bytes in the table of contents, 1 in
            # the heap.
            size, self.at = uleb(toc, self.at)
            if encoding == 1:
                offset, self.at = uleb(toc, self.at)
                value = ("heap", offset, size)
            else:
                value = ("inline", bytes(toc[self.at:self.at + size]))
                self.at += size
        else:
            raise ValueError("unknown attribute type %d" % kind)
        return ident, value, children

    def skip_children(self):
        """Skips the children of the attribute just read."""
        while True:
            a = self.attribute()
            if a is None:
                return
            if a[2]:
                self.skip_children()

    def entries(self):
        """Yields (path, type, permissions, data, link) for each entry."""
        while True:
            a = self.attribute()
            if a is None:
                return
            ident, value, children = a
            if ident == ATTR_DIRECTORY_ENTRY:
                for e in self.child("", value, children):
                    yield e
            elif children:
                self.skip_children()

    def child(self, parent, name, children):
        """Reads one child entry. Returns the list of entries in it."""
        path = parent + "/" + name if parent else name
        entry = {"type": FILE_TYPE_FILE, "mode": None, "data": None, "link": None}
        subdirs = []
        if children:
            while True:
                b = self.attribute()
                if b is None:
                    break
                bid, bval, bchildren = b
                if bid == ATTR_DIRECTORY_ENTRY:
                    subdirs.append(self.child(path, bval, bchildren))
                    continue
                if bid == ATTR_FILE_TYPE:
                    entry["type"] = bval
                elif bid == ATTR_FILE_PERMISSIONS:
                    entry["mode"] = bval
                elif bid == ATTR_DATA:
                    entry["data"] = bval
                elif bid == ATTR_SYMLINK_PATH:
                    entry["link"] = bval
                if bchildren:
                    self.skip_children()
        out = [(path, entry["type"], entry["mode"], entry["data"], entry["link"])]
        for s in subdirs:
            out.extend(s)
        return out

    def content(self, data):
        """Returns the bytes of a file's data attribute."""
        if data is None:
            return b""
        if data[0] == "inline":
            return data[1]
        return self.heap.read(data[1], data[2])


ARCHITECTURES = {0: "any", 1: "x86", 2: "x86_gcc2", 3: "source", 4: "x86_64"}
ATTR_PACKAGE = 54
ATTR_NAME = 15
ATTR_ARCHITECTURE = 21
ATTR_VERSION_MAJOR = 22
ATTR_VERSION_MINOR = 23
ATTR_VERSION_MICRO = 24
ATTR_VERSION_REVISION = 25
ATTR_VERSION_PRE_RELEASE = 36


class Repository(Package):
    """Reads the package list of a repository index file (format "hpkr")."""

    def __init__(self, path):
        """Reads the header, the heap and the package section."""
        with open(path, "rb") as f:
            d = f.read()
        if d[:4] != b"hpkr":
            raise ValueError("%s is not a Haiku repository index" % path)
        header_size, version = struct.unpack_from(">HH", d, 4)
        if version != 2:
            raise ValueError("repository format version %d is not supported" % version)
        (_total, _minor, compression, chunk_size, heap_compressed, heap_size,
         info_length, _reserved, packages_length, strings_length,
         strings_count) = struct.unpack_from(">QHHIQQIIQQQ", d, 8)
        self.heap = Heap(d, header_size, compression, chunk_size, heap_compressed, heap_size)
        section = self.heap.read(info_length, packages_length)
        self.strings = []
        at = 0
        for _ in range(strings_count):
            end = section.index(b"\0", at)
            self.strings.append(section[at:end].decode("utf-8", "surrogateescape"))
            at = end + 1
        self.toc = section
        self.at = strings_length

    def packages(self):
        """Yields (name, version tuple, file name) for each package."""
        while True:
            a = self.attribute()
            if a is None:
                return
            if a[0] != ATTR_PACKAGE or not a[2]:
                if a[2]:
                    self.skip_children()
                continue
            info = {}
            while True:
                b = self.attribute()
                if b is None:
                    break
                bid, bval, bchildren = b
                if bid == ATTR_VERSION_MAJOR and bchildren and "major" not in info:
                    info["major"] = bval
                    while True:
                        c = self.attribute()
                        if c is None:
                            break
                        info[c[0]] = c[1]
                        if c[2]:
                            self.skip_children()
                    continue
                if bid in (ATTR_NAME, ATTR_ARCHITECTURE) and bid not in info:
                    info[bid] = bval
                if bchildren:
                    self.skip_children()
            name = info.get(ATTR_NAME)
            if name is None:
                continue
            text = str(info.get("major", ""))
            for part in (ATTR_VERSION_MINOR, ATTR_VERSION_MICRO):
                if part in info:
                    text += "." + str(info[part])
            if ATTR_VERSION_PRE_RELEASE in info:
                text += "~" + str(info[ATTR_VERSION_PRE_RELEASE])
            revision = info.get(ATTR_VERSION_REVISION, 0)
            arch = ARCHITECTURES.get(info.get(ATTR_ARCHITECTURE, 0), "any")
            key = tuple(version_key(str(info.get(k, ""))) for k in ("major", ATTR_VERSION_MINOR, ATTR_VERSION_MICRO)) + (revision,)
            yield name, key, "%s-%s-%d-%s.hpkg" % (name, text, revision, arch)


def version_key(text):
    """Turns a version part into a key that sorts numbers as numbers."""
    import re
    return tuple(int(p) if p.isdigit() else p for p in re.findall(r"\d+|[^\d]+", text))


def remap(path, maps):
    """Moves a package path by the first --map whose FROM starts it."""
    for old, new in maps:
        if path == old or path.startswith(old + "/"):
            rest = path[len(old):].lstrip("/")
            return os.path.join(new, rest) if rest else new
    return path


def main(argv):
    """Runs the list, extract or resolve command."""
    maps = []
    while len(argv) > 3 and argv[2] == "--map":
        old, _, new = argv[3].partition("=")
        maps.append((old.strip("/"), new.strip("/")))
        argv = argv[:2] + argv[4:]
    if len(argv) >= 4 and argv[1] == "resolve":
        best = {}
        for name, key, filename in Repository(argv[2]).packages():
            if name in argv[3:] and (name not in best or key > best[name][0]):
                best[name] = (key, filename)
        for name in argv[3:]:
            if name not in best:
                sys.stderr.write("no package named %s\n" % name)
                return 1
            print(best[name][1])
        return 0
    if len(argv) < 3 or argv[1] not in ("list", "extract"):
        sys.stderr.write(__doc__ if __doc__ else "usage: hpkg.py list|extract PACKAGE [DIRECTORY [PREFIX...]]\n")
        return 2
    pkg = Package(argv[2])
    if argv[1] == "list":
        for path, kind, _mode, data, link in pkg.entries():
            mark = {FILE_TYPE_DIRECTORY: "/", FILE_TYPE_SYMLINK: " -> " + str(link)}.get(kind, "")
            print(path + mark)
        return 0
    if len(argv) < 4:
        sys.stderr.write("extract needs a directory\n")
        return 2
    root = argv[3]
    prefixes = argv[4:]
    for path, kind, mode, data, link in pkg.entries():
        if prefixes and not any(path == p or path.startswith(p.rstrip("/") + "/") for p in prefixes):
            continue
        new = remap(path, maps)
        if kind == FILE_TYPE_SYMLINK and not link.startswith("/"):
            # The link's target, as a path in the package, moved the
            # same way, and then relative to the link's new place.
            old_target = os.path.normpath(os.path.join(os.path.dirname(path), link))
            link = os.path.relpath(remap(old_target, maps), os.path.dirname(new) or ".")
        path = new
        target = os.path.join(root, path)
        if kind == FILE_TYPE_DIRECTORY:
            os.makedirs(target, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if os.path.lexists(target):
            os.remove(target)
        if kind == FILE_TYPE_SYMLINK:
            os.symlink(link, target)
            continue
        with open(target, "wb") as f:
            f.write(pkg.content(data))
        if mode is not None:
            os.chmod(target, mode & 0o7777)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
