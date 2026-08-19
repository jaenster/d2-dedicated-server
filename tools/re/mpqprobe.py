#!/usr/bin/env python3
"""Ask an MPQ whether it holds a member, by name hash.

Member names are not stored — only hashes — so an archive cannot be listed, it can only
be interrogated. That is why extracting these patches recovered ~20 of ~100 members: the
extractor could only name what someone thought to try.
"""
import struct, sys

def crypt_table():
    t = {}; seed = 0x00100001
    for i in range(0x100):
        for j in range(5):
            seed = (seed * 125 + 3) % 0x2AAAAB
            a = (seed & 0xFFFF) << 0x10
            seed = (seed * 125 + 3) % 0x2AAAAB
            b = (seed & 0xFFFF)
            t[i + j * 0x100] = (a | b)
    return t
CT = crypt_table()

def hash_str(s, kind):
    s = s.upper().encode('latin1')
    seed1, seed2 = 0x7FED7FED, 0xEEEEEEEE
    for ch in s:
        v = CT[(kind * 0x100) + ch]
        seed1 = (v ^ (seed1 + seed2)) & 0xFFFFFFFF
        seed2 = (ch + seed1 + seed2 + (seed2 << 5) + 3) & 0xFFFFFFFF
    return seed1

def decrypt(data, key):
    out = bytearray(); seed2 = 0xEEEEEEEE
    for i in range(0, len(data) - len(data) % 4, 4):
        seed2 = (seed2 + CT[0x400 + (key & 0xFF)]) & 0xFFFFFFFF
        v = struct.unpack_from('<I', data, i)[0]
        ch = v ^ ((key + seed2) & 0xFFFFFFFF)
        out += struct.pack('<I', ch)
        key = (((~key << 0x15) + 0x11111111) | (key >> 0x0B)) & 0xFFFFFFFF
        seed2 = (ch + seed2 + (seed2 << 5) + 3) & 0xFFFFFFFF
    return bytes(out)

class Mpq:
    def __init__(self, path):
        d = open(path, 'rb').read()
        self.d = d
        magic, hsize, asize, fmt, bshift, hpos, bpos, hsz, bsz = struct.unpack_from('<4sIIHHIIII', d, 0)
        self.hsz = hsz
        ht = decrypt(d[hpos:hpos + hsz * 16], hash_str("(hash table)", 3))
        self.hash = [struct.unpack_from('<IIHHI', ht, i * 16) for i in range(hsz)]
        bt = decrypt(d[bpos:bpos + bsz * 16], hash_str("(block table)", 3))
        self.block = [struct.unpack_from('<IIII', bt, i * 16) for i in range(bsz)]

    def has(self, name):
        i = hash_str(name, 0) % self.hsz
        a, b = hash_str(name, 1), hash_str(name, 2)
        for n in range(self.hsz):
            e = self.hash[(i + n) % self.hsz]
            if e[4] == 0xFFFFFFFF: return None
            if e[0] == a and e[1] == b and e[4] < len(self.block):
                return self.block[e[4]][2]   # uncompressed size
        return None

if __name__ == '__main__':
    m = Mpq(sys.argv[1])
    names = sys.argv[2:]
    found = 0
    for n in names:
        sz = m.has(n)
        if sz is not None:
            print(f'   {n}  ({sz} bytes)')
            found += 1
    print(f'   -- {found}/{len(names)} present, archive holds {len(m.block)} members')
