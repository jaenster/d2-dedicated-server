#!/usr/bin/env python3
"""Match classic-era Fog ordinals to their LoD numbers by fingerprinting the functions.

Fog renumbered once, at the LoD boundary. The functions themselves largely did not
change, so a classic ordinal can be identified by what its function *does*: which
strings it references (Fog is dense with asserts carrying source paths and messages),
which Storm ordinals it calls (Storm's numbering is stable across the whole range),
and its instruction mnemonics.
"""
import struct, sys, collections
from capstone import *
from capstone.x86 import *

class PE:
    def __init__(self, path):
        self.d = d = open(path, 'rb').read()
        pe = struct.unpack_from('<I', d, 0x3c)[0]; opt = pe + 24
        self.base = struct.unpack_from('<I', d, opt + 28)[0]
        nsec = struct.unpack_from('<H', d, pe + 6)[0]
        so = opt + struct.unpack_from('<H', d, pe + 20)[0]
        self.secs = []
        for i in range(nsec):
            o = so + i * 40
            nm = d[o:o+8].rstrip(b'\0').decode(errors='replace')
            vsz, va, rsz, ra = struct.unpack_from('<IIII', d, o + 8)
            self.secs.append((nm, va, vsz, ra, rsz))
        self.erva, _ = struct.unpack_from('<II', d, opt + 96)
        self.irva, _ = struct.unpack_from('<II', d, opt + 96 + 8)

    def r2o(self, rva):
        for nm, va, vsz, ra, rsz in self.secs:
            if va <= rva < va + max(vsz, rsz): return ra + (rva - va)

    def va2o(self, va): return self.r2o(va - self.base)

    def exports(self):
        o = self.r2o(self.erva)
        bo = struct.unpack_from('<I', self.d, o + 16)[0]
        n = struct.unpack_from('<I', self.d, o + 20)[0]
        eat = struct.unpack_from('<I', self.d, o + 28)[0]
        out = {}
        for i in range(n):
            fr = struct.unpack_from('<I', self.d, self.r2o(eat) + i * 4)[0]
            if fr: out[bo + i] = self.base + fr
        return out

    def storm_slots(self):
        o = self.r2o(self.irva); i = 0; slots = {}
        while True:
            ilt, ts, fc, nr, iat = struct.unpack_from('<IIIII', self.d, o + i * 20)
            if ilt == 0 and nr == 0 and iat == 0: break
            no = self.r2o(nr); nm = self.d[no:self.d.index(b'\0', no)].decode()
            if nm.lower().startswith('storm'):
                oo = self.r2o(ilt or iat); k = 0
                while True:
                    v = struct.unpack_from('<I', self.d, oo + k * 4)[0]
                    if v == 0: break
                    if v & 0x80000000: slots[self.base + iat + k * 4] = v & 0xffff
                    k += 1
            i += 1
        return slots

    def string_at(self, va):
        o = self.va2o(va)
        if o is None: return None
        end = o
        while end < len(self.d) and end - o < 120:
            c = self.d[end]
            if c == 0: break
            if c < 0x20 or c > 0x7e: return None
            end += 1
        if end - o < 5: return None
        return self.d[o:end].decode(errors='replace')

def fingerprint(pe, md, entry, storm, thunks, limit=400):
    """Walk a function from its entry, following straight-line flow."""
    strings, storms, mnems = set(), set(), []
    o = pe.va2o(entry)
    if o is None: return None
    for ins in md.disasm(pe.d[o:o+4096], entry):
        if len(mnems) > limit: break
        mnems.append(ins.mnemonic)
        for op in ins.operands:
            if op.type == X86_OP_IMM:
                s = pe.string_at(op.imm & 0xffffffff)
                if s: strings.add(s)
            elif op.type == X86_OP_MEM and op.mem.base == 0 and op.mem.index == 0:
                disp = op.mem.disp & 0xffffffff
                if ins.mnemonic in ('call', 'jmp') and disp in storm: storms.add(storm[disp])
                else:
                    s = pe.string_at(disp)
                    if s: strings.add(s)
        if ins.mnemonic == 'call' and ins.operands and ins.operands[0].type == X86_OP_IMM:
            t = ins.operands[0].imm & 0xffffffff
            if t in thunks: storms.add(thunks[t])
        if ins.mnemonic in ('ret', 'retf'): break
    return strings, storms, mnems

def build(path):
    pe = PE(path)
    md = Cs(CS_ARCH_X86, CS_MODE_32); md.detail = True
    storm = pe.storm_slots()
    # thunks: call rel32 -> jmp [storm slot]
    thunks = {}
    nm, va, vsz, ra, rsz = pe.secs[0]
    code = pe.d[ra:ra+rsz]
    pos = 0
    while pos < len(code):
        got = list(md.disasm(code[pos:], pe.base + va + pos))
        if not got: pos += 1; continue
        for ins in got:
            if ins.mnemonic == 'jmp' and ins.operands and ins.operands[0].type == X86_OP_MEM \
               and ins.operands[0].mem.base == 0:
                disp = ins.operands[0].mem.disp & 0xffffffff
                if disp in storm: thunks[ins.address] = storm[disp]
        pos = (got[-1].address - (pe.base + va)) + got[-1].size
    fps = {}
    for ordn, entry in pe.exports().items():
        fp = fingerprint(pe, md, entry, storm, thunks)
        if fp: fps[ordn] = fp
    return pe, fps

def jac(a, b):
    if not a and not b: return 0.0
    return len(a & b) / max(1, len(a | b))

def seq(a, b):
    n = min(len(a), len(b), 60)
    if n == 0: return 0.0
    same = sum(1 for i in range(n) if a[i] == b[i])
    return same / n

if __name__ == '__main__':
    classic_path, lod_path = sys.argv[1], sys.argv[2]
    wanted = [int(x) for x in sys.argv[3].split(',')] if len(sys.argv) > 3 else None
    _, cf = build(classic_path)
    _, lf = build(lod_path)
    print(f'classic exports fingerprinted: {len(cf)}   lod: {len(lf)}')
    for ordn in sorted(wanted or cf):
        if ordn not in cf: print(f'  @{ordn}: no export'); continue
        cs_, cst, cm = cf[ordn]
        best = []
        for lord, (ls, lst, lm) in lf.items():
            score = 4.0 * jac(cs_, ls) + 3.0 * jac(cst, lst) + 1.5 * seq(cm, lm)
            if abs(len(cm) - len(lm)) > max(20, 0.5 * max(len(cm), len(lm))): score -= 0.5
            best.append((score, lord))
        best.sort(reverse=True)
        top = best[0]
        second = best[1] if len(best) > 1 else (0, 0)
        margin = top[0] - second[0]
        flag = 'OK  ' if (top[0] > 2.0 and margin > 0.5) else 'weak'
        sample = sorted(cs_)[:1]
        print(f'  @{ordn} -> @{top[1]}  score={top[0]:.2f} margin={margin:.2f} {flag}'
              + (f'   [{sample[0][:48]}]' if sample else ''))
