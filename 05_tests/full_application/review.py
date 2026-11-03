"""Fixed-gallery continuous application proof. Same exact two-L2 reference."""
from pathlib import Path
import sys,re,struct,importlib.util,zlib,json
E=Path(__file__).resolve().parent
import numeric_reference as ref
read=lambda p:json.loads(Path(p).read_text())
dump=lambda p,v:Path(p).write_text(json.dumps(v,indent=2),encoding='utf8')
sha=lambda p:__import__('hashlib').sha256(Path(p).read_bytes()).hexdigest()
now=lambda:__import__('time').time()
def verify(pins):
 for p,h in pins.items():assert sha(p)==h,p
O=Path(sys.argv[1]);verify(read(O/'PINNED_INPUTS.json'));p=E/'numeric_reference.py'
t=(O/'run.log').read_text();assert 'PP_STEADY_APPLICATION_PASS epochs=5 people=1 recognized=5 final_generation=5'in t
assert 'CPU_GRAPH_RTL_FAIL'not in t
gold=(O/'e4_gold_217.bin').read_bytes();assert len(gold)==2048
q=ref.normalize(ref.normalize([ref.f32(ref.u32(x/65536.0))for x in struct.unpack('<512i',gold)]))
qw=list(map(ref.u32,q));seed=(O/'seed_feature.bin').read_bytes();assert seed==struct.pack('<512I',*qw)
score=max(-1.,min(1.,ref.dot(q,ref.normalize(list(struct.unpack('<512f',seed))))))
post=read(E/'EXPECTED_POST.json')['words']
expected=[0x31445246,1,0x261007a1,15,post[3],post[1],post[2],7,ref.u32(score),1,ref.u32(.40),1,*post[262:266]]
gallery=(O/'gallery_revision_1.bin').read_bytes();assert len(gallery)==2112
assert struct.unpack('<8I',gallery[:32])==(0x31424447,1,1,1,zlib.crc32(gallery[32:])&0xffffffff,2080,0,0)
assert gallery[32:64]==struct.pack('<8I',7,0,0,0,0,0,0,0)and gallery[64:]==seed
chunks=t.split('RESIDENT_EPOCH_BEGIN epoch=')[1:];assert len(chunks)==5
receipts=[]
for i,c in enumerate(chunks):
 assert c.startswith(str(i)+' ')
 marks=[(int(a),int(b))for a,b in re.findall(r'CPU_GRAPH_STAGE id=(\d+) frame=(\d+)',c)]
 def words(base,n):
  rows=[(k,v)for k,v in marks if base<=k<base+n]
  assert [k for k,v in rows]==list(range(base,base+n));return[v for k,v in rows]
 assert words(0x90000000,512)==qw
 assert words(0xa0000000,16)==expected
 assert (0xfffffff7,1)in marks
 assert [(k,v)for k,v in marks if k==0xfffffff6]==([]if i else[(0xfffffff6,0x50454d31)])
 assert (O/f'epoch_{i}_actual_e4_217.bin').read_bytes()==gold
 assert (O/f'epoch_{i}_actual_uart_result.bin').read_bytes()==struct.pack('<16I',*expected)
 assert 'COMPACT_RESULT_ACK_REAL_RELEASE_PASS'in c
 metrics={k:int(v)for k,v in re.findall(r'(\w+)=(\d+)',next(x for x in c.splitlines()if x.startswith('CPU_GRAPH_RTL_PASS ')))}
 assert metrics['checks']==219 and metrics['commands']==4005
 receipts.append(dict(epoch=i,checks=219,exact_feature_words=512,CPU_result_words=16,COMMIT=True,metrics=metrics))
for marker,n in [('ACTUAL_UART_GALLERY_INSTALL_PASS',1),('ACTUAL_HDMI_CAPTURE_DDR_PASS',5),('ACTUAL_HDMI_RESULT_ASSOCIATION_PASS',5),('ACTUAL_UART_REARM_RESIDENT_DDR_PASS',4),('BOARD_LOGIC_ACTUAL_CPU_RESIDENCY_GATE_PASS',5)]:assert t.count(marker)==n,(marker,t.count(marker))
def rows(prefix):return[{k:int(v)for k,v in re.findall(r'(\w+)=(\d+)',x)}for x in t.splitlines()if x.startswith(prefix+' ')]
captures=rows('ACTUAL_HDMI_CAPTURE_DDR_PASS');retired=rows('PP_RESULT_RETIRED')
assert len(captures)==len(retired)==5
assert all(v['physical_write']==3686400 and v['physical_read']==0 and v['input_crc']==zlib.crc32((O/'epoch_0_input.bin').read_bytes())&0xffffffff for v in captures)
overlap=read(O/'SCENARIO.json')['mode']=='overlap'
assert [v['overlapped']for v in captures]==([0,1,1,1,1]if overlap else[0]*5)
assert [v['slot']for v in captures]==([0x01800000,0x0e000000,0x01800000,0x0e000000,0x01800000]if overlap else[0x01800000]*5)
# Completion-to-completion includes real REARM, SESSION, capture status/START,
# FPGA work, compact result UART and result ACK. No gallery update between frames.
intervals=[dict(epoch=i,cycles=retired[i]['absolute_cycles']-retired[i-1]['absolute_cycles'],read_bytes=retired[i]['read']-retired[i-1]['read'],write_bytes=retired[i]['write']-retired[i-1]['write'])for i in range(1,5)]
final=rows('PP_STEADY_APPLICATION_PASS')[0]
verify(read(O/'PINNED_INPUTS.json'))
dump(O/'NUMERIC_REVIEW.json',dict(status='PP04_STEADY_FIVE_APPLICATION_EXACT_PASS',at=now(),complete_application_RTL=True,fixed_gallery=True,fixed_models=True,input='A',people=1,epochs=receipts,completion_intervals=intervals,steady_interior_epochs=[1,2,3],last_epoch_drains_pipeline=True,captures=captures,physical_total=final,CPU_Hz=31250000,NPU_Hz=125000000,DDR_latency40_not_calibrated=True,board=False,full15D8R=False,reference_sha256=sha(p),review_sha256=sha(__file__),log_sha256=sha(O/'run.log')))
print('PP04_STEADY_FIVE_APPLICATION_EXACT_PASS',O.name)
