#!/usr/bin/env python3
"""Count a callback's stack args by simulating the stack, not by counting pushes.

Counting pushes back to the previous CALL assumes that call consumed everything
before it. It does not: an intermediate stdcall pops only its own arguments, and the
remainder still belong to the pending call. That undercount is why three slots were
recorded wrong. Here each intermediate call's `ret N` is resolved -- through import
thunks into the owning DLL when necessary -- and subtracted.
"""
import struct, sys
from capstone import *
from capstone.x86 import *

class Mod:
    def __init__(s, path):
        s.d=open(path,'rb').read()
        pe=struct.unpack_from('<I',s.d,0x3c)[0]; s.opt=pe+24
        s.base=struct.unpack_from('<I',s.d,s.opt+28)[0]
        nsec=struct.unpack_from('<H',s.d,pe+6)[0]
        so=s.opt+struct.unpack_from('<H',s.d,pe+20)[0]
        s.secs=[]
        for i in range(nsec):
            o=so+i*40
            vsz,va,rsz,ra=struct.unpack_from('<IIII',s.d,o+8)
            s.secs.append((va,vsz,ra,rsz))
        s.md=Cs(CS_ARCH_X86,CS_MODE_32); s.md.detail=True
    def o(s,va):
        rva=va-s.base
        for v,vs,ra,rs in s.secs:
            if v<=rva<v+max(vs,rs): return ra+(rva-v)
    def ret_at(s,va,limit=6000):
        off=s.o(va)
        if off is None: return None
        for ins in s.md.disasm(s.d[off:off+limit], va):
            if ins.mnemonic=='ret': return ins.operands[0].imm if ins.operands else 0
            if ins.mnemonic=='jmp' and ins.operands and ins.operands[0].type==X86_OP_MEM \
               and ins.operands[0].mem.base==0:
                return ('import', ins.operands[0].mem.disp & 0xffffffff)
        return None
    def imports(s):
        imp,_=struct.unpack_from('<II',s.d,s.opt+96+8)
        o=s.o(s.base+imp); i=0; out={}
        while True:
            ilt,ts,fc,nr,iat=struct.unpack_from('<IIIII',s.d,o+i*20)
            if ilt==0 and nr==0 and iat==0: break
            no=s.o(s.base+nr); nm=s.d[no:s.d.index(b'\0',no)].decode()
            oo=s.o(s.base+(ilt or iat)); k=0
            while True:
                v=struct.unpack_from('<I',s.d,oo+k*4)[0]
                if v==0: break
                if v & 0x80000000: out[s.base+iat+k*4]=(nm, v & 0xffff)
                k+=1
            i+=1
        return out
    def export_va(s, ordinal):
        erva,_=struct.unpack_from('<II',s.d,s.opt+96)
        o=s.o(s.base+erva); bo=struct.unpack_from('<I',s.d,o+16)[0]
        n=struct.unpack_from('<I',s.d,o+20)[0]; eat=struct.unpack_from('<I',s.d,o+28)[0]
        i=ordinal-bo
        if not (0<=i<n): return None
        return s.base+struct.unpack_from('<I',s.d,s.o(s.base+eat)+i*4)[0]

def count(game_path, deps, site, window=0x60):
    g=Mod(game_path); imps=g.imports()
    depmods={k:Mod(v) for k,v in deps.items()}
    def pops(target_va):
        r=g.ret_at(target_va)
        if isinstance(r,tuple) and r[0]=='import':
            ent=imps.get(r[1])
            if not ent: return None
            dll,ordn=ent
            m=depmods.get(dll.lower())
            if not m: return None
            va=m.export_va(ordn)
            if va is None: return None
            rr=m.ret_at(va)
            return rr if isinstance(rr,int) else None
        return r if isinstance(r,int) else None
    start=site-window
    off=g.o(start)
    depth=0; log=[]
    for ins in g.md.disasm(g.d[off:off+window+8], start):
        if ins.address>=site: break
        if ins.mnemonic=='push': depth+=1
        elif ins.mnemonic=='call':
            op=ins.operands[0]
            if op.type==X86_OP_IMM:
                p=pops(op.imm & 0xffffffff)
                if p is None: log.append(f'  ? call 0x{op.imm:x} (unknown pops) at 0x{ins.address:x}')
                else:
                    depth-=p//4; log.append(f'  call 0x{op.imm:x} pops {p//4}')
            else:
                log.append(f'  ? indirect call at 0x{ins.address:x}')
            if depth<0: depth=0
        elif ins.mnemonic in ('add','sub') and 'esp' in ins.op_str:
            depth=0
    return depth, log

DEPS_LOD={'d2common.dll':None}
CASES=[
 ('1.07', '/Users/jaenster/code/d2-patch-extract/1.07-lod-base/pe-files/D2Game.dll',
          '/Users/jaenster/code/d2-patch-extract/1.07-lod-base/pe-files/D2Common.dll',
          {0x14:0x6fc68631, 0x28:0x6fc67226, 0x2c:0x6fc9ede3}),
 ('1.09d','/Users/jaenster/code/d2-patch-extract/1.09d-lod/rebuilt/D2Game.dll',
          '/Users/jaenster/code/d2-patch-extract/1.09d-lod/rebuilt/D2Common.dll',
          {0x14:0x6fc388e6, 0x28:0x6fc37477, 0x2c:0x6fc726b3}),
 ('1.10f','/Users/jaenster/code/d2-1.10f-binaries/D2Game.dll',
          '/Users/jaenster/code/d2-1.10f-binaries/D2Common.dll',
          {0x14:0x6fc38d74, 0x28:0x6fc37670, 0x2c:0x6fc7edc7}),
 ('1.06b','/Users/jaenster/code/d2-patch-extract/1.06b-classic/rebuilt/D2Game.dll',
          '/Users/jaenster/code/d2-patch-extract/1.06b-classic/rebuilt/D2Common.dll',
          {0x14:0x6fcb7fda, 0x28:0x6fcb6cee, 0x2c:0x6fceb3a1}),
]
NAMES={0x14:'fpEnterGame',0x28:'fpUpdateCharacterLadder',0x2c:'fpUpdateGameInformation'}
for label, game, common, sites in CASES:
    print(f'== {label}')
    for slot, va in sites.items():
        n,log = count(game, {'d2common.dll': common}, va)
        print(f'   {NAMES[slot]:<24} slot 0x{slot:02x} @0x{va:x} -> {n} stack args')
        for l in log[-3:]: print('     ', l)
