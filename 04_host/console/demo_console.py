"""Local demonstration console. Source/display/control only, no face inference.

Offline by default. Serial is imported/opened only after an explicit connection
request and the project's completed physical release record has been checked.
One worker owns the transport. Source pixels remain immutable while leased.
"""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit,parse_qs
import struct
import sys
import argparse,base64,copy,hashlib,importlib.util,json,queue,re,secrets,subprocess,threading,time,uuid
from gallery import Gallery,CAPACITY
from runtime_demo import RuntimeDemo
from video_protocol import BOARD_BUILD,PersistentSequence,ProtocolError
from video_session import VideoClient,FLAG_NAMES
from ux_flow import display_diagnostics,action_policy,next_step
from display_sources import DisplaySources,NATIVE,BROWSER
from host_pipeline import HostPipeline
from prefetched_sequence import PrefetchedSequence
from async_serial_records import AsyncLoggedSerial

H=Path(__file__).resolve().parent; E=H.parent; R=E.parent
PY_IMAGE=sys.executable
spec=importlib.util.spec_from_file_location('op_source_assets',E/'source/source_server.py')
asset_module=importlib.util.module_from_spec(spec); spec.loader.exec_module(asset_module)
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()

class UserInputError(ValueError):
    """Local request rejected before any hardware mutation; lease remains valid."""
    pass

def person_id(value):
    try:
        if isinstance(value,bool):raise ValueError()
        identity=int(value)
        if str(identity)!=str(value) or not 0<identity<=0xffffffff:raise ValueError()
        return identity
    except (ValueError,TypeError):raise UserInputError('人员编号必须为 1..4294967295 的整数') from None

def release_check(path):
    if path is None:raise RuntimeError('尚无正式位流发布记录；当前控制台仅离线准备。')
    p=Path(path); d=json.loads(p.read_text(encoding='utf8')); physical=E
    if d.get('status')!='SRAM_REVIEW_PASS' or d.get('candidate_id')!=physical.name or d.get('board_build_id')!=f'{BOARD_BUILD:08x}':raise RuntimeError('发布候选或 ABI 不符')
    if sha(d['bitstream'])!=d['bitstream_sha256'] or sha(physical/'firmware_build01/demo.elf')!=d['firmware_sha256'] or sha(physical/'firmware01/UPLOAD.json')!=d['upload_manifest_sha256']:raise RuntimeError('发布文件哈希不符')
    # This record is produced by the project's final route/STA/release review,
    # never by this UI. Browser diagnostics cannot create or bypass it.
    return d

class LoggedSerial:
    def __init__(self,link,folder):
        self.link=link;self.tx=self.rx=self.transactions=None
        try:
            self.transactions=(folder/'transactions.jsonl').open('x',encoding='utf8',buffering=1)
            self.tx=(folder/'serial_tx.bin').open('xb');self.rx=(folder/'serial_rx.bin').open('xb')
        except Exception:self.close();raise
    def record_transaction(self,row):self.transactions.write(json.dumps(dict(row,t=time.perf_counter()))+'\n')
    def read(self,n):
        b=self.link.read(n);self.rx.write(b);return b
    def write(self,b):
        n=self.link.write(b);self.tx.write(b[:n]);return n
    def flush(self):
        # Serial.write uses Win32 GetOverlappedResult with write_timeout=3 and the
        # protocol verifies the exact byte count. The matched reply proves FPGA
        # receipt; driver out_waiting polling adds 50ms without strengthening ACK.
        # This adapter is only used with the blocking Windows serial configuration.
        self.tx.flush();self.rx.flush()
    def close(self):
        try:self.link.close()
        finally:
            if self.tx:self.tx.close()
            if self.rx:self.rx.close()
            if self.transactions:self.transactions.close()

class ConsoleCore:
    def __init__(self,data,source,release=None,connector=None):
        self.data=Path(data);self.data.mkdir(parents=True,exist_ok=True)
        self.release=release;self.connector=connector;self.demo=None;self.link=None;self.sequences=None;self.report=None
        self.recorder=None;self.qualification=None;self._immediate_arm_checked=None
        self.sequence_path=self.data/'sequence.json';self.auto_deadline=0
        self.display_sources=DisplaySources();self.changed=threading.Condition();self.revision=0;self.frame_metrics=None
        self.state=dict(connected=False,busy=False,mode='离线准备',candidate_id=E.name,board_build_id=f'{BOARD_BUILD:08x}',model_resident=False,gallery=[],gallery_revision=None,
                        result=None,health=None,video=None,progress=0,held=False,events=[],error=None,auto_stage=None,task_label='')
        self.source_id=secrets.randbelow(0x7fffffff);self.set_source(source)
        self.pipeline=HostPipeline(self)
        self._public_key=None
    def notify(self):
        with self.changed:
            self.revision+=1;self.changed.notify_all()
    def notify_observation(self):
        # Wake UI for decisions/results, not every changing DDR byte counter.
        s=self.state;h=s.get('health') or {};v=s.get('video') or {};r=s.get('result') or {}
        key=(s.get('connected'),s.get('busy'),s.get('error'),s.get('auto_stage'),s.get('progress'),
             s.get('task_label'),s.get('held'),s.get('model_resident'),s.get('gallery_revision'),
             tuple(r.get('raw',())),r.get('generation'),
             tuple(h.get(k) for k in ('phase','temperature_C','over_temp','temp_fault','fault','result_committed','ddr_ready','safety_ready','temp_valid')),
             tuple(v.get(k) for k in ('session_generation','errors')+FLAG_NAMES))
        if key!=self._public_key:self._public_key=key;self.notify()
    def event(self,text):
        row=dict(time=time.strftime('%H:%M:%S'),message=text)
        self.state['events']=(self.state['events']+[row])[-40:]
        self.append_record(self.data/'events.jsonl',row)
    def append_record(self,path,row):
        if self.recorder:self.recorder.submit('append',path,row)
        else:
            with path.open('a',encoding='utf8') as f:f.write(json.dumps(row,ensure_ascii=False)+'\n')
    def check_records(self):
        if self.recorder:self.recorder.check()
    def set_source(self,folder):
        if self.demo:self.demo.idle()
        manifest,assets=asset_module.load_assets(folder)
        self.source_id+=1;self.source=(manifest,assets);self.report=None
        self.state.update(source_id=self.source_id,source_sha=manifest['files']['frame.rgb']['sha256'],source_crc=manifest['files']['frame.rgb']['crc32'],result=None)
    def manifest(self):return dict(self.source[0],source_id=self.source_id)
    def display_report(self,report):
        # Diagnostic only: cannot authorize a serial connection or physical release.
        with self.display_sources.lock:
            self.display_sources.put(report);self.report=self.display_sources.current()
        if self.frame_metrics and self.frame_metrics.get('source_id',self.source_id)==self.source_id and report.get('source_id')==self.source_id and self.display_ready():
            self.frame_metrics.setdefault('display_ready',time.perf_counter())
        self.pipeline.note_display()
        self.notify()
    def select_display(self,provider,instance):
        if self.demo and self.demo.video.held:raise UserInputError('当前帧仍被持有，释放后才能切换显示源。')
        with self.display_sources.lock:
            try:self.display_sources.select(provider,instance)
            except ValueError as e:raise UserInputError(str(e)) from None
            self.report=self.display_sources.current()
    def display_ready(self):
        return display_diagnostics(self)['ready']
    def backups(self):
        return [p.name for p in sorted(self.data.glob('gallery_*')) if (p/'metadata.json').is_file()]
    def snapshot(self):
        self.sync()
        with self.display_sources.lock:
            display=display_diagnostics(self);selection=self.display_sources.summary()
        value=dict(self.state,revision=self.revision,display_ready=display['ready'],display=display,display_selection=selection,backups=self.backups(),
             hardware_connection_enabled=self.release is not None,model_inference_on_PC=False,
             display_scope='Selected source pixels and window geometry only; actual HDMI capture is separately qualified')
        value['pipeline']=self.pipeline.snapshot()
        value['actions']=action_policy(value,display,value['backups']);value['next_step']=next_step(value,display)
        if value['pipeline']['finishing']:
            value['actions']={k:'连续流水运行中，请先暂停并等待本帧完成。' for k in value['actions']}
            value['next_step']='电脑准备下一帧，FPGA 计算当前帧；结果显示独立推进。'
        return copy.deepcopy(value)
    def sync(self):
        d=self.demo
        self.state.update(connected=d is not None,model_resident=bool(d and d.static_fingerprint),held=bool(d and d.video.held),
                          gallery=[]if not d or not d.gallery else [dict(identity=r.identity,name=r.name)for r in d.gallery.records],
                          gallery_revision=None if not d or not d.gallery else d.gallery.revision)
    def preserve_health_failure(self,error):
        snapshot=getattr(error,'health_snapshot',None)
        if snapshot is None:return
        record=dict(time=time.time(),health=copy.deepcopy(snapshot),message=str(error),board_reset=False,release_issued=False)
        self.state['previous_health']=copy.deepcopy(snapshot);self.state['last_board_fault']=record
        path=self.new_dir('board_fault').with_suffix('.json')
        path.write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf8')
        self.state['last_board_fault_path']=str(path)
    def close(self):
        if hasattr(self,'pipeline'):self.pipeline.abort('connection_closed')
        try:
            if self.link:self.link.close()
        finally:
            if self.sequences:self.sequences.close()
            self.demo=self.link=self.sequences=None
            self.state.update(mode='离线准备',health=None,video=None,result=None,auto_stage=None,progress=0)
            self.sync()
    def connect(self,port):
        if self.demo:raise UserInputError('先断开当前连接')
        if self.connector:
            client,authorize=self.connector(port);self.demo=RuntimeDemo(client,authorize);self.state['mode']='显式测试传输（非实板）'
        else:
            release_check(self.release)
            if not isinstance(port,str)or not re.fullmatch(r'COM[1-9][0-9]*',port.upper()):raise UserInputError('COM 端口格式')
            folder=self.new_dir('session');folder.mkdir()
            try:
                self.sequences=PrefetchedSequence(self.sequence_path)
                import serial
                raw=serial.Serial(port=None,baudrate=921600,timeout=.05,write_timeout=3)
                try:
                    raw.dtr=False;raw.rts=False;raw.port=port;raw.open()
                except BaseException:
                    raw.close();raise
                self.link=AsyncLoggedSerial(raw,folder)
                client=VideoClient(self.link,self.sequences)
                from reconnect_session import recover_idle
                def record_reconnect(value):
                    with (folder/'reconnect.jsonl').open('a',encoding='utf8') as log:
                        log.write(json.dumps(value,ensure_ascii=False)+'\n')
                        log.flush()
                receipt=recover_idle(client,lambda:release_check(self.release),record_reconnect)
                self.demo=RuntimeDemo(client,lambda:release_check(self.release))
                self.state['reconnect_receipt']=receipt
            except Exception:
                self.close();raise
            self.state['mode']='实板连接；计算由 FPGA 执行'
        self.sync();self.event('已连接，驻留标记从空状态开始。')
    def new_dir(self,prefix):return self.data/(prefix+'_'+time.strftime('%Y%m%d_%H%M%S_')+uuid.uuid4().hex[:8])
    def poll(self):
        if not self.demo:return
        self.check_records();collect_receipt=None
        d=self.demo;s,v=d.video.check();self.state.update(health=s,video=v)
        if v['session_generation']!=d.expected_generation:raise ProtocolError('Unexpected session generation')
        if self.state['auto_stage']=='capture':
            d.video.matched(v)
            if v.get('rejected') or v.get('errors'):
                self.state['auto_stage']=None
                raise UserInputError('板端拒绝本帧采集；请查看诊断并按真实停止/恢复状态处理，当前帧未擅自释放。')
            if v['frame_ready'] and v['start_permitted']:
                self.state['auto_stage']='compute';self.auto_deadline=time.monotonic()+120
                if self.frame_metrics:self.frame_metrics['capture_ready_observed']=time.perf_counter()
                d.start(checked=(s,v))
                if self.frame_metrics:self.frame_metrics['start_ack']=time.perf_counter()
                self.event('完整帧已写入 DDR，自动启动 FPGA 检测与识别。')
            elif time.monotonic()>self.auto_deadline:
                self.state['auto_stage']=None
                raise UserInputError('等待 HDMI 完整帧超时。连接和帧所有权已保留；检查图像窗口及 HDMI 信号后可手动继续。')
        elif self.state['auto_stage']=='compute' and not v['result_ready'] and time.monotonic()>self.auto_deadline:
            self.state['auto_stage']=None
            raise UserInputError('计算等待超过 120 秒，保留连接及帧所有权，继续查询真实结果；未重发 START。')
        if d.video.held and v['result_ready'] and d.result is None:
            if self.frame_metrics:self.frame_metrics['result_ready_observed']=time.perf_counter()
            result,embedding=d.collect(checked=(s,v))
            collect_receipt=getattr(d.client,'last_collect_session',None)
            self.state['health']=d.video.health() # New phase: correlate committed result with a post-collection health sample.
            if self.frame_metrics and 'start_ack' in self.frame_metrics:
                m=self.frame_metrics;m['collected']=time.perf_counter()
                keys=['received','source_published','display_ready','arm_ack','start_ack','collected']
                if all(k in m for k in keys):
                    result['host_pipeline_ms']={b:round((m[b]-m[a])*1000,3) for a,b in zip(keys,keys[1:])}
                    result['host_pipeline_ms']['total']=round((m['collected']-m['received'])*1000,3)
            folder=self.new_dir('result')
            if self.recorder:self.recorder.submit('result',folder,result,bytes(embedding))
            else:
                folder.mkdir()
                (folder/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
                (folder/'embedding.bin').write_bytes(embedding)
            self.state['result']=result;self.state['auto_stage']=None;self.event('CPU 已提交，来源与结果摘要已核对。可登记本次人脸，或释放换图。')
        self.pipeline.tick(collect_receipt=collect_receipt)
        self.sync()
    def action(self,name,p):
        if not self.pipeline.finishing and name in ('image','camera_frame','recognize','arm','release','enroll','delete','restore','disconnect'):
            with self.pipeline.lock:self.pipeline.last_result=None
        self.state['error']=None
        if name=='resume':
            from resident_resume import resume
            from gallery import load
            if not self.demo:raise UserInputError('请先连接开发板')
            candidates=sorted(self.data.glob('gallery_[0-9]*'),reverse=True)
            if not candidates:raise UserInputError('没有可核对的本地图库备份，请装载模型并重新登记。')
            def progress(done,total):self.state['progress']=round(done*100/total,1)
            result=resume(self.demo,json.loads((R/'runtime/UPLOAD.json').read_text()),load(candidates[0]),self.demo.expected_generation,progress)
            (self.new_dir('resume_receipt').with_suffix('.json')).write_text(json.dumps(result,indent=2)+'\n')
            self.event('已逐字节读回核对全部驻留模型与图库，无需重传模型。')
        elif name=='camera_frame':
            from camera_assets import prepare
            self.frame_metrics={'received':p.get('_submitted',time.perf_counter())}
            if self.demo and self.demo.video.held and self.state['result'] is None:raise UserInputError('上一帧尚未完成')
            try:manifest,assets=prepare(p['rgb'] if 'rgb' in p else base64.b64decode(p['data'],validate=True),p['token'])
            except (ValueError,TypeError,KeyError) as e:raise UserInputError(str(e)) from None
            if self.demo and self.demo.video.held:self.demo.release()
            # No board mutation here; release verified ACK and ARM rechecks the idle owner.
            self.source_id+=1;self.source=(manifest,assets);self.report=None
            self.state.update(source_id=self.source_id,source_sha=manifest['files']['frame.rgb']['sha256'],source_crc=manifest['files']['frame.rgb']['crc32'],result=None,camera_frame_token=p['token'])
            self.frame_metrics['source_published']=time.perf_counter()
        elif name=='select_display':
            self.select_display(p['provider'],p['source_instance']);self.event('已显式选择显示源：'+p['provider'])
        elif name=='connect':self.connect(p['port'])
        elif name=='disconnect':self.close();self.event('已断开。没有自动停止板端任务；重连不沿用驻留假设。')
        elif name=='image':
            if self.demo and self.demo.video.held and self.state['result'] is None:raise UserInputError('当前帧尚未完成，请等待结果后换图。')
            try:raw=base64.b64decode(p['data'],validate=True)
            except (ValueError,TypeError):raise UserInputError('图片编码无效') from None
            if not 0<len(raw)<=16*1024*1024:raise UserInputError('图片大小应小于 16 MiB')
            folder=self.new_dir('image');folder.mkdir();(folder/'source').write_bytes(raw)
            command=[PY_IMAGE,str(E/'source/prepare_source.py'),str(folder/'prepared'),'--image',str(folder/'source')]
            with (folder/'prepare.log').open('xb')as log:
                proc=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=60,creationflags=0x08000000)
            if proc.returncode:raise UserInputError('无法读取这张图片，请选择 PNG/JPEG；原图与日志已保存，连接保持。')
            if self.demo and self.demo.video.held:
                self.demo.release();self.state['result']=None;self.event('已按实际 REARM 确认释放上一帧，再更换图片。')
            self.set_source(folder/'prepared');self.event('新图片已准备；仅缩放、补边和像素格式转换。')
        else:
            if not self.demo:raise RuntimeError('需要已通过发布检查的实际连接')
            d=self.demo
            if name=='upload':
                items=json.loads((R/'runtime/UPLOAD.json').read_text(encoding='utf8'))
                receipt=d.upload_models(items,lambda n,total:self.state.update(progress=round(100*n/total,1)))
                if d.gallery is None:d.install_gallery(Gallery(1))
                self.event('模型已驻留；本次写入 '+str(receipt['uploaded_bytes'])+' 字节。图库初始为空。')
            elif name in ('arm','recognize'):
                self.check_records()
                if not self.display_ready():raise UserInputError('HDMI 画布尚未就绪；请检查全屏、640×480 和当前图片')
                if not d.static_fingerprint or d.gallery is None:raise UserInputError('请先装载模型和初始化图库。')
                checked=self._immediate_arm_checked;self._immediate_arm_checked=None
                d.arm(self.manifest(),self.source_id,checked=checked)
                if self.frame_metrics:self.frame_metrics['arm_ack']=time.perf_counter()
                self.state['result']=None;self.event('采集已请求；等待板端真实 frame_ready。')
                if name=='recognize':self.state['auto_stage']='capture';self.auto_deadline=time.monotonic()+15
            elif name=='start':d.start();self.event('已启动 FPGA 检测和识别；等待 CPU 提交。')
            elif name=='qualify_pixels':
                self.source[1]['input.bin'] # Materialize exact reference only for explicit readback.
                d.video.source['files']['input.bin']=self.source[0]['files']['input.bin']
                self.event(json.dumps(d.video.qualify_pixels(),ensure_ascii=False))
            elif name=='release':d.release();self.state['result']=None;self.state['auto_stage']=None;self.event('已释放本帧，模型与图库驻留。')
            elif name=='enroll':
                identity=person_id(p.get('identity'));person=p.get('name')
                if not isinstance(person,str)or not person.strip()or len(person.strip())>80:raise UserInputError('请输入 1–80 字的人员名称')
                if d.result is None or not d.result.get('has_face')or d.video.held is None:raise UserInputError('需要已收齐结果的当前人脸')
                if len(d.gallery.records)>=CAPACITY and identity not in {r.identity for r in d.gallery.records}:raise UserInputError('图库已满，最多 16 人')
                backup=self.new_dir('gallery')
                d.enroll_and_release(identity,person.strip(),backup,'offline_fixture'if self.connector else 'board')
                self.state['result']=None;self.event('登记已备份并写回板端：'+backup.name)
            elif name=='delete':
                identity=person_id(p.get('identity'))
                if not d.gallery or identity not in {r.identity for r in d.gallery.records}:raise UserInputError('图库中没有该人员编号')
                d.delete(identity,self.new_dir('gallery'));self.event('删除后的图库已写入并读回核对。')
            elif name=='restore':
                key=p['backup']
                if not isinstance(key,str)or key not in self.backups():raise UserInputError('请选择已有的图库备份；首次登记前没有备份。')
                d.restore(self.data/key,self.new_dir('gallery'));self.event('备份已恢复，图库版本已递增。')
            elif name=='stop':d.video.stop();self.event('已请求停止采集，所有权保持至真实排空。')
            elif name=='recover':d.video.recover();self.event('已请求恢复，等待真实释放确认。')
            elif name=='release_recovered':d.video.release_observed();self.event('已确认采集恢复后的释放。')
            else:raise ValueError('Unknown action')
        self.sync()

class Worker(threading.Thread):
    def __init__(self,core):super().__init__(daemon=True);self.core=core;self.queue=queue.Queue(maxsize=1)
    def run(self):
        while True:
            action=None
            # Clear BEFORE inspecting queue/pipeline. A later event stays set;
            # never erase a new frame/display wake between poll and wait.
            self.core.pipeline.wake.clear()
            try:
                try:action,p=self.queue.get_nowait()
                except queue.Empty:
                    self.core.poll()
                    if not self.core.state['auto_stage']:
                        self.core.notify_observation()
                        self.core.pipeline.wake.wait(.1) # Idle health deadline; events wake immediately.
                    continue
                self.core.state['busy']=True;self.core.state['task_label']=dict(upload='正在装载模型，请保持供电和 USB 连接。',resume='正在逐字节读回核对板上模型与图库，不重新上传…',image='正在准备图片…',camera_frame='正在准备摄像头帧…',enroll='正在读取 FPGA 特征并登记…').get(action,'正在执行 '+action)
                self.core.action(action,p)
            except UserInputError as e:
                self.core.state['error']=str(e);self.core.event(str(e))
            except Exception as e:
                try:self.core.preserve_health_failure(e)
                except Exception as archive_error:self.core.state['fault_archive_error']=str(archive_error)
                self.core.state['error']=str(e)
                try:self.core.event(str(e))
                except Exception as log_error:self.core.state['error']+='; log failure: '+str(log_error)
                # No whole-command retries. On live errors residency/ownership
                # can be indeterminate; close the link, retain logs and backups.
                self.core.close()
            finally:
                self.core.state['busy']=False;self.core.state['task_label']=''
                if action:self.queue.task_done()
                self.core.notify_observation()

class Server(ThreadingHTTPServer):
    daemon_threads=True
    request_queue_size=64
    def __init__(self,port,core):
        self.core=core;self.nonce=secrets.token_hex(24);self.worker=Worker(core)
        super().__init__(('127.0.0.1',port),Handler)
        self.worker.start()

class Handler(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def setup(self):
        super().setup()
        import socket
        self.connection.settimeout(12)
        self.connection.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
    def log_message(self,*a):pass
    def reply(self,status,value,mime='application/json; charset=utf-8'):
        b=value if isinstance(value,bytes)else json.dumps(value,ensure_ascii=False).encode()
        self.send_response(status);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(b)))
        self.send_header('Cache-Control','no-store');self.send_header('X-Content-Type-Options','nosniff');self.end_headers();self.wfile.write(b)
    def valid_host(self):return self.headers.get('Host')==f'127.0.0.1:{self.server.server_port}'
    def do_GET(self):
        if not self.valid_host():
            self.close_connection=True;return self.reply(403,{'error':'host'})
        path=self.path.partition('?')[0];c=self.server.core
        if path in ('/','/coremark','/source'):
            page=H/('index.html'if path in ('/','/coremark') else 'source.html')
            return self.reply(200,page.read_bytes().replace(b'__NONCE__',self.server.nonce.encode()),'text/html; charset=utf-8')
        if path in ('/layout.js','/layout.css','/frame_metrics.js'):return self.reply(200,(H/path[1:]).read_bytes(),'text/css' if path.endswith('.css') else 'text/javascript; charset=utf-8')
        if path in ('/console.js','/camera.js'):return self.reply(200,(H/path[1:]).read_bytes().replace(b'__NONCE__',self.server.nonce.encode()),'text/javascript; charset=utf-8')
        if path=='/state':
            q=parse_qs(urlsplit(self.path).query)
            if 'after' in q:
                with c.changed:c.changed.wait_for(lambda:c.revision!=int(q['after'][0]),timeout=2)
            return self.reply(200,c.snapshot())
        if path=='/source-frame':
            q=parse_qs(urlsplit(self.path).query);previous=int(q.get('after',['-1'])[0])
            with c.changed:
                c.changed.wait_for(lambda:c.source_id!=previous,timeout=1)
                sid=c.source_id;manifest,assets=c.source
                meta=json.dumps(dict(manifest,source_id=sid,nonce=self.server.nonce)).encode()
                rgb=assets['frame.rgb'] if sid!=previous else b''
            return self.reply(200,struct.pack('<I',len(meta))+meta+rgb,'application/octet-stream')
        if path=='/result-frame.rgb':
            try:return self.reply(200,c.pipeline.preview(parse_qs(urlsplit(self.path).query)['sha'][0]),'application/octet-stream')
            except (KeyError,ValueError):return self.reply(404,{'error':'Result frame expired'})
        if path=='/manifest':return self.reply(200,c.manifest())
        if path=='/frame.rgb':return self.reply(200,c.source[1]['frame.rgb'],'application/octet-stream')
        if path=='/frame.png':return self.reply(200,c.source[1]['frame.png'],'image/png')
        if path=='/backups':return self.reply(200,[p.name for p in sorted(c.data.glob('gallery_*'))if(p/'metadata.json').is_file()])
        self.reply(404,{'error':'not found'})
    def do_POST(self):
        if not self.valid_host()or self.headers.get('Origin')!=f'http://127.0.0.1:{self.server.server_port}':
            self.close_connection=True;return self.reply(403,{'error':'origin'})
        try:
            size=int(self.headers.get('Content-Length','0'))
            if not 0<size<=23*1024*1024:raise ValueError('body length')
            raw=self.rfile.read(size)
            if self.path in ('/camera-frame','/pipeline/frame'):
                if size!=921600:raise ValueError('RGB extent')
                p=dict(nonce=self.headers.get('X-Console-Nonce'),token=self.headers.get('X-Frame-Token'),action='camera_frame',rgb=raw)
            else:p=json.loads(raw)
            if p.pop('nonce',None)!=self.server.nonce:return self.reply(403,{'error':'token'})
            if self.path.startswith('/pipeline/'):
                pipe=self.server.core.pipeline
                try:
                    if self.path=='/pipeline/start':value=pipe.begin(p['run_id'],p.get('max_frames'))
                    elif self.path=='/pipeline/stop':value=pipe.stop(p['run_id'])
                    elif self.path=='/pipeline/frame':
                        value=pipe.feed(self.headers.get('X-Pipeline-Run'),int(self.headers.get('X-Pipeline-Sequence','0')),raw)
                    else:return self.reply(404,{'error':'not found'})
                    return self.reply(200,value)
                except ValueError as e:return self.reply(409,{'error':str(e)})
            if self.path=='/display-report':self.server.core.display_report(p);return self.reply(200,{'saved':True})
            if self.path not in ('/action','/camera-frame'):return self.reply(404,{'error':'not found'})
            if self.server.core.state['busy']or not self.server.worker.queue.empty():return self.reply(409,{'error':'busy'})
            name=p.pop('action');policy=self.server.core.snapshot()['actions']
            if name not in policy:return self.reply(400,{'error':'未知操作'})
            if policy[name]:return self.reply(409,{'error':policy[name]})
            p['_submitted']=time.perf_counter();self.server.worker.queue.put_nowait((name,p));self.server.core.pipeline.wake.set();self.reply(202,{'queued':True})
        except (ValueError,TypeError,KeyError,queue.Full)as e:
            self.close_connection=True;self.reply(400,{'error':str(e)})

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=8780)
    parser.add_argument('--data',type=Path,default=H/'console_data')
    parser.add_argument('--source',type=Path,default=R/'05_tests/fixtures/reference')
    parser.add_argument('--release',type=Path,help='Qualified current-candidate BOARD_RELEASE.json; absent means offline only')
    args=parser.parse_args();core=ConsoleCore(args.data,args.source,args.release);server=Server(args.port,core)
    print(f'Console http://127.0.0.1:{server.server_port}/ ; disconnected; no inference on PC',flush=True)
    try:server.serve_forever()
    finally:core.close();server.server_close()
