"""Bounded PC overlap. Only the existing serial worker invokes tick().

Preparing RGB is independent. HDMI may change only after the current capture's
identity and full-frame receipt have been checked. ARM/REARM remain serialized
by the real board protocol. No model computation occurs here.
"""
from collections import OrderedDict,deque
import copy,json,threading,time
from camera_assets import prepare


class HostPipeline:
    def __init__(self,core):
        self.c=core;self.lock=threading.RLock();self.wake=threading.Event()
        self.enabled=False;self.finishing=False;self.run_id=None;self.pending=None
        self.display=None;self.active=None;self.last_record=None;self.views=OrderedDict()
        self.completed=0;self.accepted=0;self.replaced=0;self.last_result=None
        self.started=None;self.ended=None;self.heartbeat=0;self.last_sequence=0
        self.last_collected=None;self.stop_reason=None;self.max_frames=None
        self.intervals=deque(maxlen=20)

    def begin(self,run_id,max_frames=None):
        with self.lock:
            c=self.c
            if self.enabled or self.finishing:raise ValueError('Pipeline already active')
            if not isinstance(run_id,str) or not 1<=len(run_id)<=80:raise ValueError('Run identity')
            if max_frames is not None and (type(max_frames)is not int or not 1<=max_frames<=1000):raise ValueError('Frame limit')
            if not c.demo or not c.demo.static_fingerprint or c.demo.gallery is None:raise ValueError('Verified models/gallery required')
            if c.state['busy'] or c.state['auto_stage'] or (c.demo.video.held and c.demo.result is None):raise ValueError('Finish current operation first')
            if c.state['error']:raise ValueError('Resolve current error first')
            c.check_records()
            if c.qualification:c.qualification.begin()
            self.enabled=True;self.finishing=True;self.run_id=run_id
            self.pending=self.display=self.active=None;self.completed=self.accepted=self.replaced=0
            self.last_sequence=0;self.started=time.perf_counter();self.ended=None
            self.heartbeat=time.monotonic();self.stop_reason=None;self.max_frames=max_frames
            self.last_collected=None;self.last_result=None
            self.intervals.clear()
            self.wake.set();c.notify()
            return self.snapshot()

    def feed(self,run_id,sequence,rgb):
        # Hash/format preparation is in the HTTP thread, never in the UART worker.
        token=run_id+':'+str(sequence)
        received=time.perf_counter();manifest,assets=prepare(rgb,token)
        with self.lock:
            if not self.enabled or run_id!=self.run_id:raise ValueError('Inactive or obsolete run')
            if type(sequence)is not int or sequence<=self.last_sequence:raise ValueError('Late or duplicate frame sequence')
            self.heartbeat=time.monotonic();self.last_sequence=sequence;self.accepted+=1
            if self.pending is not None:self.replaced+=1
            self.pending=dict(token=token,manifest=manifest,assets=assets,metrics={'received':received,'prepared':time.perf_counter()})
            self.wake.set()
            return {'accepted':True,'token':token,'queue_capacity':1,'replaced':self.replaced}

    def stop(self,run_id,reason='user_pause'):
        with self.lock:
            if run_id!=self.run_id:raise ValueError('Obsolete run')
            self.enabled=False;self.pending=None;self.stop_reason=reason
            self.wake.set();self.c.notify()
            return self.snapshot()

    def abort(self,reason):
        with self.lock:
            self.enabled=False;self.finishing=False;self.pending=None
            self.stop_reason=reason;self.ended=time.perf_counter();self.wake.set()
            if self.c.qualification:self.c.qualification.end()

    def snapshot(self):
        with self.lock:
            end=self.ended or time.perf_counter()
            return dict(enabled=self.enabled,finishing=self.finishing,run_id=self.run_id,
                completed=self.completed,accepted=self.accepted,replaced=self.replaced,
                fps=self.completed/(end-self.started) if self.started and end>self.started else 0,
                recent_fps=len(self.intervals)/sum(self.intervals) if self.intervals else None,
                interval_ms=self.intervals[-1]*1000 if self.intervals else None,
                active_token=self.active['token'] if self.active else None,
                display_token=self.display['token'] if self.display else None,
                pending_token=self.pending['token'] if self.pending else None,
                phase='capture' if self.active and not self.active.get('captured') else 'compute' if self.active and not self.active.get('done') else 'handoff' if self.enabled else 'paused',
                last_result=copy.deepcopy(self.last_result),stop_reason=self.stop_reason,
                queue_capacity=1,board_frames_in_flight=1 if self.active and not self.active.get('done') else 0)

    def note_display(self):
        with self.lock:
            if self.display and self.display.get('source_id')==self.c.source_id and self.c.display_ready():
                self.display['metrics'].setdefault('display_ready',time.perf_counter())
            self.wake.set()

    def preview(self,sha):
        with self.lock:
            if sha not in self.views:raise ValueError('Result frame expired')
            return self.views[sha]

    def publish(self,record):
        c=self.c
        # Caller proved capture complete or there is no unfinished capture.
        with c.changed:
            c.source_id+=1;record['source_id']=c.source_id
            c.source=(record['manifest'],record['assets']);c.report=None
            f=record['manifest']['files']['frame.rgb']
            c.state.update(source_id=c.source_id,source_sha=f['sha256'],source_crc=f['crc32'],camera_frame_token=record['token'])
            record['metrics']['source_published']=time.perf_counter()
            self.display=record;c.notify()

    def tick(self,collect_receipt=None):
        """Serial-owner thread only; called after an actual health/video observation."""
        with self.lock:
            c=self.c;d=c.demo
            if not self.finishing or not d:return
            c.check_records()
            if self.enabled and time.monotonic()-self.heartbeat>8:
                self.enabled=False;self.pending=None;self.stop_reason='source_heartbeat_expired'
            a=self.active
            if a and not a.get('captured') and (c.state['auto_stage']=='compute' or c.state['result'] is not None):
                v=c.state['video'];d.video.matched(v)
                if not v['frame_ready'] or v['errors'] or v['rejected']:raise ValueError('No valid full-frame receipt for overlap')
                a['captured']=True;a['metrics']['capture_confirmed']=time.perf_counter()
            if a and not a.get('done') and c.state['result'] is not None:
                r=c.state['result']
                if r['source_rgb_sha256']!=a['manifest']['files']['frame.rgb']['sha256'] or r['video_source']['frame']!=a['source_id']:
                    raise ValueError('Pipeline result/source mismatch')
                now=time.perf_counter();a['done']=True;self.completed+=1;self.last_record=a
                r['camera_frame_token']=a['token']
                r['pipeline_timing_ms']=dict(
                    prepared_to_arm=(a['metrics']['arm_ack']-a['metrics']['prepared'])*1000,
                    capture_to_start=(a['metrics']['start_ack']-a['metrics']['arm_ack'])*1000,
                    start_to_collected=(now-a['metrics']['start_ack'])*1000,
                    complete_interval=None if self.last_collected is None else (now-self.last_collected)*1000,
                    next_display_overlapped=bool(self.display is not a and self.display and 'display_ready' in self.display['metrics']))
                if self.last_collected is not None:self.intervals.append(now-self.last_collected)
                self.last_collected=now;self.last_result=copy.deepcopy(r)
                sha=r['source_rgb_sha256'];self.views[sha]=a['assets']['frame.rgb'];self.views.move_to_end(sha)
                while len(self.views)>3:self.views.popitem(last=False)
                c.append_record(c.data/'pipeline_results.jsonl',dict(run_id=self.run_id,index=self.completed,time=now,result=r,metrics=a['metrics']))
                if self.max_frames and self.completed>=self.max_frames:
                    self.enabled=False;self.pending=None;self.stop_reason='frame_limit'
                c.notify()
            if not self.enabled:
                if a and not a.get('done'):return # Finish actual in-flight task; never cancel/overwrite it.
                if a and self.display is not a:self.publish(a) # Paused final image stays available for enrollment.
                self.pending=None;self.finishing=False;self.ended=time.perf_counter()
                if c.qualification:c.qualification.end()
                c.sync();c.notify();return
            # During capture the HDMI image is immutable. During compute, the
            # previously captured DDR source remains immutable independently.
            if a and not a.get('captured'):return
            # Freeze the already displayed next frame at handoff. Newly prepared
            # pixels remain in a bounded latest slot for the following task.
            done=a is None or a.get('done')
            if self.pending is not None and (not done or self.display is None or self.display is a):
                record=self.pending;self.pending=None;self.publish(record)
            if not done or self.display is None or self.display is a:return
            if not c.display_ready():return
            record=self.display;record['metrics'].setdefault('display_ready',time.perf_counter())
            checked=None
            if d.video.held:
                if d.result is None:raise ValueError('Cannot release before committed result collection')
                if a and a.get('done') and collect_receipt is not None:
                    checked=d.release_for_immediate_arm(collect_receipt)
                else:checked=d.release_for_immediate_arm()
            c.frame_metrics=record['metrics'];c.frame_metrics['source_id']=record['source_id']
            c._immediate_arm_checked=checked
            try:c.action('recognize',{})
            finally:c._immediate_arm_checked=None
            record['captured']=False;record['done']=False;self.active=record
            c.notify()
