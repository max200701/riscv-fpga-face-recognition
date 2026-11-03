"""Build/run the frozen five-face -> CoreMark -> face RTL regression.
This takes substantial time. No FPGA or proprietary PDS implementation is run.
"""
from pathlib import Path
import argparse,os,sys,shutil,subprocess,json,hashlib,time,concurrent.futures,re
ROOT=Path(__file__).resolve().parents[1]
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--verilator',type=Path,required=True);ap.add_argument('--verilator-root',type=Path,required=True);ap.add_argument('--cxx',type=Path,required=True);ap.add_argument('--pango-lib',type=Path,required=True);ap.add_argument('--run',action='store_true');a=ap.parse_args()
 out=ROOT/'build'/('rtl_'+str(time.time_ns()));out.mkdir(parents=True);s=out/'source';shutil.copytree(ROOT/'05_tests/full_application/source',s);obj=out/'obj';obj.mkdir();job=out/'run';shutil.copytree(ROOT/'05_tests/full_application/fixtures',job);tmp=out/'tmp';tmp.mkdir()
 for p in s.glob('*'):
  if p.suffix in ('.v','.sv','.vh'):
   t=p.read_text();t=re.sub(r'"(application_rom\.hex|sigmoid(?:_even|_odd)?\.hex)"',lambda m:'"'+(s/m[1]).as_posix()+'"',t);p.write_text(t)
 env=dict(os.environ,TEMP=str(tmp),TMP=str(tmp),TMPDIR=str(tmp),VERILATOR_ROOT=str(a.verilator_root.resolve()),PATH=str(a.cxx.resolve().parent)+os.pathsep+os.environ['PATH'])
 def run(cmd,cwd,log):
  with log.open('w')as f:subprocess.run(list(map(str,cmd)),cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
 libs=[a.pango_lib/n for n in ('GTP_GRS.v','GTP_RAM32X2DP.v','GTP_DRM18K_E1.v')];assert all(x.is_file()for x in libs)
 run([a.verilator,'--cc','--Mdir',obj,'--top-module','demo_board_logic','--timing','-Wno-fatal','--output-split','16000','--output-split-cfuncs','500','-GNATIVE=0','+define+PM_SIM_OBSERVER','+incdir+'+str(s),*s.glob('*.v'),*s.glob('*.sv'),*libs],out,out/'verilate.log')
 sources=[*obj.glob('*.cpp'),*[a.verilator_root/'include'/n for n in ('verilated.cpp','verilated_timing.cpp','verilated_threads.cpp')],s/'driver.cpp']
 def compile_one(p):
  o=obj/(p.stem+'.o');run([a.cxx,'-std=c++20','-O2','-DNDEBUG','-DVL_TIME_CONTEXT','-I'+str(obj),'-I'+str(a.verilator_root/'include'),'-I'+str(a.verilator_root/'include/vltstd'),'-c',p,'-o',o],out,obj/(p.stem+'.log'));return o
 with concurrent.futures.ThreadPoolExecutor(4)as pool:objects=list(pool.map(compile_one,sources))
 rsp=out/'link.rsp';rsp.write_text('\n'.join('"'+str(x)+'"'for x in objects));exe=out/'simulation.exe';run([a.cxx,'@'+str(rsp),'-o',exe],out,out/'link.log')
 if a.run:
  pins={str(p):hashlib.sha256(p.read_bytes()).hexdigest()for p in [*s.glob('*'),*job.glob('*'),*list((ROOT/'03_models').glob('*'))]if p.is_file()}
  (job/'PINNED_INPUTS.json').write_text(json.dumps(pins,indent=2))
  env.update(DEMO_HDMI='1',DDR_FIRST_LATENCY='40',PP_PIPELINE='1',PW_SWITCHBACK='1',QN_WRAP_PRECONDITION='1')
  for k in ('DEMO_PREFLIGHT_ONLY','FLOW_CHECKPOINT_SMOKE','PW_COREMARK_ONLY','DEMO_RUNTIME_FAULT','PW_BAD_IMAGE'):env.pop(k,None)
  run([exe,'750'],job,job/'run.log');run([sys.executable,'-B',ROOT/'05_tests/full_application/review.py',job],out,out/'numeric.log')
 print(out)
if __name__=='__main__':main()
