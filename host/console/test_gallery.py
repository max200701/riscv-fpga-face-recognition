"""Offline host fault tests. Fake transport is never called board evidence."""
from pathlib import Path
import copy,json,struct,tempfile,unittest
from gallery import *

R=Path(__file__).resolve().parents[2]
SYNTHETIC_RESULT=R/'host/source/assets_reference01/synthetic_result.bin'

class Fake:
    def __init__(self):
        self.memory=bytearray(32+16*2080);self.events=[];self.fail=None;self.active=False;self.gen=3
    def snapshot(self):return dict(supported=True,phase=0,ddr_ready=True,safety_ready=True,temp_valid=True,temp_fault=0,over_temp=False,fault=False)
    def session(self):return dict(memory_drained=True,start_allowed=True,generation=self.gen)
    def video_status(self):return dict(video_reserved=self.active,application_selected=False,capture_busy=False,session_generation=self.gen)
    def request(self,op,address,length,payload=b''):
        assert address%32==0 and 0<length<=512 and length%32==0 and (address&4095)+length<=4096,'Actual FBD1 geometry'
        self.events.append((op,address,length,bytes(payload)))
        if self.fail==len(self.events):raise TimeoutError('injected lost response')
        off=address-BASE
        if op==WRITE:
            assert not self.active and off%32==0 and 0<length<=512 and length%32==0
            self.memory[off:off+length]=payload;return b''
        if op==READ:return bytes(self.memory[off:off+length])
        raise AssertionError('No implicit START or REARM')

class Tests(unittest.TestCase):
    def setUp(self):
        self.embedding=SYNTHETIC_RESULT.read_bytes()[64:];feature_ok(self.embedding)
        self.result=dict(has_face=True,result_page_mask=(1<<33)-1,generation=3,
                         video_source=dict(session=3,capture=3,frame=123),embedding_sha256=sha(self.embedding),source_rgb_sha256='ab'*32)
        self.empty=Gallery(1)
        self.g=self.empty.enroll(7,'测试登记',self.result,self.embedding,'offline_fixture')
    def test_exact_board_bytes_and_abi(self):
        data=self.g.binary();h=struct.unpack('<8I',data[:32])
        self.assertEqual(h,(0x31424447,1,1,2,zlib.crc32(data[32:])&0xffffffff,2080,0,0))
        self.assertEqual(data[32:64],struct.pack('<8I',7,0,0,0,0,0,0,0));self.assertEqual(data[64:],self.embedding)
    def test_backup_restore_no_overwrite(self):
        with tempfile.TemporaryDirectory()as t:
            p=Path(t)/'revision2';self.g.save(p);self.assertEqual(load(p).binary(),self.g.binary())
            with self.assertRaises(FileExistsError):self.g.save(p)
    def test_delete_and_reenroll(self):
        a=self.g.enroll(7,'更新名称',self.result,self.embedding,'offline_fixture');self.assertEqual(len(a.records),1)
        self.assertEqual(a.revision,3);b=a.delete(7);self.assertEqual(len(b.records),0);self.assertEqual(b.revision,4)
        self.assertEqual(self.empty.binary(),struct.pack('<8I',0x31424447,1,0,1,0,2080,0,0))
    def test_capacity_and_duplicate(self):
        a=self.empty
        for i in range(1,17):a=a.enroll(i,str(i),self.result,self.embedding,'offline_fixture')
        with self.assertRaises(ValueError):a.enroll(17,'overflow',self.result,self.embedding,'offline_fixture')
        with self.assertRaises(ValueError):Gallery(1,(a.records[0],a.records[0])).binary()
    def test_result_ownership_and_pages(self):
        for field,value in [('has_face',False),('result_page_mask',1),('generation',4),('embedding_sha256','0'*64),('source_rgb_sha256','')]:
            bad=dict(self.result);bad[field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):self.empty.enroll(7,'bad',bad,self.embedding,'offline_fixture')
    def test_nonfinite_truncated_zero_feature(self):
        for data in (self.embedding[:2044],bytes(2048),struct.pack('<f',float('nan'))+self.embedding[4:]):
            with self.assertRaises(ValueError):feature_ok(data)
    def test_checksum_reject(self):
        with tempfile.TemporaryDirectory()as t:
            p=Path(t)/'v2';self.g.save(p);data=bytearray((p/'gallery.bin').read_bytes());data[-1]^=1;(p/'gallery.bin').write_bytes(data)
            with self.assertRaises(ValueError):load(p)
    def test_payload_then_header_publication(self):
        f=Fake();x=GalleryTransfer(f,lambda:None);receipt=x.install(self.g)
        self.assertEqual(f.events[0],(WRITE,BASE,32,bytes(32)));self.assertEqual(f.events[-2][0],WRITE)
        self.assertEqual(f.events[-2][1],BASE);self.assertEqual(f.memory[:2112],self.g.binary());self.assertEqual(receipt['revision'],2)
    def test_empty_delete_upload(self):
        f=Fake();x=GalleryTransfer(f,lambda:None);x.install(self.g);x.install(self.g.delete(7))
        self.assertEqual(struct.unpack_from('<I',f.memory,8)[0],0)
    def test_capture_conflict(self):
        f=Fake();f.active=True;x=GalleryTransfer(f,lambda:None)
        with self.assertRaises(ProtocolError):x.install(self.g)
        self.assertEqual(f.events,[])
    def test_unauthorized_no_write(self):
        f=Fake()
        def deny():raise PermissionError('physical release pending')
        with self.assertRaises(PermissionError):GalleryTransfer(f,deny).install(self.g)
        self.assertEqual(f.events,[])
    def test_each_transaction_failure_no_ready(self):
        baseline=Fake();GalleryTransfer(baseline,lambda:None).install(self.g)
        for n in range(1,len(baseline.events)+1):
            f=Fake();f.fail=n;x=GalleryTransfer(f,lambda:None)
            with self.subTest(transaction=n),self.assertRaises(TimeoutError):x.install(self.g)
            self.assertIsNone(x.installed)
    def test_changed_generation_rejected(self):
        f=Fake();calls=0
        def auth():
            nonlocal calls
            calls+=1
            if calls==3:f.gen+=1
        x=GalleryTransfer(f,auth)
        with self.assertRaises(ProtocolError):x.install(self.g)
        self.assertIsNone(x.installed);self.assertEqual(f.memory[:32],bytes(32))
    def test_readback_corruption_rejected(self):
        class Corrupt(Fake):
            def request(self,op,address,length,payload=b''):
                out=super().request(op,address,length,payload)
                return bytes([out[0]^1])+out[1:]if op==READ else out
        x=GalleryTransfer(Corrupt(),lambda:None)
        with self.assertRaises(ProtocolError):x.install(self.g)
        self.assertIsNone(x.installed)

if __name__=='__main__':unittest.main(verbosity=2)
