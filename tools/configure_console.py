"""Create package-relative host configuration. Does not access hardware."""
from pathlib import Path
import json,hashlib,argparse
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def configure():
 run=ROOT/'runtime';run.mkdir(exist_ok=True)
 upload=json.loads((ROOT/'03_models/UPLOAD.json').read_text());upload=[dict(r,path=str(ROOT/r['path']))for r in upload]
 (run/'UPLOAD.json').write_text(json.dumps(upload,indent=2))
 h=ROOT/'04_host/console';pins={str(p):sha(p)for p in h.iterdir()if p.suffix in ('.py','.js','.css','.html')}
 (run/'SOURCE_PINS.json').write_text(json.dumps(pins,indent=2))
 bit=ROOT/'08_bitstreams/QO/mini_face_demo_QO_DEBUG136.sbit';gate=ROOT/'07_docs/QO_TIMING_EVIDENCE.json'
 values={str(p):sha(p)for p in (bit,gate)}
 values.update({r['path']:r['sha256']for r in upload})
 (run/'RELEASE.json').write_text(json.dumps(dict(status='QO_DEBUG136_PACKAGED_SOURCE_RELEASE',bitstream=str(bit),bitstream_sha256=sha(bit),timing_review=str(gate),pins=values),indent=2))
 (run/'data').mkdir(exist_ok=True)
 return run
if __name__=='__main__':print(configure())
