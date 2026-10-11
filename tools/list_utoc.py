"""List package paths stored in an IoStore .utoc directory index.

Usage: python -I list_utoc.py <file.utoc> [substring-filter ...]
Read-only; finds the index by its "../../../" mount point instead of
walking the whole TOC header, so it survives minor format changes.
"""
import struct
import sys


def read_fstring(buf, pos):
    (n,) = struct.unpack_from("<i", buf, pos)
    pos += 4
    if n == 0:
        return "", pos
    if n < 0:
        raw = buf[pos:pos + (-n) * 2]
        return raw.decode("utf-16-le").rstrip("\0"), pos + (-n) * 2
    raw = buf[pos:pos + n]
    return raw.decode("latin-1").rstrip("\0"), pos + n


def parse_index(buf, pos):
    mount, pos = read_fstring(buf, pos)
    (ndirs,) = struct.unpack_from("<i", buf, pos)
    pos += 4
    dirs = [struct.unpack_from("<4I", buf, pos + i * 16) for i in range(ndirs)]
    pos += ndirs * 16
    (nfiles,) = struct.unpack_from("<i", buf, pos)
    pos += 4
    files = [struct.unpack_from("<3I", buf, pos + i * 12) for i in range(nfiles)]
    pos += nfiles * 12
    (nstr,) = struct.unpack_from("<i", buf, pos)
    pos += 4
    strings = []
    for _ in range(nstr):
        s, pos = read_fstring(buf, pos)
        strings.append(s)
    return mount, dirs, files, strings


def walk(dirs, files, strings, d, prefix, out):
    none = 0xFFFFFFFF
    while d != none:
        name_i, child, sibling, first_file = dirs[d]
        name = strings[name_i] if name_i != none else ""
        path = prefix + name + "/" if name else prefix
        f = first_file
        while f != none:
            fname_i, nxt, _user = files[f]
            out.append(path + strings[fname_i])
            f = nxt
        if child != none:
            walk(dirs, files, strings, child, path, out)
        d = sibling


def main():
    buf = open(sys.argv[1], "rb").read()
    filters = [f.lower() for f in sys.argv[2:]]
    marker = struct.pack("<i", 10) + b"../../../\0"
    pos = buf.find(marker)
    if pos < 0:
        sys.exit("no directory index found (container may be encrypted)")
    mount, dirs, files, strings = parse_index(buf, pos)
    out = []
    walk(dirs, files, strings, 0, mount, out)
    for p in out:
        if not filters or any(f in p.lower() for f in filters):
            print(p)


if __name__ == "__main__":
    main()
