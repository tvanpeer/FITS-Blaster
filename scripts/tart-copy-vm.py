#!/usr/bin/env python3
"""tart-copy-vm.py — copy a Tart VM folder to another volume, keeping the disk image sparse.

A VM's disk.img is a 50–80 GB sparse file of which only 20–30 GB holds data. `ditto` writes
it out in full; `cp -Rp` keeps it sparse but checks every 4 KB block (about 0.6 MB/s). This
copies only the data regions (SEEK_DATA/SEEK_HOLE) in large chunks, at drive speed.
Keeps mode and times; skips sockets (Tart's control.sock is made again at the next start).

Shut the VM down first. Check the copy afterwards with `shasum -a 256` on both disk.img files.

Usage:
  scripts/tart-copy-vm.py <source VM folder> <destination VM folder>
  e.g. scripts/tart-copy-vm.py "/Volumes/FITS Blaster External/Tart/vms/fb-27" ~/Tart/vms/fb-27

The destination must not exist yet, and its parent folder must (so nothing is written
under /Volumes when a drive isn't connected).
"""
import os
import shutil
import stat
import sys
import time

CHUNK = 16 * 1024 * 1024


def copy_file(src, dst):
    """Copies the data regions of src to dst; returns the number of bytes copied."""
    st = os.stat(src)
    with open(src, "rb") as fin, open(dst, "xb") as fout:
        fi, fo = fin.fileno(), fout.fileno()
        size = st.st_size
        os.ftruncate(fo, size)
        pos = 0
        copied = 0
        while pos < size:
            try:
                data = os.lseek(fi, pos, os.SEEK_DATA)
            except OSError:  # no data after pos
                break
            hole = os.lseek(fi, data, os.SEEK_HOLE)
            off = data
            while off < hole:
                buf = os.pread(fi, min(CHUNK, hole - off), off)
                os.pwrite(fo, buf, off)
                off += len(buf)
                copied += len(buf)
            pos = hole
    os.chmod(dst, stat.S_IMODE(st.st_mode))
    os.utime(dst, ns=(st.st_atime_ns, st.st_mtime_ns))
    return copied


def copy_tree(src, dst):
    os.mkdir(dst)
    for name in sorted(os.listdir(src)):
        s, d = os.path.join(src, name), os.path.join(dst, name)
        mode = os.lstat(s).st_mode
        if stat.S_ISDIR(mode):
            copy_tree(s, d)
        elif stat.S_ISREG(mode):
            start = time.time()
            n = copy_file(s, d)
            print(f"{s}: {n / 2**30:.1f} GiB data in {time.time() - start:.0f}s", flush=True)
        elif stat.S_ISLNK(mode):
            os.symlink(os.readlink(s), d)
        else:
            print(f"skipped (not a regular file): {s}", flush=True)
    shutil.copystat(src, dst)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip())
    src, dst = (os.path.abspath(p) for p in sys.argv[1:])
    if not os.path.isdir(src):
        sys.exit(f"No VM folder: {src} (is the drive connected?)")
    if os.path.lexists(dst):
        sys.exit(f"Already exists: {dst}")
    if not os.path.isdir(os.path.dirname(dst)):
        sys.exit(f"No folder {os.path.dirname(dst)} (is the drive connected?)")
    copy_tree(src, dst)


if __name__ == "__main__":
    main()
