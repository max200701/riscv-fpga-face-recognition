"""Validate immutable release files and a fresh local SRAM programming receipt."""
from pathlib import Path
import json,hashlib
from pin_cache import PinCache
ROOT=Path(__file__).resolve().parents[2];RUN=ROOT/'runtime';M=RUN/'RELEASE.json'
UPLOAD=RUN/'UPLOAD.json';PHYSICAL=ROOT/'07_docs/QO_TIMING_EVIDENCE.json';PROGRAM=RUN/'program_receipt.json'
EXPECTED='bedb89fe470c9978afb61905c3fc1a2f19d17840de8c9859a81415729709063d'
cache=PinCache()
def check(path):
 q=json.loads(Path(path).read_text())
 if q['status']!='QO_DEBUG136_PACKAGED_SOURCE_RELEASE' or q['bitstream_sha256']!=EXPECTED:raise RuntimeError('Release identity mismatch')
 for p,h in q['pins'].items():
  if cache.sha(p)!=h:raise RuntimeError('Release file changed: '+p)
 for p,h in json.loads((RUN/'SOURCE_PINS.json').read_text()).items():
  if cache.sha(p)!=h:raise RuntimeError('Host source changed: '+p)
 t=json.loads(PHYSICAL.read_text())
 if len(t['timing'])!=8 or any(x['failed']for x in t['timing'].values()):raise RuntimeError('Timing evidence mismatch')
 if not PROGRAM.exists():raise RuntimeError('请先用 tools/program_sram.py 下载本包 QO 位流；当前仅离线浏览。')
 r=json.loads(PROGRAM.read_text())
 if r.get('status')!='SRAM_PROGRAM_PASS_NOT_APPLICATION_ACCEPTANCE' or r.get('sha256')!=EXPECTED or r.get('flash_written')is not False:raise RuntimeError('Programming receipt mismatch')
 return q
