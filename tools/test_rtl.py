from pathlib import Path
import argparse,subprocess,os,time
ROOT=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser();ap.add_argument('--iverilog',required=True,type=Path);ap.add_argument('--vvp',required=True,type=Path);a=ap.parse_args()
out=ROOT/'build'/('rtl_short_'+str(time.time_ns()));out.mkdir(parents=True)
env=dict(os.environ,TEMP=str(out),TMP=str(out),PATH=str(a.iverilog.resolve().parent)+os.pathsep+os.environ['PATH'])
for tb,module in [('tb_modes.sv','demo_packet_endpoint.sv'),('tb_results.sv','demo_result_store.sv')]:
 exe=out/(tb+'.vvp')
 subprocess.run([str(a.iverilog),'-g2012','-s','tb','-o',str(exe),str(ROOT/'05_tests/rtl'/tb),str(ROOT/'01_hardware/QO/rtl'/module)],check=True,env=env,cwd=out)
 subprocess.run([str(a.vvp),str(exe)],check=True,env=env,cwd=out,timeout=60)
