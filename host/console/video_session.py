"""OM HDMI command API. No device opens; callers supply transport/authorization."""
import struct,zlib
from video_protocol import Client,ProtocolError,READ,VIDEO_ARM,VIDEO_STATUS,VIDEO_STOP,VIDEO_RECOVER

FLAG_NAMES=('start_permitted','application_selected','video_reserved','capture_busy','frame_ready','rejected','recovery_ready','waiting_source_stop','source_stopped','arm_permitted','stop_permitted','recover_permitted','result_ready','rx_configured','rx_stream_candidate','rx_fault')
def parse_video(data):
    w=list(struct.unpack('<16I',data))
    if w[:2]!=[0x31444956,1] or w[2]&~0xffff or w[10] not in (0,1):raise ProtocolError('VIDEO_STATUS identity')
    out=dict(raw=w,session_generation=w[3],next_capture_generation=w[4],held_capture_generation=w[5],held_frame_id=w[6],held_session_generation=w[7],pixels=w[8],writes=w[9],result_source_id=w[10],result_session_generation=w[11],result_capture_generation=w[12],result_frame_id=w[13],errors=w[14],rx_raw_status=w[15])
    out.update({name:bool(w[2]&(1<<i)) for i,name in enumerate(FLAG_NAMES)})
    return out

class VideoClient(Client):
    def video_status(self):return parse_video(self.request(VIDEO_STATUS))

class VideoSession:
    def __init__(self,client,authorize):
        self.client,self.authorize=client,authorize
        self.source=None;self.held=None
    def health(self):
        s=self.client.snapshot()
        if not s['supported']:raise ProtocolError('QG build26102420 required')
        if not(s['ddr_ready'] and s['safety_ready'] and s['temp_valid']) or s['temp_fault'] or s['over_temp'] or s['fault']:
            raise ProtocolError('Board health not qualified')
        return s
    def check(self):return self.health(),self.client.video_status()
    def arm(self,source_manifest,frame_id,checked=None):
        self.authorize();s,v=self.check() if checked is None else checked
        if self.held is not None or not v['arm_permitted'] or v['video_reserved'] or s['phase']!=0:raise ProtocolError('Not idle video BOOT')
        if v['next_capture_generation']==0xffffffff or type(frame_id) is not int or not 0<=frame_id<=0xffffffff:raise ProtocolError('Generation/frame range')
        if (source_manifest['width'],source_manifest['height'])!=(640,480):raise ProtocolError('Source geometry')
        payload=struct.pack('<4I',frame_id,v['next_capture_generation'],0,0)
        self.client.request(VIDEO_ARM,address=v['session_generation'],length=16,payload=payload)
        self.held=dict(session=v['session_generation'],capture=v['next_capture_generation'],frame=frame_id)
        self.source=source_manifest
        return dict(status='ARM_ACK_NOT_FRAME_READY',**self.held)
    def matched(self,v):
        if self.held is None or [v['held_session_generation'],v['held_capture_generation'],v['held_frame_id']]!=[self.held[k] for k in ('session','capture','frame')]:
            raise ProtocolError('Video source/generation changed')
    def frame(self,checked=None):
        _,v=self.check() if checked is None else checked;self.matched(v)
        if not v['frame_ready'] or v['errors'] or v['rejected'] or not v['video_reserved']:raise ProtocolError('Capture incomplete/rejected')
        return v
    def qualify_pixels(self):
        """Optional first-board qualification; full UART readback is slow."""
        s,v=self.check();self.matched(v)
        if s['phase']!=0 or not v['frame_ready'] or v['application_selected']:raise ProtocolError('Readback requires captured BOOT')
        crc=0;size=640*480*3*4
        for offset in range(0,size,512):
            b=self.client.request(READ,address=0x01800000+offset,length=min(512,size-offset));crc=zlib.crc32(b,crc)
        self.frame()
        got=f'{crc&0xffffffff:08x}';expected=self.source['files']['input.bin']['crc32']
        if got!=expected:raise ProtocolError('HDMI pixel/color/geometry CRC mismatch')
        return dict(status='ACTUAL_READBACK_CRC_MATCH_IF_REAL_LINK',bytes=size,crc32=got,scope='Only this capture; not inference acceptance')
    def start(self,checked=None):
        self.authorize();v=self.frame(checked=checked)
        if not v['start_permitted']:raise ProtocolError('START not permitted')
        self.client.start(self.held['session'])
    def collect(self, include_embedding=True,checked=None):
        _,v=self.check() if checked is None else checked;self.matched(v)
        if not v['result_ready'] or v['result_source_id']!=1 or [v['result_session_generation'],v['result_capture_generation'],v['result_frame_id']]!=[self.held[k] for k in ('session','capture','frame')]:raise ProtocolError('Result source mismatch')
        if hasattr(self.client,'collect_from_video'):
            result,embedding=self.client.collect_from_video(self.held['session'],v,include_embedding=include_embedding)
        else:result,embedding=self.client.collect(self.held['session'], include_embedding=include_embedding)
        after=self.client.video_status();self.matched(after)
        for key in ('result_source_id','result_session_generation','result_capture_generation','result_frame_id'):
            if v[key]!=after[key]:raise ProtocolError('Result source changed while collecting')
        result.update(video_source=dict(self.held),source_rgb_sha256=self.source['files']['frame.rgb']['sha256'])
        return result,embedding
    def rearm(self,checked_session=None):
        self.authorize()
        if self.held is None:raise ProtocolError('No owned capture')
        if checked_session is not None:
            value=self.client.rearm_checked(self.held['session'],checked_session)
        else:value=self.client.rearm(self.held['session'])
        v=self.client.video_status()
        if v['video_reserved']:raise ProtocolError('REARM did not release capture')
        self.last_release=(value,v)
        self.held=None;self.source=None;return value
    def stop(self):
        self.authorize();_,v=self.check();self.matched(v)
        if not v['stop_permitted']:raise ProtocolError('STOP unavailable')
        self.client.request(VIDEO_STOP,address=self.held['capture'])
    def recover(self):
        self.authorize();_,v=self.check();self.matched(v)
        if not v['recover_permitted'] or not v['source_stopped']:raise ProtocolError('Real stop/drain not acknowledged')
        self.client.request(VIDEO_RECOVER,address=self.held['capture'])
        # ACK means requested; retain ownership until caller observes actual release.
    def release_observed(self):
        _,v=self.check()
        if self.held is None or v['video_reserved'] or not v['arm_permitted']:raise ProtocolError('Release not complete')
        if v['session_generation']!=self.held['session']:raise ProtocolError('Recovery altered session')
        self.held=None;self.source=None
