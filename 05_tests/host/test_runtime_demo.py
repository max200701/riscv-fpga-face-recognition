"""Controller/real host-protocol integration tests with an explicit fake board."""
from pathlib import Path
import copy,hashlib,struct,tempfile,unittest
from runtime_demo import RuntimeDemo
from gallery import Gallery,BASE
from test_gallery import Fake,REAL_RESULT
from video_protocol import VIDEO_ARM,parse_result,ProtocolError,WRITE

class Board(Fake):
    def __init__(self):
        super().__init__();self.held=None;self.phase=0;self.ready=False;self.no_face=False;self.wrong_revision=False;self.serial_tx_model=0
    def snapshot(self):
        d=super().snapshot();d['phase']=self.phase;return d
    def video_status(self):
        h=self.held or (self.gen,self.gen,0)
        return dict(session_generation=self.gen,next_capture_generation=self.gen,
                    held_session_generation=h[0],held_capture_generation=h[1],held_frame_id=h[2],
                    arm_permitted=not self.active,video_reserved=self.active,application_selected=self.phase!=0,capture_busy=False,
                    frame_ready=self.active,errors=0,rejected=False,start_permitted=self.active and self.phase==0,
                    result_ready=self.ready,result_source_id=1,result_session_generation=h[0],result_capture_generation=h[1],result_frame_id=h[2])
    def request(self,op,address=0,length=0,payload=b''):
        if op==VIDEO_ARM:
            assert address==self.gen and not self.active
            frame,capture,r0,r1=struct.unpack('<4I',payload);assert not(r0 or r1)
            self.held=(self.gen,capture,frame);self.active=True;return b''
        if address<BASE:
            assert op==WRITE and self.phase==0 and not self.active
            self.events.append((op,address,length,bytes(payload)));self.serial_tx_model+=length;return b''
        return super().request(op,address,length,payload)
    def start(self,generation):
        assert generation==self.gen and self.active
        self.phase=3;self.ready=True
    def collect(self,generation,include_embedding=True):
        assert generation==self.gen and self.ready
        words=list(struct.unpack('<16I',REAL_RESULT.read_bytes()[:64]))
        count,revision=struct.unpack_from('<2I',self.memory,8)
        words[3]=0 if self.no_face else (15 if count else 9)
        words[7]=struct.unpack_from('<I',self.memory,32)[0]if count and not self.no_face else 0xffffffff
        words[8]=0 if not count or self.no_face else 0x3f800000
        words[9]=count;words[11]=revision+int(self.wrong_revision)
        result=parse_result(struct.pack('<16I',*words));embedding=b''if self.no_face or not include_embedding else REAL_RESULT.read_bytes()[64:]
        result.update(generation=self.gen,result_page_mask=1 if self.no_face or not include_embedding else (1<<33)-1)
        if embedding:result['embedding_sha256']=hashlib.sha256(embedding).hexdigest()
        return result,embedding
    def rearm(self,generation):
        assert generation==self.gen and self.ready
        self.gen+=1;self.phase=0;self.active=False;self.ready=False;return self.session()

class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.p=Path(self.tmp.name);self.addCleanup(self.tmp.cleanup)
        self.board=Board();self.demo=RuntimeDemo(self.board,lambda:None)
        model=self.p/'immutable.bin';model.write_bytes(bytes(range(32)))
        self.manifest=[dict(kind='static_model',path=str(model),address=0x10000,bytes=32,sha256=hashlib.sha256(model.read_bytes()).hexdigest())]
        self.source=dict(width=640,height=480,files={'frame.rgb':{'sha256':'ab'*32}})
    def ready(self):self.demo.upload_models(self.manifest);self.demo.install_gallery(Gallery(1))
    def collect(self):
        self.demo.arm(self.source,100+self.board.gen);self.demo.start();return self.demo.collect()
    def test_enrollment_delete_restore_flow(self):
        self.ready();r,e=self.collect();self.assertFalse(r['accepted']);self.assertIsNone(r['person_name'])
        saved=self.p/'enrolled';self.demo.enroll_and_release(7,'人员甲',saved,'offline_fixture')
        self.assertEqual(self.demo.gallery.revision,2);self.assertEqual(e,b'');self.assertEqual(self.demo.gallery.records[0].embedding,REAL_RESULT.read_bytes()[64:])
        r,_=self.collect();self.assertTrue(r['accepted']);self.assertEqual(r['person_name'],'人员甲');self.demo.release()
        self.demo.delete(7,self.p/'deleted');self.assertEqual(len(self.demo.gallery.records),0)
        self.demo.restore(saved,self.p/'restored');self.assertEqual(self.demo.gallery.revision,4)
        self.assertEqual(self.board.serial_tx_model,32,'model must stay resident across ordinary release/enroll')
    def test_model_integrity_checked_even_resident(self):
        self.ready();self.assertEqual(self.demo.upload_models(self.manifest)['uploaded_bytes'],0)
        Path(self.manifest[0]['path']).write_bytes(b'x'*32)
        with self.assertRaises(ValueError):self.demo.upload_models(self.manifest)
        self.assertEqual(self.board.serial_tx_model,32)
    def test_capture_holds_source_and_blocks_gallery(self):
        self.ready();self.demo.arm(self.source,4)
        for f in (lambda:self.demo.install_gallery(Gallery(2)),lambda:self.demo.upload_models(self.manifest),lambda:self.demo.arm(self.source,5),self.demo.release):
            with self.assertRaises(ProtocolError):f()
    def test_noface_cannot_enroll_can_release(self):
        self.ready();self.board.no_face=True;r,e=self.collect();self.assertFalse(r['has_face']);self.assertEqual(e,b'')
        with self.assertRaises(ValueError):self.demo.enroll_and_release(7,'nobody',self.p/'bad','offline_fixture')
        self.assertTrue(self.board.active);self.demo.release();self.assertFalse(self.board.active)
    def test_cpu_gallery_version_mismatch(self):
        self.ready();self.demo.arm(self.source,9);self.demo.start();self.board.wrong_revision=True
        with self.assertRaises(ProtocolError):self.demo.collect()
        with self.assertRaises(ProtocolError):self.demo.release()
    def test_failed_install_blocks_start(self):
        self.ready();self.board.fail=len(self.board.events)+1
        with self.assertRaises(TimeoutError):self.demo.install_gallery(Gallery(2))
        with self.assertRaises(ProtocolError):self.demo.arm(self.source,11)
    def test_new_connection_does_not_assume_residency(self):
        self.ready();reconnect=RuntimeDemo(self.board,lambda:None)
        with self.assertRaises(ProtocolError):reconnect.arm(self.source,2)
    def test_unexpected_generation(self):
        self.ready();self.board.gen+=1
        with self.assertRaises(ProtocolError):self.demo.arm(self.source,2)

if __name__=='__main__':unittest.main(verbosity=2)
