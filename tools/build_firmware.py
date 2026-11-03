"""Rebuild one firmware using the recorded flags and a user-supplied compiler."""
from pathlib import Path
import argparse,json,os,subprocess,struct,time
ROOT=Path(__file__).resolve().parents[1]
def sections(path):
 d=path.read_bytes();assert d[:6]==b'\x7fELF\x01\x01' and struct.unpack_from('<H',d,18)[0]==243
 off=struct.unpack_from('<I',d,32)[0];step,n=struct.unpack_from('<HH',d,46);r=[]
 for i in range(n):
  _,typ,flags,addr,pos,size,*_=struct.unpack_from('<10I',d,off+i*step)
  if flags&2:r.append((typ,addr,size,None if typ==8 else d[pos:pos+size].hex()))
 return r
def main():
 ap=argparse.ArgumentParser();ap.add_argument('target');ap.add_argument('--cc',required=True,type=Path);ap.add_argument('--output',type=Path);a=ap.parse_args()
 src=ROOT/'02_firmware'/a.target;out=(a.output or ROOT/'build'/('firmware_'+a.target+'_'+str(time.time_ns()))).resolve();out.mkdir(parents=True,exist_ok=False)
 tmp=out/'tmp';tmp.mkdir();cc=a.cc.resolve();assert cc.is_file()
 args=[v.replace('${CC}',str(cc)).replace('${ROOT}',str(ROOT)).replace('${OUT}',str(out)) for v in json.loads((src/'command.json').read_text())]
 env=dict(os.environ,TEMP=str(tmp),TMP=str(tmp),TMPDIR=str(tmp),PATH=str(cc.parent)+os.pathsep+os.environ['PATH'])
 (out/'command.json').write_text(json.dumps(args,indent=2),encoding='utf8')
 with (out/'build.log').open('w')as f:subprocess.run(args,cwd=out,env=env,stdout=f,stderr=subprocess.STDOUT,check=True,timeout=180)
 exe=Path(args[args.index('-o')+1]);reference=src/'prebuilt'/exe.name
 same=sections(exe)==sections(reference)
 result=dict(target=a.target,ELF_allocated_sections_equal=same,reference=str(reference.relative_to(ROOT)),board_test=False)
 (out/'RESULT.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
 if not same:raise SystemExit('Executable differs: do not substitute it for the measured firmware.')
if __name__=='__main__':main()
