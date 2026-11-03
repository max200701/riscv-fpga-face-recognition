"""Explicit idle handoff: read every resident model byte; never assume residency."""
from pathlib import Path
import hashlib,json
from video_protocol import READ,ProtocolError
from gallery import BASE,sha

class ResidentBytesMismatch(ProtocolError):
    pass

def resume(demo,manifest,gallery,generation,progress=lambda a,b:None):
    if demo.idle()!=generation:raise ProtocolError('Handoff generation differs')
    demo.static_fingerprint=None;demo.gallery=None;demo.transfer.installed=None
    items=[r for r in manifest if r['kind']=='static_model']
    if not items:raise ValueError('No static models')
    data=[]
    for r in items:
        b=Path(r['path']).read_bytes()
        if len(b)!=r['bytes'] or hashlib.sha256(b).hexdigest()!=r['sha256']:raise ValueError('Frozen model changed')
        if r['address']%32 or r['address']<0 or r['address']+len(b)>0x40000000:raise ValueError('Model range')
        data.append((r['address'],b+bytes(-len(b)%32)))
    g=gallery.binary();data.append((BASE,g))
    total=sum(len(b) for a,b in data);done=0;requests=0
    for address,b in data:
        offset=0
        while offset<len(b):
            if requests%64==0:demo.idle()
            length=min(512,len(b)-offset,4096-((address+offset)&4095))
            got=demo.client.request(READ,address=address+offset,length=length)
            if got!=b[offset:offset+length]:raise ResidentBytesMismatch(f'Resident bytes differ at {address+offset:#x}; no residency adopted')
            offset+=length;done+=length;requests+=1;progress(done,total)
    demo.idle()
    demo.static_fingerprint=hashlib.sha256(json.dumps([{k:r[k]for k in ('address','bytes','sha256')}for r in items],sort_keys=True).encode()).hexdigest()
    demo.gallery=gallery
    demo.transfer.installed=dict(generation=generation,revision=gallery.revision,count=len(gallery.records),sha256=sha(g),bytes=len(g),scope='exact physical READ of existing gallery and all model bytes')
    return dict(status='RESIDENT_MODELS_AND_GALLERY_EXACT_READBACK_PASS',bytes=total,requests=requests,generation=generation,model_reuploaded_bytes=0,gallery_revision=gallery.revision)
