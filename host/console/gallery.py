"""GDB1 enrollment storage. No face inference, normalization or similarity search.

Embeddings must be the exact 2048 bytes collected from the FPGA result pages.
This module never opens a serial port. A caller supplies the qualified transport
and the existing physical-release authorization callback for any board mutation.
"""
from dataclasses import dataclass
from pathlib import Path
import hashlib,json,math,struct,zlib
from video_protocol import WRITE,READ,ProtocolError

BASE=0x0a000000
MAGIC=0x31424447
STRIDE=2080
CAPACITY=16
sha=lambda b:hashlib.sha256(b).hexdigest()

def u32(value):
    return type(value)is int and 0<value<=0xffffffff

def feature_ok(blob):
    if type(blob)is not bytes or len(blob)!=2048:raise ValueError('Expected unchanged 512 float32 feature words')
    values=struct.unpack('<512f',blob)
    if not all(math.isfinite(v) for v in values):raise ValueError('Nonfinite feature')
    # Validation only, never modify or renormalize the returned data.
    norm2=math.fsum(v*v for v in values)
    if not .99<=norm2<=1.01:raise ValueError('Expected board two-L2 unit vector')

@dataclass(frozen=True)
class Record:
    identity:int
    name:str
    embedding:bytes
    provenance:dict

@dataclass(frozen=True)
class Gallery:
    revision:int
    records:tuple=()

    def binary(self):
        if not u32(self.revision) or len(self.records)>CAPACITY:raise ValueError('Gallery revision/capacity')
        payload=bytearray();seen=set()
        for row in self.records:
            if not u32(row.identity) or row.identity in seen:raise ValueError('Unique nonzero ID required')
            if not isinstance(row.name,str) or not row.name.strip() or len(row.name)>80:raise ValueError('Person name')
            feature_ok(row.embedding);seen.add(row.identity)
            payload.extend(struct.pack('<8I',row.identity,0,0,0,0,0,0,0));payload.extend(row.embedding)
        return struct.pack('<8I',MAGIC,1,len(seen),self.revision,zlib.crc32(payload)&0xffffffff,STRIDE,0,0)+payload

    def enroll(self,identity,name,result,embedding,scope):
        """Call after VideoSession.collect, before REARM; return a new revision.

        scope records the origin, not a cryptographic assertion of hardware.
        Simulated evidence must never be relabeled as a board measurement.
        """
        if scope not in ('application_rtl','board','offline_fixture'):raise ValueError('Evidence scope')
        if not u32(identity) or self.revision==0xffffffff:raise ValueError('ID/revision exhausted')
        feature_ok(embedding)
        src=result.get('video_source',{})
        if not result.get('has_face') or result.get('result_page_mask')!=(1<<33)-1:raise ValueError('Enrollment needs face and all acknowledged feature pages')
        if set(src)!=set(('session','capture','frame')) or any(type(v)is not int or not 0<=v<=0xffffffff for v in src.values()):raise ValueError('Missing result source/epoch')
        if result.get('generation')!=src['session']:raise ValueError('Result/source generation mismatch')
        if result.get('embedding_sha256')!=sha(embedding):raise ValueError('Feature receipt hash mismatch')
        source_hash=result.get('source_rgb_sha256','')
        if len(source_hash)!=64 or any(c not in '0123456789abcdef' for c in source_hash):raise ValueError('Missing source RGB identity')
        provenance=dict(scope=scope,source=dict(src),source_rgb_sha256=source_hash,
                        embedding_sha256=sha(embedding),page_mask=result['result_page_mask'],
                        description='unchanged result feature pages; no host face inference')
        row=Record(identity,name.strip(),embedding,provenance)
        records=tuple(r for r in self.records if r.identity!=identity)+(row,)
        candidate=Gallery(self.revision+1,records);candidate.binary();return candidate

    def delete(self,identity):
        if self.revision==0xffffffff:raise ValueError('Revision exhausted')
        if identity not in {r.identity for r in self.records}:raise KeyError(identity)
        return Gallery(self.revision+1,tuple(r for r in self.records if r.identity!=identity))

    def save(self,directory):
        """Immutable versioned backup; prior galleries are never overwritten."""
        data=self.binary();directory=Path(directory);directory.mkdir(parents=True,exist_ok=False)
        (directory/'gallery.bin').write_bytes(data)
        metadata=dict(schema='GDB1_HOST_BACKUP_V1',revision=self.revision,sha256=sha(data),
                      records=[dict(identity=r.identity,name=r.name,embedding_sha256=sha(r.embedding),provenance=r.provenance)for r in self.records],
                      board_computation=False,meaning='host stores board or explicitly labeled test features; names never enter the FPGA ABI')
        (directory/'metadata.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
        if load(directory).binary()!=data:raise IOError('Gallery backup readback mismatch')
        return metadata

def load(directory):
    directory=Path(directory);data=(directory/'gallery.bin').read_bytes();m=json.loads((directory/'metadata.json').read_text(encoding='utf8'))
    if m.get('schema')!='GDB1_HOST_BACKUP_V1' or sha(data)!=m.get('sha256'):raise ValueError('Backup identity/checksum')
    if len(data)<32:raise ValueError('Truncated GDB1 header')
    h=struct.unpack('<8I',data[:32]);count=h[2]
    if h[0:2]!=(MAGIC,1) or count>CAPACITY or not h[3] or h[5:]!=(STRIDE,0,0):raise ValueError('GDB1 ABI')
    if len(data)!=32+count*STRIDE or zlib.crc32(data[32:])&0xffffffff!=h[4]:raise ValueError('GDB1 extent/payload CRC')
    if m['revision']!=h[3] or len(m['records'])!=count:raise ValueError('Backup metadata extent')
    rows=[]
    for i,meta in enumerate(m['records']):
        offset=32+i*STRIDE;words=struct.unpack_from('<8I',data,offset);embedding=data[offset+32:offset+STRIDE]
        if words[1:]!=(0,)*7 or words[0]!=meta['identity'] or sha(embedding)!=meta['embedding_sha256']:raise ValueError('Record metadata mismatch')
        rows.append(Record(words[0],meta['name'],embedding,meta['provenance']))
    gallery=Gallery(h[3],tuple(rows))
    if gallery.binary()!=data:raise ValueError('Noncanonical GDB1')
    return gallery

class GalleryTransfer:
    """BOOT-only invalid-header -> data -> verified-header publication.

    No START or retry is implicit. Any failure clears this object's ready flag;
    reconnect requires a new verified installation and never assumes residency.
    Existing transport retries only exact request bytes with the same sequence.
    """
    def __init__(self,client,authorize):
        self.client=client;self.authorize=authorize;self.installed=None

    def idle(self,generation=None,observed=False):
        self.authorize();s=self.client.snapshot();e=self.client.session();v=self.client.video_status()
        return self.qualify_idle(s,e,v,generation,observed)

    def qualify_idle(self,s,e,v,generation=None,observed=False):
        if not s['supported'] or s['phase']!=0 or not all(s[k]for k in ('ddr_ready','safety_ready','temp_valid')) or any(s[k]for k in ('temp_fault','over_temp','fault')):raise ProtocolError('Gallery update requires healthy idle OM BOOT')
        if not e['memory_drained'] or not e['start_allowed'] or v['video_reserved'] or v['application_selected'] or v['capture_busy']:raise ProtocolError('Gallery update conflicts with active owner/capture')
        if e['generation']!=v['session_generation'] or generation is not None and generation!=e['generation']:raise ProtocolError('Gallery update generation changed')
        return (s,v) if observed else e['generation']

    def install(self,gallery):
        data=gallery.binary();self.installed=None;generation=self.idle()
        def write(offset,blob):
            self.idle(generation)
            self.client.request(WRITE,address=BASE+offset,length=len(blob),payload=blob)
        def readback(offset,blob):
            self.idle(generation)
            got=self.client.request(READ,address=BASE+offset,length=len(blob))
            if got!=blob:raise ProtocolError('Gallery physical readback mismatch')
        invalid=bytes(32);write(0,invalid);readback(0,invalid)
        offset=32
        while offset<len(data):
            # FBD1's real endpoint rejects even a 32-byte-aligned transaction
            # if it crosses 4 KiB. Header +32 shifts the payload off 512 bytes.
            length=min(512,len(data)-offset,4096-((BASE+offset)&4095))
            blob=data[offset:offset+length];write(offset,blob);readback(offset,blob)
            offset+=length
        write(0,data[:32]);readback(0,data[:32]);self.idle(generation)
        self.installed=dict(generation=generation,revision=gallery.revision,count=len(gallery.records),sha256=sha(data),
                            bytes=len(data),scope='transport ACK and exact readback; next real CPU preflight still required')
        return dict(self.installed)
