#!/usr/bin/env python3
"""Validate a .d2s character save.

A save carries its own length and checksum in its header, which means a corrupted one can be
caught without anything to compare it against. That matters because the realm's own tests could
not: a cache that truncated saves to 1024 bytes ran a full stress pass reporting every round
clean, and was only found by measuring bytes against the durable copy by hand.

Header (little-endian):
  0x00 u32 magic     0xAA55AA55
  0x04 u32 version
  0x08 u32 filesize  the save's own idea of how long it is
  0x0c u32 checksum  computed over the whole file with these four bytes zeroed

Usage:
  checksave.py <file>...          validate each file
  checksave.py --stdin <name>     validate bytes on stdin (for redis blobs)

Exits non-zero if any save is bad, and says which check failed.
"""
import sys

MAGIC = 0xAA55AA55


def checksum(data: bytes) -> int:
    """D2's rotate-and-add checksum, with the checksum field itself read as zero."""
    acc = 0
    for i, b in enumerate(data):
        if 12 <= i < 16:
            b = 0
        carry = (acc >> 31) & 1
        acc = ((acc << 1) & 0xFFFFFFFF) | carry
        acc = (acc + b) & 0xFFFFFFFF
    return acc


def u32(data: bytes, off: int) -> int:
    return int.from_bytes(data[off:off + 4], "little")


def check(name: str, data: bytes) -> list[str]:
    problems = []
    if len(data) < 16:
        return [f"too short to be a save ({len(data)} bytes)"]
    if u32(data, 0) != MAGIC:
        problems.append(f"bad magic 0x{u32(data, 0):08x}, expected 0x{MAGIC:08x}")
    declared = u32(data, 8)
    # A record with no length and no checksum was never finalised by the game — the realm can
    # create one (char creation, the e2e fixtures) and the game fills the header in on first play.
    # That is a different condition from a save that WAS complete and has since been damaged, and
    # conflating the two would bury the second in a pile of the first.
    if declared == 0 and u32(data, 12) == 0:
        return ["STUB"]
    # The check that catches truncation: the save says how long it should be.
    if declared != len(data):
        problems.append(f"declared {declared} bytes but is {len(data)} — TRUNCATED or padded")
    want = u32(data, 12)
    got = checksum(data)
    if want != got:
        problems.append(f"checksum 0x{want:08x} but computes 0x{got:08x} — bytes altered")
    return problems


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    bad = 0
    if args[0] == "--stdin":
        name = args[1] if len(args) > 1 else "<stdin>"
        problems = check(name, sys.stdin.buffer.read())
        if problems == ["STUB"]:
            print(f"stub {name}: header never finalised (not yet played)")
            return 0
        if problems:
            bad = 1
            for p in problems:
                print(f"BAD  {name}: {p}")
        else:
            print(f"ok   {name}")
        return bad
    for path in args:
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError as e:
            print(f"BAD  {path}: {e}")
            bad = 1
            continue
        problems = check(path, data)
        if problems == ["STUB"]:
            print(f"stub {path}: header never finalised (not yet played)")
            continue
        if problems:
            bad = 1
            for p in problems:
                print(f"BAD  {path}: {p}")
        else:
            print(f"ok   {path} ({len(data)} bytes)")
    return bad


if __name__ == "__main__":
    sys.exit(main())
