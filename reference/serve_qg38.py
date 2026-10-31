"""QG experimental board console; host provides pixels/control, never inference."""
from pathlib import Path
import hashlib,json,sys
H=Path(__file__).resolve().parent;E=H.parent;R=E.parent
# Install pyserial from requirements.txt instead of a private wheel path.
import demo_console as ui
from pin_cache import PinCache
from run_qualification import LockedQualification
from async_records import AsyncRecords
from gallery import load,BASE,sha
from video_protocol import READ
pins=PinCache();M=H/'RELEASE33.json';UPLOAD=R/'pm_release_execution01/assets02/UPLOAD.json'
def check(path):
    q=json.loads(Path(path).read_text(encoding='utf8'))
    assert q['status']=='QG_EXPERIMENTAL_BOARD_TESTED_CONSOLE' and q['formal_STA_pass'] is False
    assert q['bitstream_sha256']=='209c34e7e704ec0977f88b6bd275f679e0c16099cc2a28233131d08de605413c'
    for p,h in q['pins'].items():assert pins.sha(p)==h,p
    for p,h in json.loads((H/'SOURCE_PINS.json').read_text(encoding='utf8')).items():assert pins.sha(p)==h,p
    for row in json.loads(UPLOAD.read_text(encoding='utf8')):
        if row['kind']=='static_model':assert pins.sha(row['path'])==row['sha256'],row['path']
    return q
check(M)
qualification=LockedQualification(check,M,H/'SOURCE_PINS.json',E/'experimental_release28/package/MANIFEST.json',UPLOAD,E/'board32/program01/RESULT.json')
ui.release_check=qualification.authorize
from coremark_mode import CoreMarkMixin
class QGConsole(CoreMarkMixin,ui.ConsoleCore):
    def connect(self,port):
        super().connect(port)
        cfg=json.loads((H/'handoff01/CONFIG.json').read_text(encoding='utf8'))
        prior=json.loads((H/'handoff01/IDLE.json').read_text(encoding='utf8'))
        s,v=self.demo.video.check();session=self.demo.client.session()
        if not (session['generation']==cfg['generation'] and s['read_bytes']==prior['health']['read_bytes'] and s['write_bytes']==prior['health']['write_bytes']):
            self.event('本次连接不符合一次性交接凭据，未继承模型或图库资格。');return
        self.demo.idle();gallery=load(cfg['gallery']);blob=gallery.binary()
        got=b''.join(self.demo.client.request(READ,address=BASE+i,length=min(512,len(blob)-i)) for i in range(0,len(blob),512))
        if got!=blob:raise RuntimeError('Current gallery handoff differs')
        items=[r for r in json.loads(UPLOAD.read_text(encoding='utf8')) if r['kind']=='static_model'];tested=0
        for r in items:
            data=Path(r['path']).read_bytes();data+=bytes(-len(data)%32)
            for offset in sorted(set([0,len(data)-min(512,len(data))])):
                want=data[offset:offset+512]
                if self.demo.client.request(READ,address=r['address']+offset,length=len(want))!=want:raise RuntimeError('Model handoff edge differs')
                tested+=len(want)
        self.demo.idle()
        self.demo.static_fingerprint=hashlib.sha256(json.dumps([{k:r[k] for k in ('address','bytes','sha256')} for r in items],sort_keys=True).encode()).hexdigest()
        self.demo.gallery=gallery
        self.demo.transfer.installed=dict(generation=cfg['generation'],revision=gallery.revision,count=len(gallery.records),sha256=sha(blob),bytes=len(blob),scope='Immediate exclusive-owner handoff; matched generation/counters, whole gallery and model edges')
        receipt=dict(status='QG38_EXCLUSIVE_HANDOFF_PASS',model_reupload_bytes=0,gallery_revision=gallery.revision,gallery_count=len(gallery.records),model_edge_bytes=tested,generation=cfg['generation'])
        (H/'data/HANDOFF38.json').write_text(json.dumps(receipt,indent=2),encoding='utf8')
        self.event('已接续当前模型与最新图库；同一CPU CoreMark入口可用。');self.sync()
config=json.loads((H/'handoff01/CONFIG.json').read_text(encoding='utf8'))
core=QGConsole(H/'data',config['source'],M);core.qualification=qualification;core.recorder=AsyncRecords()
core.sequence_path=E/'board32/sequence.json'
core.select_display('WIN32_TK_EXACT_FRAME','default')
core.state.update(mode='QG实验联调 · 尚未连接',formal_STA_pass=False,board_acceptance='fixed_image_numerical_pass_HDMI_pending',console_version='QG38')
server=ui.Server(8783,core)
print('QG38 http://127.0.0.1:8783/; explicit experimental board test, no PC inference',flush=True)
try:server.serve_forever()
finally:core.close();qualification.end();core.recorder.close();server.server_close()
