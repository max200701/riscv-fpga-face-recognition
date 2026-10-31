"""Two real QB RTL ABI tests, under Icarus; not a full inference test."""
from pathlib import Path
import argparse,subprocess
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--iverilog',default='iverilog');p.add_argument('--vvp',default='vvp');a=p.parse_args()
out=ROOT/'build/rtl_smoke';out.mkdir(parents=True,exist_ok=False)
for name,rtl in [('modes','demo_packet_endpoint.sv'),('results','demo_result_store.sv')]:
 exe=out/(name+'.vvp')
 cmd=[a.iverilog,'-g2012','-s','tb','-o',str(exe),str(ROOT/'tests/rtl'/f'tb_{name}.sv'),str(ROOT/'hardware/rtl'/rtl)]
 subprocess.run(cmd,check=True,timeout=60)
 subprocess.run([a.vvp,str(exe)],check=True,timeout=60)
print('RTL_SMOKE_PASS; does not establish full application, PNR or board acceptance')
