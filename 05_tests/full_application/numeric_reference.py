"""Independent integer/IEEE reference for actual CPU L2, gallery and UART pages.
No model computation, reference crop or feature is inserted into the simulation.
"""
from pathlib import Path
import argparse,hashlib,json,math,struct,zlib
E=Path(__file__).resolve().parent;R=E.parent
def f32(u):return struct.unpack('<f',struct.pack('<I',u))[0]
def u32(f):return struct.unpack('<I',struct.pack('<f',f))[0]
def part(u,fraction,exponent,bias):
    e=(u>>fraction)&((1<<exponent)-1);m=(u&((1<<fraction)-1))|((1<<fraction)if e else 0)
    return (-m if u>>(fraction+exponent)else m),(e-bias-fraction)if e else(1-bias-fraction)
def rounded_positive(n,base,fraction,bias):
    if not n:return 0
    cut=max(n.bit_length()-fraction-1,1-bias-fraction-base);cut=max(cut,0)
    q=n>>cut;rem=n-(q<<cut)
    if cut and(rem>(1<<(cut-1))or rem==(1<<(cut-1))and q&1):q+=1
    e=cut+base+fraction
    if q>=(1<<(fraction+1)):q>>=1;e+=1
    if q<(1<<fraction):return q
    return ((e+bias)<<fraction)|(q&((1<<fraction)-1))
def square_add(x,a):
    ux=struct.unpack('<Q',struct.pack('<d',x))[0];ua=struct.unpack('<Q',struct.pack('<d',a))[0]
    mx,ex=part(ux,52,11,1023);ma,ea=part(ua,52,11,1023)
    assert math.isfinite(x)and math.isfinite(a)and a>=0
    n=(mx*mx<<(2*ex+2148))+(ma<<(ea+2148))
    return struct.unpack('<d',struct.pack('<Q',rounded_positive(n,-2148,52,1023)))[0]
def normalize(values):
    assert len(values)==512 and all(math.isfinite(v)for v in values)
    a=[[0.0]*8 for _ in range(4)]
    for k in range(16):
        for j in range(4):
            for l in range(8):a[j][l]=square_add(values[32*k+8*j+l],a[j][l])
    c=[a[0][l]+a[0][l+4]for l in range(4)]
    for j in range(1,4):
        for l in range(4):c[l]=c[l]+(a[j][l]+a[j][l+4])
    norm=math.sqrt((c[0]+c[2])+(c[1]+c[3]));assert norm>=1e-12
    return [f32(u32(v/norm))for v in values]
def fma(a,b,c):
    ma,ea=part(a,23,8,127);mb,eb=part(b,23,8,127);mc,ec=part(c,23,8,127)
    n=(ma*mb<<(ea+eb+298))+(mc<<(ec+298))
    if not n:return ((c>>31)<<31)if not(ma*mb)and not mc and ((a^b)>>31)==(c>>31)else 0
    return(0x80000000 if n<0 else 0)|rounded_positive(abs(n),-298,23,127)
def dot(x,y):
    w=[0]*127
    for i in range(512):w[i%64]=fma(u32(x[i]),u32(y[i]),w[i%64])
    for j in range(4):
        for l in range(8):w[64+8*j+l]=fma(w[16*j+l],0x3f800000,w[16*j+l+8])
    for l in range(8):
        w[96+l]=fma(w[64+l],0x3f800000,w[72+l]);w[104+l]=fma(w[96+l],0x3f800000,w[80+l]);w[112+l]=fma(w[104+l],0x3f800000,w[88+l])
    for l in range(4):w[120+l]=fma(w[112+l],0x3f800000,w[116+l])
    w[124]=fma(w[120],0x3f800000,w[121]);w[125]=fma(w[122],0x3f800000,w[123]);v=fma(w[124],0x3f800000,w[125])
    return f32(v)if v&0x7fffffff else 0.0
