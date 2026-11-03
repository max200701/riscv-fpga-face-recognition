"""Offline until explicit Connect; all inference remains on the FPGA."""
from pathlib import Path
import sys,json,argparse
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'tools'))
from configure_console import configure
RUN=configure()
import demo_console as ui
from release_package import check,M,UPLOAD,PHYSICAL,PROGRAM
from run_qualification import LockedQualification
from async_records import AsyncRecords
from coremark_mode import CoreMarkMixin
from gallery import load
qualification=LockedQualification(check,M,RUN/'SOURCE_PINS.json',PHYSICAL,UPLOAD,PROGRAM)
ui.release_check=qualification.authorize
class Demo(CoreMarkMixin,ui.ConsoleCore):
 def connect(self,port):
  # Sequence namespace comes only from a successfully programmed SRAM session.
  check(M);receipt=json.loads(PROGRAM.read_text());self.sequence_path=Path(receipt['sequence_path'])
  super().connect(port)
  candidates=sorted(self.data.glob('gallery_[0-9]*'),reverse=True)
  if not candidates:return
  from resume_if_present import resume_if_present
  def progress(done,total):
   self.state['progress']=round(done*100/total,1);self.state['task_label']='正在核对驻留模型与图库';self.notify_observation()
  result=resume_if_present(self.demo,json.loads(UPLOAD.read_text()),load(candidates[0]),progress)
  self.event('驻留内容核对通过。'if result['adopted']else'请装载模型并查看状态。');self.state['task_label']='';self.sync()
ap=argparse.ArgumentParser();ap.add_argument('--http-port',type=int,default=8783);args=ap.parse_args()
core=Demo(RUN/'data',ROOT/'05_tests/fixtures/reference',M)
core.qualification=qualification;core.recorder=AsyncRecords();core.sequence_path=RUN/'not_programmed_sequence.json'
core.select_display('WIN32_TK_EXACT_FRAME','default')
core.state.update(mode='QO DEBUG136 · 尚未连接',formal_STA_pass=True,board_acceptance='LOCAL_SESSION_NOT_YET_VALIDATED',console_version='QO92 submission',bitstream_sha256='bedb89fe470c9978afb61905c3fc1a2f19d17840de8c9859a81415729709063d')
server=ui.Server(args.http_port,core)
print('http://127.0.0.1:'+str(args.http_port)+'/',flush=True)
try:server.serve_forever()
finally:core.close();qualification.end();core.recorder.close();server.server_close()
