from pathlib import Path
import base64,hashlib,json,struct,tempfile,unittest
from camera_assets import prepare
from resident_resume import resume
from runtime_demo import RuntimeDemo
from test_runtime_demo import Board
from gallery import Gallery
from video_protocol import READ,ProtocolError
import test_ux_flow as flow

class Assets(unittest.TestCase):
    def test_reference_rgb_exact_q16(self):
        from demo_console import R
        p=R/'05_tests/fixtures/reference'
        m,a=prepare((p/'frame.rgb').read_bytes(),'test:1')
        self.assertEqual(a['input.bin'],(p/'input.bin').read_bytes())
        self.assertEqual(m['files']['frame.rgb']['sha256'],hashlib.sha256(a['frame.rgb']).hexdigest())
    def test_extreme_channels(self):
        m,a=prepare(bytes([0,127,255])*307200,'test:2')
        for i,v in enumerate([151*65536,10*65536,-123*65536]):
            self.assertEqual(a['input.bin'][i*1228800:(i+1)*1228800],struct.pack('<i',v)*307200)
    def test_bad_size_token(self):
        with self.assertRaises(ValueError):prepare(b'','x')
        with self.assertRaises(ValueError):prepare(bytes(921600),'')

class CameraFlow(unittest.TestCase):
    setUp=flow.Tests.setUp
    ready=flow.Tests.ready
    display=flow.Tests.display
    run_one=flow.Tests.run_one
    def test_owned_inflight_frame_not_replaced(self):
        self.ready();self.c.action('arm',{});old=self.c.source_id
        with self.assertRaises(ValueError):self.c.action('camera_frame',dict(data='',token='x'))
        self.assertEqual(self.c.source_id,old);self.assertTrue(self.b.active)
    def test_camera_releases_exactly_after_result_and_model_stays(self):
        self.ready();self.run_one();gen=self.b.gen
        self.c.action('camera_frame',dict(data=base64.b64encode(self.c.source[1]['frame.rgb']).decode(),token='camera:1'))
        self.assertEqual(self.b.gen,gen+1);self.assertFalse(self.b.active)
        self.assertEqual(self.c.state['camera_frame_token'],'camera:1');self.assertFalse(self.c.display_ready())
        self.assertEqual(self.c.demo.static_fingerprint,'TEST_ONLY')
        self.display();self.run_one();self.assertTrue(self.c.state['result']['has_face'])

class Resident(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.p=Path(self.tmp.name)/'model';self.data=bytes(range(256))*5;self.p.write_bytes(self.data)
        self.rows=[dict(kind='static_model',path=str(self.p),address=0x100fe0,bytes=len(self.data),sha256=hashlib.sha256(self.data).hexdigest())]
        self.b=Board();self.d=RuntimeDemo(self.b,lambda:None);self.g=Gallery(2);self.d.install_gallery(self.g)
        orig=self.b.request
        def req(op,address=0,length=0,payload=b''):
            if 0x100fe0<=address<0x100fe0+len(self.data):
                self.assertEqual(op,READ);self.assertLessEqual((address&4095)+length,4096)
                return self.data[address-0x100fe0:address-0x100fe0+length]
            return orig(op,address,length,payload)
        self.b.request=req;self.requests=len(self.b.events)
    def test_every_byte_and_no_writes(self):
        receipt=resume(self.d,self.rows,self.g,self.b.gen)
        self.assertEqual(receipt['bytes'],len(self.data)+32)
        self.assertEqual(receipt['model_reuploaded_bytes'],0)
        self.assertEqual(self.d.upload_models(self.rows)['uploaded_bytes'],0)
    def test_corruption_never_adopts_residency(self):
        self.data=b'x'+self.data[1:]
        with self.assertRaises(ProtocolError):resume(self.d,self.rows,self.g,self.b.gen)
        self.assertIsNone(self.d.static_fingerprint);self.assertIsNone(self.d.gallery)
    def test_generation_change_rejected(self):
        with self.assertRaises(ProtocolError):resume(self.d,self.rows,self.g,self.b.gen+1)
    def test_gallery_mismatch_rejected(self):
        with self.assertRaises(ProtocolError):resume(self.d,self.rows,Gallery(3),self.b.gen)
        self.assertIsNone(self.d.static_fingerprint)

if __name__=='__main__':unittest.main(verbosity=2)
