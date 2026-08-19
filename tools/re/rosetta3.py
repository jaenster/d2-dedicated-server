#!/usr/bin/env python3
"""Solve the classic->LoD Fog map under THREE constraints at once.

  fingerprint   what the function references and calls
  monotonicity  the renumbering inserted, never reordered
  arity         `ret N` must match on both sides -- an independent fact that already
                refuted five rows the first two agreed on
"""
import sys, importlib.util, struct
sys.argv=['x']
def load(name, path):
    spec=importlib.util.spec_from_file_location(name, path)
    m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
BASE='/private/tmp/claude-501/-Users-jaenster-code-zig-d2gs/1214742b-8bf9-48a1-b848-4549dcc94831/scratchpad/'
r=load('r', BASE+'rosetta.py')
ac=load('ac', BASE+'arity_check.py')   # reuses its callee_ret

CLASSIC='/Users/jaenster/code/d2-patch-extract/1.06b-classic/rebuilt/Fog.dll'
LOD='/Users/jaenster/code/d2-1.10f-binaries/Fog.dll'
WANT=[10016,10021,10022,10023,10024,10026,10033,10034,10036,10061,10062,10064,10075,10076,
      10077,10078,10086,10087,10088,10089,10095,10096,10097,10098,10099,10102,10103,10104,
      10105,10109,10110,10140,10141,10142,10152,10175,10200,10201,10202,10203]
_, cf = r.build(CLASSIC)
_, lf = r.build(LOD)
cret = ac.callee_ret(CLASSIC)
lret = ac.callee_ret(LOD)

cs_ords=[o for o in WANT if o in cf]
lo_ords=sorted(lf)
def score(c,l):
    if cret.get(c) is None or lret.get(l) is None: return None
    if cret[c] != lret[l]: return None            # hard gate
    a,b,am=cf[c]; x,y,bm=lf[l]
    return 4.0*r.jac(a,x)+3.0*r.jac(b,y)+1.5*r.seq(am,bm)

NEG=-1e9
n,m=len(cs_ords),len(lo_ords)
S=[[ (score(c,l) if score(c,l) is not None else NEG) for l in lo_ords] for c in cs_ords]
best=[[NEG]*m for _ in range(n)]; back=[[-1]*m for _ in range(n)]
for j in range(m): best[0][j]=S[0][j]
for i in range(1,n):
    rmax,rarg=NEG,-1
    for j in range(m):
        if j>0 and best[i-1][j-1]>rmax: rmax,rarg=best[i-1][j-1],j-1
        if rarg>=0 and S[i][j]>NEG/2: best[i][j]=rmax+S[i][j]; back[i][j]=rarg
j=max(range(m), key=lambda k: best[n-1][k])
path=[]
for i in range(n-1,-1,-1): path.append(j); j=back[i][j]
path.reverse()
print(f'{"classic":>8} -> {"lod":>6}  {"score":>6}  ret  note')
for i,c in enumerate(cs_ords):
    l=lo_ords[path[i]]
    free=max((k for k in range(m) if S[i][k]>NEG/2), key=lambda k:S[i][k], default=None)
    tag='anchor' if free is not None and lo_ords[free]==l and S[i][path[i]]>2.0 else \
        ('agrees' if free is not None and lo_ords[free]==l else 'pinned')
    print(f'{c:>8} -> {l:>6}  {S[i][path[i]]:6.2f}  {cret.get(c)!s:>3}  {tag}')
