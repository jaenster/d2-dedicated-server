#!/usr/bin/env python3
"""Independent check on the classic->LoD Fog map: the arities must agree.

The fingerprint says which LoD function a classic ordinal became. If that is right,
then what 1.06b pushes at its call sites must equal what the LoD function pops in its
`ret N`. Two unrelated facts about the same row -- a disagreement refutes it.
"""
import struct, sys, collections
from capstone import *
from capstone.x86 import *

def secs_of(d):
    pe=struct.unpack_from('<I',d,0x3c)[0]; opt=pe+24
    base=struct.unpack_from('<I',d,opt+28)[0]
    nsec=struct.unpack_from('<H',d,pe+6)[0]
    so=opt+struct.unpack_from('<H',d,pe+20)[0]
    secs=[]
    for i in range(nsec):
        o=so+i*40
        nm=d[o:o+8].rstrip(b'\0').decode(errors='replace')
        vsz,va,rsz,ra=struct.unpack_from('<IIII',d,o+8)
        secs.append((nm,va,vsz,ra,rsz))
    return pe,opt,base,secs

def r2o(secs,rva):
    for nm,va,vsz,ra,rsz in secs:
        if va<=rva<va+max(vsz,rsz): return ra+(rva-va)

def fog_slots(path):
    d=open(path,'rb').read(); pe,opt,base,secs=secs_of(d)
    imp,_=struct.unpack_from('<II',d,opt+96+8)
    o=r2o(secs,imp); i=0; slots={}
    while True:
        ilt,ts,fc,nr,iat=struct.unpack_from('<IIIII',d,o+i*20)
        if ilt==0 and nr==0 and iat==0: break
        no=r2o(secs,nr); nm=d[no:d.index(b'\0',no)].decode()
        if nm.lower().startswith('fog'):
            oo=r2o(secs,ilt or iat); k=0
            while True:
                v=struct.unpack_from('<I',d,oo+k*4)[0]
                if v==0: break
                if v & 0x80000000: slots[base+iat+k*4]=v & 0xffff
                k+=1
        i+=1
    return d,base,secs,slots

def disasm_all(d,base,secs,md):
    nm,va,vsz,ra,rsz=secs[0]
    code=d[ra:ra+rsz]; out=[]; pos=0
    while pos<len(code):
        got=list(md.disasm(code[pos:], base+va+pos))
        if not got: pos+=1; continue
        out.extend(got); pos=(got[-1].address-(base+va))+got[-1].size
    return out

def caller_pushes(paths):
    md=Cs(CS_ARCH_X86,CS_MODE_32); md.detail=True
    counts=collections.defaultdict(collections.Counter)
    for path in paths:
        d,base,secs,slots=fog_slots(path)
        insns=disasm_all(d,base,secs,md)
        thunks={}
        for ins in insns:
            if ins.mnemonic=='jmp' and ins.operands and ins.operands[0].type==X86_OP_MEM \
               and ins.operands[0].mem.base==0:
                s=ins.operands[0].mem.disp & 0xffffffff
                if s in slots: thunks[ins.address]=slots[s]
        for i,ins in enumerate(insns):
            if ins.mnemonic!='call' or not ins.operands: continue
            op=ins.operands[0]
            if op.type==X86_OP_IMM and (op.imm & 0xffffffff) in thunks: ordn=thunks[op.imm & 0xffffffff]
            elif op.type==X86_OP_MEM and op.mem.base==0 and (op.mem.disp & 0xffffffff) in slots:
                ordn=slots[op.mem.disp & 0xffffffff]
            else: continue
            p=0
            for k in range(i-1,max(i-40,0),-1):
                q=insns[k]
                if q.mnemonic=='push': p+=1
                elif q.mnemonic=='call': break
                elif q.mnemonic in ('add','sub') and 'esp' in q.op_str: break
            counts[ordn][p]+=1
    return counts

def callee_ret(fog_path):
    """ordinal -> stack bytes popped by its `ret N` (None if it ends in a plain ret)."""
    d=open(fog_path,'rb').read(); pe,opt,base,secs=secs_of(d)
    erva,_=struct.unpack_from('<II',d,opt+96)
    o=r2o(secs,erva); bo=struct.unpack_from('<I',d,o+16)[0]
    n=struct.unpack_from('<I',d,o+20)[0]; eat=struct.unpack_from('<I',d,o+28)[0]
    md=Cs(CS_ARCH_X86,CS_MODE_32); md.detail=True
    out={}
    for i in range(n):
        fr=struct.unpack_from('<I',d,r2o(secs,eat)+i*4)[0]
        if not fr: continue
        off=r2o(secs,fr)
        if off is None: continue
        for ins in md.disasm(d[off:off+4096], base+fr):
            if ins.mnemonic=='ret':
                out[bo+i]= (ins.operands[0].imm if ins.operands else 0)
                break
            if ins.mnemonic=='jmp' and ins.operands and ins.operands[0].type==X86_OP_IMM:
                continue
    return out

classic_dlls=['/Users/jaenster/code/d2-patch-extract/1.06b-classic/rebuilt/D2Game.dll',
              '/Users/jaenster/code/d2-patch-extract/1.06b-classic/rebuilt/D2Common.dll']
pushes=caller_pushes(classic_dlls)
rets=callee_ret('/Users/jaenster/code/d2-1.10f-binaries/Fog.dll')
rets_classic=callee_ret('/Users/jaenster/code/d2-patch-extract/1.06b-classic/rebuilt/Fog.dll')

MAP=[(10016,10018,'corr'),(10021,10023,'INF'),(10022,10024,'INF'),(10023,10025,'corr'),
     (10024,10026,'INF'),(10026,10029,'meas'),(10033,10042,'corr'),(10034,10043,'corr'),
     (10036,10055,'corr'),(10061,10083,'corr'),(10062,10084,'corr'),(10064,10086,'corr'),
     (10075,10102,'meas'),(10076,10103,'meas'),(10077,10104,'meas'),(10078,10105,'meas'),
     (10086,10115,'meas'),(10087,10118,'corr'),(10088,10119,'corr'),(10089,10120,'corr'),
     (10095,10126,'meas'),(10096,10127,'corr'),(10097,10128,'INF'),(10098,10132,'INF'),
     (10099,10133,'INF'),(10102,10134,'meas'),(10103,10135,'meas'),(10104,10136,'meas'),
     (10105,10137,'corr'),(10109,10143,'INF'),(10110,10144,'INF'),(10140,10170,'INF'),
     (10141,10171,'INF'),(10142,10172,'INF'),(10152,10175,'INF'),(10175,10180,'INF'),
     (10200,10207,'meas'),(10201,10208,'meas'),(10202,10209,'corr'),(10203,10210,'corr')]
print(f'{"classic":>8} {"lod":>6} {"how":>5} {"pushes":>7} {"classicRet":>11} {"lodRet":>7}  verdict')
agree=disagree=unknown=0
for c,l,how in MAP:
    pc = pushes[c].most_common(1)[0][0] if c in pushes else None
    rc = rets_classic.get(c); rl = rets.get(l)
    v='?'
    if rc is not None and rl is not None:
        v = 'AGREE' if rc==rl else 'CONFLICT'
    if v=='AGREE': agree+=1
    elif v=='CONFLICT': disagree+=1
    else: unknown+=1
    print(f'{c:>8} {l:>6} {how:>5} {str(pc):>7} {str(rc):>11} {str(rl):>7}  {v}')
print(f'\nret-size agrees on {agree}, conflicts on {disagree}, unknown {unknown}')
