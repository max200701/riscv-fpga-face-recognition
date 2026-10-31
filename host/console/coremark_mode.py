"""Existing same-CPU benchmark mode; invoked only by the serial-owner worker."""
from pathlib import Path
import hashlib,json,struct,time,traceback,zlib
import video_protocol as protocol
from demo_console import UserInputError

original_encode=protocol.encode
def encode(op,seq,address=0,length=0,payload=b'',status=0):
    if op!=14:return original_encode(op,seq,address,length,payload,status)
    if length!=16 or len(payload)!=16:raise protocol.ProtocolError('Mode extent')
    prefix=protocol.HEADER.pack(protocol.MAGIC,1,op,status,0,seq,address,length,0)[:20]
    return prefix+struct.pack('<I',zlib.crc32(prefix+payload)&0xffffffff)+payload
protocol.encode=encode

def firmware_path():
    return Path(__file__).resolve().parent.parent.parent/'build/coremark'

def decode_benchmark(raw,mode,n):
    w=list(struct.unpack('<16I',raw));cycles=w[6]|w[7]<<32
    if w[:3]!=[0x314b4d43,1,0x26102601] or w[4]!=31250000 or w[5]!=n or not cycles:raise protocol.ProtocolError('CoreMark identity/time')
    if not(w[3]&2) or w[3]&1 or bool(w[3]&8)!=(mode==2) or w[13:]!=[2000,0,1]:raise protocol.ProtocolError('CoreMark flags/errors')
    crcs=[0x18f2,0xe3c1,0x0747,0x8d84] if mode==2 else [0xe9f5,0xe714,0x1fd7,0x8e3a]
    if w[8:12]!=crcs:raise protocol.ProtocolError('CoreMark reference CRC')
    if cycles<10*w[4] or not(w[3]&4):raise protocol.ProtocolError('CoreMark measured interval below 10 seconds')
    return dict(raw=w,cpu_Hz=w[4],iterations=n,CPU_cycles=cycles,timed_seconds=cycles/w[4],coremark_per_second=n*w[4]/cycles,coremark_per_MHz=n*1e6/cycles,crc_pass=True,mode=mode)

class CoreMarkMixin:
    def snapshot(self):
        s=super().snapshot()
        s['actions']['coremark']='请先连接并完成模型/图库资格' if not s['connected'] or not s['model_resident'] else '请先暂停连续识别并等待完成' if s['pipeline']['finishing'] or s['busy'] or s.get('auto_stage') else ''
        return s
    def action(self,name,p):
        if name!='coremark':return super().action(name,p)
        mode=p.get('mode',1)
        if type(mode) is not int or mode not in (1,2):raise UserInputError('CoreMark模式只能为1或2')
        n=p.get('iterations',2500)
        if type(n) is not int or not 2000<=n<=10000:raise UserInputError('CoreMark迭代数须为2000–10000')
        if self.pipeline.finishing or self.state.get('auto_stage'):raise UserInputError('请先暂停连续识别并等待完成')
        d=self.demo
        if not d or not d.static_fingerprint or d.gallery is None:raise UserInputError('模型/图库尚未就绪')
        if d.video.held is not None:
            if d.result is None:raise UserInputError('当前图像尚未完成')
            d.release()
        with self.pipeline.lock:self.pipeline.last_result=None
        self.state.update(result=None,auto_stage=None,coremark={'status':'RUNNING','iterations':n})
        self.frame_metrics=None;d.result=None;d.embedding=None
        firmware=firmware_path()
        manifest=json.loads((firmware/'MANIFEST.json').read_text(encoding='utf8'))
        image=firmware/'coremark_image.bin';data=image.read_bytes()
        assert hashlib.sha256(data).hexdigest()==manifest['image_sha256']
        folder=self.new_dir('coremark');folder.mkdir()
        q=dict(status='RUNNING',mode=mode,build=manifest['build'],elf_sha256=manifest['elf_sha256'],image=str(image),image_sha256=hashlib.sha256(data).hexdigest(),model_reupload_bytes=0,gallery_revision=d.gallery.revision,gallery_count=len(d.gallery.records),formal_STA_pass=False,official_submission=False)
        def save():
            (folder/'RESULT.json').write_text(json.dumps(q,ensure_ascii=False,indent=2),encoding='utf8')
        save();d.idle();self.qualification.begin()
        try:
            for offset in range(0,len(data),512):
                b=data[offset:offset+512];d.client.request(protocol.WRITE,address=0x0c000000+offset,length=len(b),payload=b)
            generation=d.idle();q['before']=d.client.snapshot();q['generation']=generation
            d.client.request(14,address=generation,length=16,payload=struct.pack('<4I',mode,n,0,0))
            d.client.start(generation);began=time.monotonic();self.event('同一CPU开始CoreMark，计时采用CPU周期计数；模型与图库保留。')
            while True:
                s=d.client.snapshot();self.state['health']=s;self.state['progress']=min(99,100*(time.monotonic()-began)/(n*.006))
                if not s['supported'] or not s['ddr_ready'] or not s['safety_ready'] or not s['temp_valid'] or s['temp_fault'] or s['over_temp'] or s['fault']:raise protocol.ProtocolError('CoreMark board health failed')
                self.notify_observation()
                if s['done']:
                    if s['cpu_status']!=1 or not s['result_committed']:raise protocol.ProtocolError('CPU did not commit benchmark')
                    break
                if time.monotonic()-began>150:raise TimeoutError('CoreMark task timeout; no replay')
                time.sleep(.1)
            raw=d.client.result_page(0);(folder/'result.bin').write_bytes(raw)
            q.update(decode_benchmark(raw,mode,n));q['observed_seconds']=time.monotonic()-began
            after=d.client.rearm(generation);d.expected_generation=after['generation']
            d.client.request(14,address=after['generation'],length=16,payload=bytes(16))
            d.idle();q.update(status='PASS',returned_face_mode=True,release=after,after=d.client.snapshot())
            self.state['coremark']=dict(q,report=str(folder/'RESULT.json'))
            self.event(f"CoreMark完成：{q['coremark_per_second']:.3f}，{q['coremark_per_MHz']:.6f}/MHz；已切回人脸模式，无需重传模型。")
        except BaseException as ex:
            q.update(status='FAILED_RETAINED',error=repr(ex),traceback=traceback.format_exc());self.state['coremark']=q;raise
        finally:
            save();self.qualification.end();self.sync()
