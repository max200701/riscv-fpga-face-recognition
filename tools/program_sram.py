"""Explicit temporary SRAM programming. Never writes configuration Flash."""
from pathlib import Path
import argparse,json,hashlib,os,re,socket,subprocess,time,urllib.request,urllib.error
ROOT=Path(__file__).resolve().parents[1]
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--pds-bin',type=Path,required=True);ap.add_argument('--target',choices=['QO','CM'],default='QO');ap.add_argument('--program',action='store_true',help='Explicitly replace volatile FPGA configuration');a=ap.parse_args()
 if not a.program:raise SystemExit('No action. Add --program to explicitly configure SRAM; power cycling loses this configuration.')
 try:
  with urllib.request.urlopen('http://127.0.0.1:8783/state',timeout=2)as f:q=json.load(f)
  if q.get('connected') or q.get('busy') or q.get('pipeline',{}).get('enabled') or q.get('pipeline',{}).get('finishing'):raise RuntimeError('Disconnect the console and finish/release its frame before programming.')
 except urllib.error.URLError as e:
  if not isinstance(e.reason,ConnectionRefusedError) and getattr(e.reason,'winerror',None)!=10061:raise
 from configure_console import configure
 run=configure();out=run/('program_'+str(time.time_ns()));out.mkdir();tmp=out/'tmp';tmp.mkdir()
 bit=next((ROOT/'08_bitstreams'/a.target).glob('*.sbit'));h=hashlib.sha256(bit.read_bytes()).hexdigest()
 manifest=json.loads((ROOT/'SHA256SUMS.json').read_text());assert manifest[str(bit.relative_to(ROOT)).replace('\\','/')]==h
 bin=a.pds_bin.resolve();env=dict(os.environ,TEMP=str(tmp),TMP=str(tmp),TMPDIR=str(tmp))
 with socket.socket()as sock:sock.bind(('127.0.0.1',65420))
 server=None
 try:
  with(out/'server.log').open('w')as f:
   server=subprocess.Popen([str(bin/'cdt_js.exe'),'-port','65420','-work_dir',str(out)],cwd=out,env=env,stdout=f,stderr=subprocess.STDOUT,creationflags=0x08000000);time.sleep(.8)
   def execute(name,commands):
    t=out/(name+'.tcl');t.write_text('\n'.join(commands)+'\n')
    with(out/(name+'.log')).open('w')as log:r=subprocess.run([str(bin/'cdt_cfg_shell.exe'),'-file',str(t)],cwd=out,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=240,creationflags=0x08000000)
    text=(out/(name+'.log')).read_text(errors='replace');assert not r.returncode and not re.search(r'(?m)^E:',text)
    assert 'The ID value is: 0x00603899'in text and 'PG2L200H'in text
    regs=re.findall(r'Status Register: 0x([0-9a-fA-F]+)',text);assert len(regs)==1
    reg=int(regs[0],16);assert not reg&(1<<27),'Over-temperature flag'
    return text,reg
   head=['cfg_set_tcl_break -flag true','cfg_connect -ip 127.0.0.1 -port 65420','cfg_set_cable_property -index 0 -freq 1Mhz','cfg_scan_chain','cfg_read_device_property -device_index 0 -mode 0']
   tail=['cfg_read_device_property -device_index 0 -mode 3','cfg_disconnect','cfg_close']
   execute('inspect',head+tail)
   text,reg=execute('program',head+['cfg_assign_file -device_index 0 -file {'+bit.as_posix()+'}','cfg_program -device_index 0']+tail)
   assert reg&(1<<12) and not reg&0x0800001f and 'Executing : cfg_program -device_index 0 successfully.'in text
  record=dict(status='SRAM_PROGRAM_PASS_NOT_APPLICATION_ACCEPTANCE',target=a.target,sha256=h,flash_written=False,status_register=hex(reg),sequence_path=str(out/'sequence.json'),finished=time.time())
  (out/'RESULT.json').write_text(json.dumps(record,indent=2))
  (run/'program_receipt.json').write_text(json.dumps(record,indent=2))
  print(json.dumps(record))
 finally:
  if server is not None and server.poll()is None:
   server.terminate()
   try:server.wait(timeout=10)
   except subprocess.TimeoutExpired:server.kill();server.wait()
if __name__=='__main__':main()
