"""Build only in a fresh output directory. Never operate the board."""
from pathlib import Path
import argparse,hashlib,json,struct,subprocess,zlib
ROOT=Path(__file__).resolve().parents[1]
def sections(p):
 d=p.read_bytes()
 if d[:6]!=b'\x7fELF\x01\x01' or struct.unpack_from('<H',d,18)[0]!=243:raise ValueError('Expected little-endian ELF32 RISC-V')
 shoff=struct.unpack_from('<I',d,32)[0];step,count=struct.unpack_from('<HH',d,46);rows=[]
 for i in range(count):
  _,typ,flags,addr,off,size,*_=struct.unpack_from('<10I',d,shoff+i*step)
  rows.append((typ,flags,addr,size,d[off:off+size]))
 return struct.unpack_from('<I',d,24)[0],rows
def main():
 p=argparse.ArgumentParser();p.add_argument('kind',choices=['face','coremark']);p.add_argument('--cc',required=True);a=p.parse_args()
 out=ROOT/'build'/a.kind
 if out.exists():raise SystemExit('Output exists: choose a fresh checkout or retain/move prior build yourself')
 cmd=json.loads((ROOT/'firmware'/f'{a.kind}_command.json').read_text())
 cmd=[x.replace('{CC}',a.cc).replace('{REPO}',str(ROOT)).replace('{OUT}',str(out))for x in cmd]
 from check_dependencies import check
 prefixes=['external/libgcc']+(['external/coremark']if a.kind=='coremark'else[])
 missing=[r for r in check(prefixes)if r['status']!='OK']
 if missing:raise SystemExit(json.dumps(missing,indent=2))
 out.mkdir(parents=True);(out/'command.json').write_text(json.dumps(cmd,indent=2))
 with(out/'compile.log').open('w')as f:subprocess.run(cmd,check=True,stdout=f,stderr=subprocess.STDOUT,timeout=180)
 entry,rows=sections(out/f'{a.kind}.elf')
 if a.kind=='face':
  rom=bytearray(65536);bss_end=0
  for typ,flags,addr,size,data in rows:
   if flags&2 and size:
    if addr<65536:
     if addr+size>65536 or typ==8:raise ValueError('ROM bounds/type')
     rom[addr:addr+size]=data
    else:bss_end=max(bss_end,addr+size)
  if bss_end>0x1f000:raise ValueError('RAM bound')
  target=out/'application_rom.hex';target.write_text(''.join(f'{int.from_bytes(rom[i:i+4],"little"):08x}\n'for i in range(0,len(rom),4)),newline='\n')
  want=next(r['sha256']for r in json.loads((ROOT/'docs/external_files.json').read_text())if r['path']=='hardware/application_rom.hex')
  # Original Windows Path.write_text used CRLF. Compare normalized ROM words as
  # well as exact original bytes; keep CRLF output to reproduce the pinned file.
  target.write_bytes(target.read_bytes().replace(b'\r\n',b'\n').replace(b'\n',b'\r\n'))
  if hashlib.sha256(target.read_bytes()).hexdigest()!=want:raise SystemExit('Built ROM differs from board source: retained for diagnosis, not qualified')
 else:
  image=bytearray(0xe000);last=0;end=0
  for typ,flags,addr,size,data in rows:
   if not(flags&2)or not size:continue
   if addr<0x10000 or addr+size>0x1e000:raise ValueError('CoreMark bounds')
   end=max(end,addr+size)
   if typ!=8:image[addr-0x10000:addr-0x10000+size]=data;last=max(last,addr-0x10000+size)
  last=(last+3)&~3;image=bytes(image[:last]);h=struct.pack('<7I',0x31494d43,1,0x10000,last,entry,end,zlib.crc32(image)&0xffffffff);h+=struct.pack('<I',zlib.crc32(h)&0xffffffff)
  data=h+image+bytes(-len(image)%32);(out/'coremark_image.bin').write_bytes(data)
  (out/'MANIFEST.json').write_text(json.dumps(dict(build='local-unqualified',image_sha256=hashlib.sha256(data).hexdigest(),elf_sha256=hashlib.sha256((out/'coremark.elf').read_bytes()).hexdigest()),indent=2))
 print('Build complete; this is not execution or board qualification:',out)
if __name__=='__main__':main()
