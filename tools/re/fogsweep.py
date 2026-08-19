#!/usr/bin/env python3
"""Count the stack args each Fog ordinal is called with, per version.

Fog is stdcall, so a replacement must pop exactly what the caller pushed. Which
ordinals a version imports is stable across the LoD family; their arities are not.
"""
import struct, sys, collections
from capstone import *
from capstone.x86 import *

def sections(d, pe, opt):
    nsec = struct.unpack_from('<H', d, pe + 6)[0]
    so = opt + struct.unpack_from('<H', d, pe + 20)[0]
    out = []
    for i in range(nsec):
        o = so + i * 40
        nm = d[o:o+8].rstrip(b'\0').decode(errors='replace')
        vsz, va, rsz, ra = struct.unpack_from('<IIII', d, o + 8)
        out.append((nm, va, vsz, ra, rsz))
    return out

def fog_iat(path):
    """Map runtime IAT slot address -> Fog ordinal."""
    d = open(path, 'rb').read()
    pe = struct.unpack_from('<I', d, 0x3c)[0]; opt = pe + 24
    base = struct.unpack_from('<I', d, opt + 28)[0]
    secs = sections(d, pe, opt)
    def r2o(rva):
        for nm, va, vsz, ra, rsz in secs:
            if va <= rva < va + max(vsz, rsz): return ra + (rva - va)
    imp, _ = struct.unpack_from('<II', d, opt + 96 + 8)
    o = r2o(imp); i = 0; slots = {}
    while True:
        ilt, ts, fc, nr, iat = struct.unpack_from('<IIIII', d, o + i * 20)
        if ilt == 0 and nr == 0 and iat == 0: break
        no = r2o(nr); nm = d[no:d.index(b'\0', no)].decode()
        if nm.lower().startswith('fog'):
            t = ilt or iat
            oo = r2o(t); k = 0
            while True:
                v = struct.unpack_from('<I', d, oo + k * 4)[0]
                if v == 0: break
                if v & 0x80000000:
                    slots[base + iat + k * 4] = v & 0xffff
                k += 1
        i += 1
    return d, base, secs, slots

def sweep(path):
    d, base, secs, slots = fog_iat(path)
    md = Cs(CS_ARCH_X86, CS_MODE_32); md.detail = True
    nm, va, vsz, ra, rsz = secs[0]
    code = d[ra:ra+rsz]
    insns = []; pos = 0
    while pos < len(code):
        got = list(md.disasm(code[pos:], base + va + pos))
        if not got: pos += 1; continue
        insns.extend(got); pos = (got[-1].address - (base + va)) + got[-1].size
    # MSVC routes imports through `jmp dword ptr [IAT]` thunks, so a call reaches Fog indirectly.
    # Map each thunk's address to the ordinal it lands on, then treat a call to it as a call to Fog.
    thunks = {}
    for ins in insns:
        if ins.mnemonic != 'jmp' or not ins.operands: continue
        op = ins.operands[0]
        if op.type != X86_OP_MEM or op.mem.base != 0 or op.mem.index != 0: continue
        slot = op.mem.disp & 0xffffffff
        if slot in slots:
            thunks[ins.address] = slots[slot]

    counts = collections.defaultdict(collections.Counter)
    for i, ins in enumerate(insns):
        if ins.mnemonic != 'call' or not ins.operands: continue
        op = ins.operands[0]
        if op.type == X86_OP_IMM and (op.imm & 0xffffffff) in thunks:
            slot = None
            ordn = thunks[op.imm & 0xffffffff]
        elif op.type == X86_OP_MEM and op.mem.base == 0 and op.mem.index == 0 \
             and (op.mem.disp & 0xffffffff) in slots:
            ordn = slots[op.mem.disp & 0xffffffff]
        else:
            continue
        pushes = 0
        for k in range(i - 1, max(i - 40, 0), -1):
            q = insns[k]
            if q.mnemonic == 'push': pushes += 1
            elif q.mnemonic == 'call': break
            elif q.mnemonic in ('add', 'sub') and 'esp' in q.op_str: break
        counts[ordn][pushes] += 1
    print(f'== {path}')
    for ordn in sorted(counts):
        c = counts[ordn]
        modal = c.most_common(1)[0]
        print(f'   @{ordn}  modal pushes={modal[0]} ({modal[1]} sites)   all={dict(c)}')

for p in sys.argv[1:]:
    sweep(p)
