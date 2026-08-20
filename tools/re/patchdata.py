#!/usr/bin/env python3
"""Recover a version's real data tables out of its patch installer.

The installers ship the tables as Ptc deltas over the expansion base, stored under BARE filenames
("skills.bin", not "data\\global\\excel\\skills.bin"). Member names are hashed and the (listfile)
is stripped, so the names cannot be listed -- only guessed and confirmed. That is why this carries
a table-name dictionary instead of enumerating.

usage: patchdata.py <installer.exe> <base-archive.mpq>[,<more.mpq>] <outdir>
env:   MPQCAT, D2PATCH  (default ./zig-out/bin/{mpqcat,d2patch})
"""
import io, os, struct, subprocess, sys, zlib

MPQCAT = os.environ.get('MPQCAT', './zig-out/bin/mpqcat')
D2PATCH = os.environ.get('D2PATCH', './zig-out/bin/d2patch')

_ct = [0] * 0x500
_s = 0x00100001
for _i in range(0x100):
    for _j in range(_i, 0x500, 0x100):
        _s = (_s * 125 + 3) % 0x2AAAAB; _a = (_s & 0xFFFF) << 16
        _s = (_s * 125 + 3) % 0x2AAAAB; _ct[_j] = _a | (_s & 0xFFFF)

def mpq_hash(s, ty):
    s = s.upper().replace('/', '\\')
    s1, s2 = 0x7FED7FED, 0xEEEEEEEE
    for ch in s.encode('latin-1'):
        s1 = (_ct[(ty << 8) + ch] ^ ((s1 + s2) & 0xFFFFFFFF)) & 0xFFFFFFFF
        s2 = (ch + s1 + s2 + (s2 << 5) + 3) & 0xFFFFFFFF
    return s1

def mpq_decrypt(data, key):
    out = bytearray(); s2 = 0xEEEEEEEE
    for i in range(0, len(data) - 3, 4):
        s2 = (s2 + _ct[0x400 + (key & 0xFF)]) & 0xFFFFFFFF
        v = struct.unpack_from('<I', data, i)[0]
        d = (v ^ ((key + s2) & 0xFFFFFFFF)) & 0xFFFFFFFF
        out += struct.pack('<I', d)
        key = (((~key) << 0x15) + 0x11111111 | (key >> 0x0B)) & 0xFFFFFFFF
        s2 = (d + s2 + (s2 << 5) + 3) & 0xFFFFFFFF
    return bytes(out)

def carve(exe_path, out_path):
    """The appended archive is the MPQ header whose size field lands exactly on EOF."""
    d = io.open(exe_path, 'rb').read()
    best, i = None, 0
    while True:
        i = d.find(b'MPQ\x1a', i)
        if i < 0: break
        if struct.unpack_from('<I', d, i + 4)[0] == 32 and i + struct.unpack_from('<I', d, i + 8)[0] == len(d):
            best = i
        i += 1
    if best is None: raise SystemExit(f'no appended archive in {exe_path}')
    io.open(out_path, 'wb').write(d[best:])
    return best, len(d) - best

def members(mpq_path):
    d = io.open(mpq_path, 'rb').read()
    _, _hsz, _asz, _fmt, _bs, htpos, btpos, hsize, bsize = struct.unpack_from('<4sIIHHIIII', d, 0)
    ht = mpq_decrypt(d[htpos:htpos + hsize * 16], mpq_hash('(hash table)', 3))
    present = set()
    for i in range(hsize):
        n1, n2, _loc, _plat, blk = struct.unpack_from('<IIHHI', ht, i * 16)
        if blk < 0xFFFFFFFE: present.add((n1, n2))
    return present, bsize

TABLES = """actinfo arena armor armtype automagic automap belts bodylocs books charstats chartemplate
colors compcode composit cubemain cubemod cubetype difficultylevels elemtypes events experience gamble
gems hireling hirelingdesc hiredesc hitclass inventory itemratio itemstatcost itemtypes levels
lowqualityitems lvlmaze lvlprest lvlsub lvltypes lvlwarp magicprefix magicsuffix misc missilecalc
missiles monai monequip monitempercent monlvl monmode monplace monpreset monprop monseq monsounds
monstats monstats2 montype monumod npc objects objgroup objmode objpreset objtype overlay pettype
playerclass plrmode plrtype properties qualityitems rareprefix raresuffix runes setitems sets shrines
skilldesc skills soundenviron sounds states storepage superuniques treasureclass treasureclassex
uniqueappellation uniqueitems uniqueprefix uniquesuffix uniquetitle wanderingmon weapons""".split()

def record_src_crc(path):
    """The record header's srcCRC32, or None for a full-file record (which needs no base)."""
    h = io.open(path, 'rb').read(8)
    if len(h) < 8: return None
    kind = struct.unpack_from('<H', h, 2)[0]
    if kind & 0x0100: return None
    return struct.unpack_from('<I', h, 4)[0]

def main():
    if len(sys.argv) != 4: raise SystemExit(__doc__)
    installer, bases, outdir = sys.argv[1], sys.argv[2].split(','), sys.argv[3]
    os.makedirs(outdir, exist_ok=True)
    work = os.path.join(outdir, '.patchdata')
    os.makedirs(work, exist_ok=True)
    arc = os.path.join(work, 'patch.mpq')
    off, size = carve(installer, arc)
    present, nblocks = members(arc)
    print(f'archive at 0x{off:x}, {size:,} bytes, {len(present)} members ({nblocks} blocks)')

    names = [f'{t}.{e}' for t in TABLES for e in ('txt', 'bin')]
    hits = [n for n in names if (mpq_hash(n, 1), mpq_hash(n, 2)) in present]
    print(f'{len(hits)} data members named')

    ok, failed = 0, []
    for n in hits:
        delta = os.path.join(work, n)
        if subprocess.call([MPQCAT, arc, n, delta], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
            failed.append(f'{n}(extract)'); continue
        # Try every archive and keep the one whose CRC the record actually wants. Stopping at the
        # first archive that merely HAS the file is wrong: the same name lives in more than one, at
        # different patch levels, and the older copy is a valid-looking base that produces garbage.
        base = os.path.join(work, 'base_' + n)
        want = record_src_crc(delta)
        got = False
        for b in bases:
            if subprocess.call([MPQCAT, b, f'data\\global\\excel\\{n}', base],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
                continue
            if want is None or zlib.crc32(io.open(base, 'rb').read()) & 0xFFFFFFFF == want:
                got = True
                break
        # Records come in two kinds. 0x0004 is a delta and needs the base it was cut against; 0x0104
        # carries the whole file and declares srcSize 0, so it applies against nothing. A version
        # that adds a table ships it whole, which is why the base lookup legitimately misses.
        if not got:
            base = os.path.join(work, '.empty')
            io.open(base, 'wb').close()
        # Verify the base against the record's own srcCRC32 before applying. `d2patch apply` reads
        # that field but does not check it, so a same-size wrong base would otherwise reconstruct
        # silent garbage -- and a table full of plausible garbage is far worse than a hard failure.
        if want is not None and not got:
            failed.append(f'{n}(badbase)'); continue
        if subprocess.call([D2PATCH, 'apply', delta, base, os.path.join(outdir, n)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0:
            ok += 1
        else:
            failed.append(f'{n}({"nobase" if not got else "apply"})')
    print(f'rebuilt {ok}, failed {len(failed)}')
    if failed: print('  ' + ' '.join(failed))

if __name__ == '__main__':
    main()
