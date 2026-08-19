#!/usr/bin/env python3
"""Sweep a pre-1.14 D2Game.dll for its server-callback dispatch sites.

Same method as the Ghidra sweep: find the global that @10023 stores the table into,
then find every CALL/JMP that reaches it -- including through LEA reg,[table+n] and
ADD reg,n -- and count the raw pushes in the dispatch's own basic block.
"""
import struct, sys, collections
from capstone import *
from capstone.x86 import *

def load(path):
    d = open(path, 'rb').read()
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    opt = pe + 24
    base = struct.unpack_from('<I', d, opt + 28)[0]
    nsec = struct.unpack_from('<H', d, pe + 6)[0]
    so = opt + struct.unpack_from('<H', d, pe + 20)[0]
    secs = []
    for i in range(nsec):
        o = so + i * 40
        name = d[o:o+8].rstrip(b'\0').decode(errors='replace')
        vsz, va, rsz, ra = struct.unpack_from('<IIII', d, o + 8)
        secs.append((name, va, vsz, ra, rsz))
    erva, _ = struct.unpack_from('<II', d, opt + 96)
    return d, base, secs, erva

def rva2off(secs, rva):
    for _, va, vsz, ra, rsz in secs:
        if va <= rva < va + max(vsz, rsz):
            return ra + (rva - va)
    return None

def export_va(d, base, secs, erva, ordinal):
    o = rva2off(secs, erva)
    bo = struct.unpack_from('<I', d, o + 16)[0]
    n = struct.unpack_from('<I', d, o + 20)[0]
    eat = struct.unpack_from('<I', d, o + 28)[0]
    i = ordinal - bo
    if not (0 <= i < n):
        return None
    return base + struct.unpack_from('<I', d, rva2off(secs, eat) + i * 4)[0]

def text_section(secs):
    for name, va, vsz, ra, rsz in secs:
        if name.startswith('.text'):
            return va, vsz, ra, rsz
    return secs[0][1], secs[0][2], secs[0][3], secs[0][4]

def find_table_global(d, base, secs, erva, md):
    """@10023 stores its argument into the callback-table global."""
    va = export_va(d, base, secs, erva, 10023)
    off = rva2off(secs, va - base)
    for ins in md.disasm(d[off:off+64], va):
        if ins.mnemonic == 'mov' and ins.operands:
            dst, src = ins.operands[0], ins.operands[1]
            if dst.type == X86_OP_MEM and dst.mem.base == 0 and dst.mem.index == 0:
                return dst.mem.disp & 0xffffffff
        if ins.mnemonic == 'ret':
            break
    return None

def sweep(path):
    d, base, secs, erva = load(path)
    md = Cs(CS_ARCH_X86, CS_MODE_32)
    md.detail = True
    g = find_table_global(d, base, secs, erva, md)
    print(f'{path}\n  image base 0x{base:x}   callback table global 0x{g:x}')
    tva, tvsz, tra, trsz = text_section(secs)
    code = d[tra:tra+trsz]
    # Linear disassembly walks into padding and alignment data; capstone stops dead there. Restart
    # one byte on so a single undecodable run does not truncate the rest of .text.
    insns = []
    pos = 0
    while pos < len(code):
        got = list(md.disasm(code[pos:], base + tva + pos))
        if not got:
            pos += 1
            continue
        insns.extend(got)
        pos = (got[-1].address - (base + tva)) + got[-1].size
    idx = {i.address: n for n, i in enumerate(insns)}

    results = []
    for n, ins in enumerate(insns):
        # a load of the global into a register starts a trace
        loads = None
        for op in ins.operands:
            if op.type == X86_OP_MEM and op.mem.base == 0 and op.mem.index == 0 \
               and (op.mem.disp & 0xffffffff) == g:
                loads = True
        if not loads or ins.mnemonic != 'mov':
            continue
        dst = ins.operands[0]
        if dst.type != X86_OP_REG:
            continue
        basemap = {ins.reg_name(dst.reg): 0}
        fnp = {}
        for m in range(n + 1, min(n + 90, len(insns))):
            q = insns[m]
            mn = q.mnemonic
            ops = q.operands
            if mn in ('call', 'jmp'):
                if ops and ops[0].type == X86_OP_MEM and ops[0].mem.base != 0 and ops[0].mem.index == 0:
                    rb = q.reg_name(ops[0].mem.base)
                    if rb in basemap:
                        results.append((basemap[rb] + ops[0].mem.disp, q, insns, m))
                        break
                if ops and ops[0].type == X86_OP_REG:
                    rb = q.reg_name(ops[0].reg)
                    if rb in fnp:
                        results.append((fnp[rb], q, insns, m))
                        break
                if mn == 'call':
                    for c in ('eax', 'ecx', 'edx'):
                        basemap.pop(c, None); fnp.pop(c, None)
                continue
            if not ops:
                continue
            d0 = ops[0]
            if d0.type != X86_OP_REG:
                continue
            dn = q.reg_name(d0.reg)
            if mn in ('add', 'sub') and len(ops) > 1 and ops[1].type == X86_OP_IMM and dn in basemap:
                basemap[dn] += ops[1].imm if mn == 'add' else -ops[1].imm
            elif mn == 'mov' and len(ops) > 1 and ops[1].type == X86_OP_REG and q.reg_name(ops[1].reg) in basemap:
                basemap[dn] = basemap[q.reg_name(ops[1].reg)]; fnp.pop(dn, None)
            elif mn == 'mov' and len(ops) > 1 and ops[1].type == X86_OP_MEM and ops[1].mem.base != 0 \
                 and q.reg_name(ops[1].mem.base) in basemap:
                fnp[dn] = basemap[q.reg_name(ops[1].mem.base)] + ops[1].mem.disp; basemap.pop(dn, None)
            elif mn == 'lea' and len(ops) > 1 and ops[1].type == X86_OP_MEM and ops[1].mem.base != 0 \
                 and q.reg_name(ops[1].mem.base) in basemap:
                basemap[dn] = basemap[q.reg_name(ops[1].mem.base)] + ops[1].mem.disp; fnp.pop(dn, None)
            elif mn not in ('push', 'cmp', 'test'):
                basemap.pop(dn, None); fnp.pop(dn, None)

    # count pushes back to the boundary, and note the ECX setup (pRealm offset)
    by_slot = collections.defaultdict(list)
    for slot, call, insns, m in results:
        pushes = 0
        ecx_lea = None
        for k in range(m - 1, max(m - 40, 0), -1):
            q = insns[k]
            if q.mnemonic == 'push':
                pushes += 1
            if q.mnemonic == 'lea' and q.operands and q.operands[0].type == X86_OP_REG \
               and q.reg_name(q.operands[0].reg) == 'ecx' and ecx_lea is None:
                ecx_lea = q.op_str
            if q.mnemonic == 'call':
                break
            if q.mnemonic in ('add', 'sub') and 'esp' in q.op_str:
                break
        by_slot[slot].append((pushes, call.address, ecx_lea))
    for slot in sorted(by_slot):
        if slot == 0x10:
            print(f'  slot 0x10: {len(by_slot[slot])} log sites (suppressed)')
            continue
        for pushes, addr, lea in by_slot[slot]:
            extra = f'   ecx <- lea {lea}' if lea else ''
            print(f'  slot 0x{slot:02x}  pushes={pushes}  at 0x{addr:x}{extra}')

for p in sys.argv[1:]:
    sweep(p)
