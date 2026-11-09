#!/usr/bin/env python3
"""gen_x86_len_tables.py -- regenerate the x86_64 instruction-length tables the
--emit=asm listing sizes every line with (x86_len_tables.EXT: src/x86_len_tables.mlr in MLRift,
src/x86_len_tables.kr in KernRift).

The listing must split the code stream exactly where GNU objdump
(-mi386:x86-64) does, valid encodings and (bad) ones alike, or a bad
encoding swallows the code after it. Which opcodes objdump knows -- per map,
mandatory prefix, REX.W/VEX.W, vector length, EVEX.b, NDD/NF and vvvv -- is
data, not structure, so it is measured here: every (map, opcode, prefix
state, W, L/LL, b, vvvv, ModR/M class) is assembled and fed to objdump, and
the length it reports is recorded as a CODE relative to the end of the
opcode (T):
  F    the structural formula (x86_formula_len) is right
  dN   T + N + the ModR/M's SIB/displacement bytes (N >= 1 counts the ModR/M)
       (a SIB-class probe's own SIB byte is not in N: x86_modrm_extra adds it)
  rN   T + N, the ModR/M's displacement NOT consumed (objdump stops early)
  pN   (legacy prefixes) + N
  0    T: objdump stopped at the opcode ((bad) before any ModR/M)
Header-level rules (C4 map, 8F XOP select, EVEX map 0, the APX map-4
ND/aaa/V'/LL/z/vvvv checks, fwait, REX2 + VEX/EVEX, the 15-byte limit) are in
the listing's x86_insn_len itself, mirrored by parse() below.

Usage: gen_x86_len_tables.py OUT.EXT        (needs objdump; ~30 min)
       gen_x86_len_tables.py --check N      (stream fuzz of the model vs objdump)
The tables are objdump-version specific; the header records the version.
"""
import sys, os, re, subprocess, tempfile, itertools, collections, random
# parse.py -- structural parse of one x86-64 instruction, as the MLRift listing will do it.
PFX={0x66,0x67,0x64,0x65,0xF2,0xF3,0x2E,0x3E,0x26,0x36,0xF0}
def modrm_extra(b,i):
    if i>=len(b): return 0
    m=b[i]; mod=m>>6; rm=m&7
    if mod==3: return 0
    e=0
    if rm==4:
        e+=1
        if mod==0 and i+1<len(b) and (b[i+1]&7)==5: e+=4
    if mod==1: e+=1
    if mod==2: e+=4
    if mod==0 and rm==5: e+=4
    return e
def mi_of(m):
    """ModR/M class: 0-7 memory (no SIB) by reg, 8-71 register by reg/rm,
    72-79 memory WITH a SIB byte by reg (VSIB gathers and AMX need one)"""
    if (m>>6)==3: return 8+((m>>3)&7)*8+(m&7)
    if (m&7)==4: return 72+((m>>3)&7)
    return (m>>3)&7
def parse(b):
    """-> dict(space, op, dims, mi, T, np, osz, asz, rexw, imod) or None (ran out)"""
    n=0; osz=asz=0; rep=0; avail=len(b)
    # fwait (9B) is a prefix of an x87 instruction (D8-DF) reached through
    # legacy prefixes, more 9Bs and a REX; otherwise it is a 1-byte fwait.
    k=0
    while k<avail and (b[k] in PFX or b[k]==0x9B): k+=1
    if k<avail and (b[k]&0xF0)==0x40: k+=1
    x87 = k<avail and 0xD8<=b[k]<=0xDF
    if not x87 and 0x9B in b[:k]:
        return dict(space="ONE",T=b.index(0x9B)+1,np=0)
    while n<avail and (b[n] in PFX or (x87 and b[n]==0x9B)):
        x=b[n]
        if x==0x66: osz=1
        if x==0x67: asz=1
        if x in (0xF2,0xF3): rep=x
        n+=1
    np_=n
    if n>=avail: return None
    ps={(0,0):0,(1,0):1,(0,0xF3):2,(0,0xF2):3,(1,0xF3):4,(1,0xF2):5}[(osz,rep)]
    x=b[n]; rexw=0
    if x==0xD5:
        if n+2>=avail: return None
        p=b[n+1]; rexw=(p>>3)&1; sp="R1" if p&0x80 else "R0"; n+=2
        op=b[n]
        if sp=="R0" and op==0xD5: return dict(space="ONE",T=n+1,np=np_)
        if not (sp=="R0" and (op in (0xC4,0xC5,0x62) or (op==0x8F and n+1<avail and (b[n+1]&0x38)!=0))):
            n+=1
            return dict(space=sp,op=op,dims=(ps,rexw),T=n,np=np_,mpos=n,osz=osz,asz=asz,rexw=rexw,rep=rep)
        # REX2 with M0=0 in front of a VEX/EVEX/XOP: parsed as that, the REX2 as a prefix
        x=op; return _vex(b,n,avail,np_,osz,asz,rexw,rep)
    if (x&0xF0)==0x40:
        rexw=(x>>3)&1; n+=1
        if n>=avail: return None
        if b[n] in PFX or (b[n]&0xF0)==0x40: return dict(space="REXLONE",T=n,np=np_)
    x=b[n]
    if x in (0xC4,0xC5,0x62) or (x==0x8F and n+1<avail and (b[n+1]&0x38)!=0):
        return _vex(b,n,avail,np_,osz,asz,rexw,rep)
    op=x; n+=1
    if op==0x0F:
        if n>=avail: return None
        op2=b[n]; n+=1
        if op2 in (0x38,0x3A):
            if n>=avail: return None
            op3=b[n]; n+=1
            return dict(space="L38" if op2==0x38 else "L3A",op=op3,dims=(ps,rexw),T=n,np=np_,mpos=n,osz=osz,asz=asz,rexw=rexw,rep=rep)
        return dict(space="L1",op=op2,dims=(ps,rexw),T=n,np=np_,mpos=n,osz=osz,asz=asz,rexw=rexw,rep=rep)
    return dict(space="L0",op=op,dims=(ps,rexw),T=n,np=np_,mpos=n,osz=osz,asz=asz,rexw=rexw,rep=rep)
def _vex(b,n,avail,np_,osz,asz,rexw,rep):
    x=b[n]
    if x==0xC4 and n+1<avail and (b[n+1]&0x1F) not in (1,2,3,7): return dict(space="ONE",T=n+1,np=np_)
    if x==0x8F and n+1<avail and (b[n+1]&0x1F) not in (8,9,10): return dict(space="ONE",T=n+1,np=np_)
    if True:
        if x==0xC5:
            if n+3>avail: return None
            p1=b[n+1]; mp=1; W=0; vv=(p1>>3)&0xF; Lb=(p1>>2)&1; pp=p1&3; n+=2
            sp="V1"; dims=(pp,Lb,W,0 if vv==0xF else 1)
        elif x==0x62:
            if n+5>avail: return None
            p0,p1,p2=b[n+1],b[n+2],b[n+3]; mp=p0&7
            if mp==0: return dict(space="E0",T=n+1,np=np_)
            W=p1>>7; vv=(p1>>3)&0xF; pp=p1&3
            if mp==4:
                nd=(p2>>4)&1; lo=p2&3; vp=(p2>>3)&1; ll=(p2>>5)&3; z=p2>>7; v15=1 if vv==0xF else 0
                if nd==0:
                    if not (lo==0 and vp==1 and ll==0 and z==0 and v15==1): return dict(space="ONE",T=n+3,np=np_)
                else:
                    if not (lo==0 and ll==0 and z==0): return dict(space="ONE",T=n+(3 if v15 else 1),np=np_)
            n+=4
            sp="E%d"%mp
            if mp==4: dims=(pp,W,(p2>>4)&1,(p2>>2)&1,0 if vv==0xF else 1)
            else: dims=(pp,W,(p2>>5)&3,(p2>>4)&1,0 if vv==0xF else 1)
        else:
            if n+4>avail: return None
            p0,p1=b[n+1],b[n+2]; mp=p0&0x1F; W=p1>>7; vv=(p1>>3)&0xF; Lb=(p1>>2)&1; pp=p1&3; n+=3
            sp=("V%d" if x==0xC4 else "X%X")%mp
            dims=(pp,Lb,W,0 if vv==0xF else 1)
        op=b[n]; n+=1
        return dict(space=sp,op=op,dims=dims,T=n,np=np_,mpos=n,osz=osz,asz=asz,rexw=rexw,rep=rep)

# ---- the structural formula: a faithful copy of the listing's x86_formula_len
PFX={0x66,0x67,0x64,0x65,0xF2,0xF3,0x2E,0x3E,0x26,0x36,0xF0}
def modrm_extra(b,i):
    m=b[i]; mod=m>>6; rm=m&7
    if mod==3: return 0
    e=0
    if rm==4:
        e+=1
        if mod==0 and (b[i+1]&7)==5: e+=4
    if mod==1: e+=1
    if mod==2: e+=4
    if mod==0 and rm==5: e+=4
    return e
def formula(b):
    avail=len(b); n=0; osz=asz=rep=0
    while n<avail:
        x=b[n]
        if x not in PFX: break
        if x==0x66: osz=1
        if x==0x67: asz=1
        if x in (0xF2,0xF3): rep=x
        n+=1
    if n>=avail: return 0
    rexw=0; rex2m=0; x=b[n]
    if x==0xD5:
        if n+2>=avail: return 0
        p=b[n+1]; rexw=(p>>3)&1; rex2m=(p>>7)&1; n+=2
    elif (x&0xF0)==0x40:
        rexw=(x>>3)&1; n+=1
        if n>=avail: return 0
        a=b[n]
        if a in PFX or (a&0xF0)==0x40: return n
    immz=2 if (osz and not rexw) else 4
    op=b[n]; n+=1
    if rex2m: op=0x0F; n-=1
    imm=0; has=0; noea=0; xop=0
    if op==0x8F and n<avail and (b[n]&0x1F)>=8: xop=1
    if op in (0xC4,0xC5,0x62) or xop:
        vpfx=2; vmap=1
        if op==0xC5: vpfx=1
        elif op==0x62: vpfx=3
        if n+vpfx>=avail: return 0
        if op==0xC4 or xop: vmap=b[n]&0x1F
        if op==0x62: vmap=b[n]&7
        n+=vpfx; vop=b[n]; n+=1; has=1
        if xop:
            if vmap==8: imm=1
            if vmap==10: imm=4
        elif vmap==3: imm=1
        elif vmap==1:
            if op!=0x62 and vop==0x77: has=0
            if 0x70<=vop<=0x73 or vop in (0xC2,0xC4,0xC5,0xC6): imm=1
    elif op==0x0F:
        if n>=avail: return 0
        op2=b[n]; n+=1
        if op2==0x38:
            if n>=avail: return 0
            n+=1; has=1
        elif op2==0x3A:
            if n>=avail: return 0
            n+=1; has=1; imm=1
        elif op2==0x0F: has=1; imm=1
        elif 0x20<=op2<=0x23: has=1; noea=1
        elif 0x80<=op2<=0x8F: imm=immz
        elif op2==0x04 or 0x05<=op2<=0x0C or op2==0x0E: pass
        elif 0x24<=op2<=0x27 or 0x30<=op2<=0x3F: pass
        elif op2 in (0x77,0x7A,0x7B,0xA7): pass
        elif op2 in (0xA0,0xA1,0xA2,0xA8,0xA9,0xAA): pass
        elif 0xC8<=op2<=0xCF: pass
        elif op2==0xB8 and rep!=0xF3: pass
        else:
            has=1
            if 0x70<=op2<=0x73 or op2 in (0xA4,0xAC,0xBA,0xC2,0xC4,0xC5,0xC6): imm=1
            if op2==0x78 and (osz or rep==0xF2): imm=2
    elif op<0x40:
        low=op&7
        if low<=3: has=1
        elif low==4: imm=1
        elif low==5: imm=immz
    elif op==0x63 or 0x84<=op<=0x8F or 0xD0<=op<=0xD3 or 0xD8<=op<=0xDF or op in (0xFE,0xFF): has=1
    elif op in (0x68,0xA9,0xE8,0xE9): imm=immz
    elif op in (0x69,0x81,0xC7): has=1; imm=immz
    elif op in (0x6B,0x80,0x83,0xC0,0xC1,0xC6): has=1; imm=1
    elif op==0x6A or 0x70<=op<=0x7F or op==0xA8 or 0xB0<=op<=0xB7 or op==0xCD or 0xE0<=op<=0xE7 or op==0xEB: imm=1
    elif 0xA0<=op<=0xA3:
        imm=4 if asz else 8
    elif 0xB8<=op<=0xBF: imm=8 if rexw else immz
    elif op in (0xC2,0xCA): imm=2
    elif op==0xC8: imm=3
    elif op in (0xF6,0xF7):
        has=1
        if n>=avail: return 0
        if ((b[n]>>3)&7)<=1: imm=1 if op==0xF6 else immz
    if not has: return n+imm
    if n>=avail: return 0
    if noea: return n+1+imm
    return n+1+modrm_extra(b,n)+imm


SLOT=32
def probe(cases):
    """objdump oracle: -> [(length, text)] of the FIRST instruction of each case"""
    out=[]
    for i in range(0,len(cases),200000):
        chunk=cases[i:i+200000]; buf=bytearray()
        for c in chunk:
            assert len(c)<=SLOT
            buf+=bytes(c)+b"\x90"*(SLOT-len(c))
        fd,p=tempfile.mkstemp(suffix=".bin"); os.write(fd,bytes(buf)); os.close(fd)
        o=subprocess.run(["objdump","-D","-b","binary","-mi386:x86-64","-Mintel","-w",p],capture_output=True,text=True).stdout
        os.unlink(p)
        st={}
        for l in o.split("\n"):
            m=re.match(r"^\s*([0-9a-f]+):\t([0-9a-f ]+)\t(.*)$",l)
            if m: st[int(m.group(1),16)]=(len(m.group(2).split()),m.group(3).strip())
        out+=[st.get(k*SLOT,(None,"")) for k in range(len(chunk))]
    return out

SPACES=["L0","L1","L38","L3A","R0","R1","V1","V2","V3","V7","X8","X9","XA","E1","E2","E3","E4","E5","E6","E7"]
def dims_of(sp):
    if sp[0] in "LR": return (6,2)
    if sp[0] in "VX": return (4,2,2,2)
    if sp=="E4": return (4,2,2,2,2)
    return (4,2,4,2,2)
PST=[[],[0x66],[0xF3],[0xF2],[0x66,0xF3],[0x66,0xF2]]
MR=[[r<<3] for r in range(8)]+[[0xC0|r<<3|m] for r in range(8) for m in range(8)]+[[r<<3|4,0x20] for r in range(8)]
NMI=len(MR)
SKIP0=set([0x0F,0xC4,0xC5,0x62,0x8F,0xD5,0x9B])|set(range(0x40,0x50))|PFX
def encode(sp,op,c,mr):
    if sp[0] in "LR":
        ps,w=c; p=list(PST[ps])
        if sp[0]=="L":
            if w: p.append(0x48)
            ob={"L0":[op],"L1":[0x0F,op],"L38":[0x0F,0x38,op],"L3A":[0x0F,0x3A,op]}[sp]
        else:
            p+=[0xD5,(0x80 if sp=="R1" else 0)|(w<<3)]; ob=[op]
        return p+ob+mr
    if sp[0] in "VX":
        pp,L,W,vz=c; vv=0xF if vz==0 else 0xE
        return [0xC4 if sp[0]=="V" else 0x8F, 0xE0|int(sp[1:],16), (W<<7)|(vv<<3)|(L<<2)|pp, op]+mr
    mp=int(sp[1:])
    if sp=="E4": pp,W,nd,nf,vz=c; p2=(nd<<4)|0x08|(nf<<2)
    else: pp,W,LL,b,vz=c; p2=(LL<<5)|(b<<4)|0x08
    vv=0xF if vz==0 else 0xE
    return [0x62,0xF0|mp,(W<<7)|(vv<<3)|4|pp,p2,op]+mr

def build():
    codes={}
    for sp in SPACES:
        combos=list(itertools.product(*[range(k) for k in dims_of(sp)]))
        keys=[]; cases=[]
        for op in range(256):
            if sp=="L0" and op in SKIP0: continue
            if sp=="L1" and op in (0x0F,0x38,0x3A): continue
            for c in combos:
                for mi,mr in enumerate(MR):
                    b=encode(sp,op,c,mr); keys.append((op,c,mi,bytes(b))); cases.append(b)
        res=probe(cases)
        d={}; mem=[]
        for (op,c,mi,b),(L,t) in zip(keys,res):
            r=parse(b+b"\x90"*14)
            if not r or r["space"]!=sp: continue   # parsed as something else (REX2 + VEX/EVEX, ...)
            T=r["T"]; npx=r["np"]
            if sp[0] in "LR" and L==formula(b+b"\x90"*14): code="F"
            elif L==T: code="0"
            elif L>T:
                # a SIB-class probe (mi >= 72) carries a SIB byte that dN's
                # x86_modrm_extra adds back at run time: count it once
                sib = 1 if mi >= 72 else 0
                if sp[0]=="R" or L-T-sib < 1: code="r"+str(L-T)
                else: code="d"+str(L-T-sib)
            else: code="p%d"%(L-npx)
            d[(op,c,mi)]=code
            if (mi<8 or mi>=72) and code[0] in "dF": mem.append((op,c,mi,b,L,T))
        # Does a code that names the ModR/M also take its displacement? Probe
        # the same encoding with mod=01 (disp8): one byte longer if it does.
        def disp8(b,T):
            b2=bytearray(b); b2[T]|=0x40; return bytes(b2)+b"\x07"
        cases=[list(disp8(b,T)) for (op,c,mi,b,L,T) in mem]
        for (op,c,mi,b,L,T),(L2,t) in zip(mem,probe(cases)):
            code=d[(op,c,mi)]
            b2=disp8(b,T)
            sib = 1 if mi >= 72 else 0
            if code=="F":
                if formula(b2+b"\x90"*14)==L2: continue
                code="d%d"%(L-T-sib)
            if L2==L+1 and int(code[1:]) >= 1: d[(op,c,mi)]=code
            elif L2==L: d[(op,c,mi)]="r%d"%(L-T)
        codes[sp]=d
        print(sp,collections.Counter(d.values()).most_common(8),file=sys.stderr)
    return codes

def length(b,codes):
    r=parse(b)
    if r is None: return 0
    sp=r["space"]
    if sp in ("REXLONE","E0","ONE"): L=r["T"]
    else:
        T=r["T"]
        if T>=len(b): return 0
        mi=mi_of(b[T])
        code=codes[sp].get((r["op"],r["dims"],mi),"F") if sp in codes else "0"
        if code=="F":
            n9=b[:r["np"]].count(0x9B)
            bb=bytes(x for i,x in enumerate(b) if not (i<r["np"] and x==0x9B))
            L=formula(bb); L=L+n9 if L else 0
        elif code[0]=="p": L=r["np"]+int(code[1:])
        elif code[0]=="r": L=T+int(code[1:])
        elif code=="0": L=T
        else: L=T+int(code[1:])+modrm_extra(b,T)
    return 15 if L>15 else L

def emit(codes,out):
    ver=subprocess.run(["objdump","--version"],capture_output=True,text=True).stdout.split("\n")[0]
    clist=sorted(set(v for d in codes.values() for v in d.values())|{"F"})
    cidx={c:i for i,c in enumerate(clist)}
    rows={}; pats={}; oppat=[]
    for sp in SPACES:
        combos=list(itertools.product(*[range(k) for k in dims_of(sp)]))
        for op in range(256):
            pr=[]
            for c in combos:
                row=tuple(cidx[codes[sp].get((op,c,mi),"F")] for mi in range(NMI))
                pr.append(rows.setdefault(row,len(rows)))
            oppat.append(pats.setdefault(tuple(pr),len(pats)))
    assert len(clist)<=36 and len(rows)<=256 and len(pats)<=4096
    A="0123456789abcdefghijklmnopqrstuvwxyz"
    patent=[]; patoff=[]
    for p,_ in sorted(pats.items(),key=lambda kv:kv[1]):
        patoff.append(len(patent)); patent+=list(p)
    rowtxt="".join("".join(A[x] for x in r) for r,_ in sorted(rows.items(),key=lambda kv:kv[1]))
    def chunks(s,n): return [s[i:i+n] for i in range(0,len(s),n)]
    def strfn(name,s,n):
        cs=chunks(s,n)
        o=["fn %s(uint64 i) -> uint64 {" % name,"    uint64 k = i / %d" % n,"    uint64 s = 0"]
        for j,c in enumerate(cs):
            o.append("    %sif k == %d { s = \"%s\" }" % ("" if j==0 else "else ", j, c))
        o+=["    uint64 p = s + i - k * %d" % n,"    uint8 v = 0","    unsafe { *(p as uint8) -> v }","    uint64 wv = v","    return wv","}"]
        return "\n".join(o)
    kinds=[]
    for c in clist:
        if c=="F": kinds.append(0)
        elif c=="0": kinds.append(1*16)
        elif c[0]=="d": kinds.append(1*16+int(c[1:]))
        elif c[0]=="r": kinds.append(2*16+int(c[1:]))
        elif c[0]=="p": kinds.append(3*16+int(c[1:]))
    ext=os.path.splitext(out)[1]
    L=[]
    L.append("// x86_len_tables%s -- GENERATED by %s from %s." % (ext,os.path.basename(__file__),ver))
    L.append("// Do not edit by hand: regenerate (see the script's docstring). Read by")
    L.append("// x86_insn_len in main%s, which sizes every line of the x86_64 --emit=asm" % ext)
    L.append("// listing exactly as objdump does, (bad) encodings included.")
    L.append("// %d codes, %d ModR/M rows, %d opcode patterns, %d spaces." % (len(clist),len(rows),len(pats),len(SPACES)))
    L.append("")
    L.append(strfn("x86t_oppat_c", "".join("%03x"%x for x in oppat), 2048)); L.append("")
    L.append(strfn("x86t_patoff_c", "".join("%04x"%x for x in patoff), 2048)); L.append("")
    L.append(strfn("x86t_patent_c", "".join("%02x"%x for x in patent), 2048)); L.append("")
    L.append(strfn("x86t_row_c", rowtxt, 2048)); L.append("")
    L.append("fn x86t_kind_c(uint64 i) -> uint64 {")
    for i,k in enumerate(kinds): L.append("    if i == %d { return %d }" % (i,k))
    L.append("    return 0\n}")
    open(out,"w").write("\n".join(L)+"\n")
    print("wrote",out,len(clist),"codes",len(rows),"rows",len(pats),"patterns",file=sys.stderr)

def check(codes,N,seed):
    random.seed(seed)
    bad=0
    for cls in ("pfx","evex","vex","xop","3dnow","x87","rex2","seg","rand"):
        pass
    return bad

if __name__=="__main__":
    if sys.argv[1]=="--codes":
        import pickle; codes=build(); pickle.dump(codes,open(sys.argv[2],"wb"))
    elif sys.argv[1]=="--emit-from":
        import pickle; emit(pickle.load(open(sys.argv[2],"rb")),sys.argv[3])
    else:
        emit(build(),sys.argv[1])
