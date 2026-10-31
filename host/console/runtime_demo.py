"""UI-facing HDMI/enrollment coordinator. The PC never runs the face models.

One caller owns this object and the transport. An explicit authorization callback
is required for board-changing commands; this module never opens any device.
Immutable model uploads, runtime gallery and source frames have distinct roles.
"""
from pathlib import Path
import hashlib,json,time
from gallery import Gallery,GalleryTransfer,load as load_gallery,BASE,CAPACITY,STRIDE
from video_session import VideoSession
from video_protocol import WRITE,ProtocolError

def file_sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()

class RuntimeDemo:
    def __init__(self,client,authorize):
        self.client,self.authorize=client,authorize
        self.video=VideoSession(client,authorize);self.transfer=GalleryTransfer(client,authorize)
        self.expected_generation=self.transfer.idle()
        self.static_fingerprint=None;self.gallery=None;self.result=None;self.embedding=None;self.started=None

    def idle(self):
        if self.video.held is not None:raise ProtocolError('Current source still owned; collect and release first')
        return self.transfer.idle(self.expected_generation)

    def upload_models(self,manifest,progress=lambda done,total:None):
        self.idle();items=[];ranges=[]
        # Verify all assets before sending the first byte, even if resident.
        for row in manifest:
            if row['kind']!='static_model':continue
            p=Path(row['path']);n=row['bytes'];a=row['address']
            if type(a)is not int or type(n)is not int or n<=0 or a%32 or a<0 or a+(n+31)//32*32>0x40000000:raise ValueError('Static model range')
            if p.stat().st_size!=n or file_sha(p)!=row['sha256']:raise ValueError('Static model hash/size changed')
            hi=a+(n+31)//32*32
            if a<BASE+32+CAPACITY*STRIDE and hi>BASE or a<0x01800000+3686400 and hi>0x01800000:raise ValueError('Static asset overlaps runtime data')
            ranges.append((a,hi));items.append(dict(row))
        if not items:raise ValueError('No immutable model assets')
        ranges.sort()
        if any(a[1]>b[0]for a,b in zip(ranges,ranges[1:])):raise ValueError('Static assets overlap')
        signature=hashlib.sha256(json.dumps([{k:r[k]for k in ('address','bytes','sha256')}for r in items],sort_keys=True).encode()).hexdigest()
        if self.static_fingerprint==signature:return dict(uploaded_bytes=0,resident=True,fingerprint=signature)
        self.static_fingerprint=None;total=sum((r['bytes']+31)//32*32 for r in items);done=0
        for row in items:
            data=Path(row['path']).read_bytes();data+=bytes((-len(data))%32)
            for offset in range(0,len(data),512):
                self.idle();blob=data[offset:offset+512]
                self.client.request(WRITE,address=row['address']+offset,length=len(blob),payload=blob)
                done+=len(blob);progress(done,total)
        self.idle();self.static_fingerprint=signature
        return dict(uploaded_bytes=done,resident=False,fingerprint=signature,
                    verification='transport physical ACK; actual CPU retains cold model CRC and hardware-invalidated residency receipt')

    def install_gallery(self,gallery):
        self.idle();receipt=self.transfer.install(gallery);self.gallery=gallery;return receipt

    def arm(self,source_manifest,frame_id,checked=None):
        if self.video.held is not None:raise ProtocolError('Current source still owned')
        checked=self.transfer.idle(self.expected_generation,observed=True) if checked is None else checked
        if self.static_fingerprint is None or self.gallery is None or self.transfer.installed is None:raise ProtocolError('Verified model/gallery installation required')
        if hashlib.sha256(self.gallery.binary()).hexdigest()!=self.transfer.installed['sha256']:raise ProtocolError('Gallery differs from installed revision')
        self.result=self.embedding=None;self.started=None
        return self.video.arm(source_manifest,frame_id,checked=checked)

    def start(self,checked=None):
        self.video.start(checked=checked);self.started=time.perf_counter()

    def collect(self, include_embedding=False,checked=None):
        result,embedding=self.video.collect(include_embedding=include_embedding,checked=checked)
        if result['gallery_revision']!=self.gallery.revision or result['gallery_count']!=len(self.gallery.records):raise ProtocolError('CPU used unexpected gallery revision/count')
        names={r.identity:r.name for r in self.gallery.records}
        if result['has_match'] and result['identity'] not in names:raise ProtocolError('CPU identity is absent from installed gallery')
        if result['accepted'] and not (result['has_face'] and result['has_match']):raise ProtocolError('Inconsistent accepted result')
        self.result=dict(result,person_name=names.get(result['identity'])if result['accepted']else None,
                         host_observed_seconds=None if self.started is None else time.perf_counter()-self.started,
                         latency_scope='host START through result download; FPGA compute cycles are separate')
        self.embedding=embedding;return dict(self.result),bytes(embedding)

    def release(self):
        if self.result is None:raise ProtocolError('Collect and verify result before releasing the source')
        after=self.video.rearm();self.expected_generation=after['generation']
        return after

    def release_for_immediate_arm(self,receipt=None):
        """Same worker/call only. Reads cannot change committed result ownership.

        A missing same-call collect receipt triggers a fresh SESSION query.
        Reuse the actual post-REARM SESSION/VIDEO_STATUS for the immediate ARM.
        Never cache ownership across worker calls or a paused run.
        Hardware still validates REARM generation/drain; a new STATUS is mandatory.
        """
        if self.result is None:raise ProtocolError('No collected result')
        after=self.video.rearm(checked_session=receipt)
        self.expected_generation=after['generation']
        session,video=self.video.last_release
        health=self.video.health()
        return self.transfer.qualify_idle(health,session,video,self.expected_generation,observed=True)

    def enroll_and_release(self,identity,name,backup,scope):
        if self.result is None or self.video.held is None:raise ProtocolError('No collected owned frame for enrollment')
        if self.result['has_face'] and not self.embedding:
            # The capture remains owned. Fetch original FPGA feature only on enrollment.
            self.collect(include_embedding=True)
        updated=self.gallery.enroll(identity,name,self.result,self.embedding,scope)
        updated.save(backup) # Save extracted bytes before releasing the source.
        self.release()
        receipt=self.install_gallery(updated)
        return dict(backup=str(Path(backup).resolve()),installation=receipt,
                    computation='FPGA feature extraction and matching; host stores and retransmits unchanged feature bytes')

    def delete(self,identity,backup):
        self.idle();updated=self.gallery.delete(identity);updated.save(backup)
        return self.install_gallery(updated)

    def restore(self,backup,new_backup):
        self.idle();restored=load_gallery(backup)
        revision=max(restored.revision,self.gallery.revision if self.gallery else 0)+1
        updated=Gallery(revision,restored.records);updated.save(new_backup)
        return self.install_gallery(updated)
