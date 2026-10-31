"""UI/API integration using an explicit fake board, never a serial device."""
from pathlib import Path
import base64,json,struct,tempfile,threading,time,unittest,urllib.error,urllib.request
from demo_console import ConsoleCore,Server,release_check,R,UserInputError
from test_runtime_demo import Board

class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.path=Path(self.tmp.name)
        self.core=ConsoleCore(self.path,R/'source/assets_reference01');self.board=Board()
    def connected(self):
        self.core.connector=lambda port:(self.board,lambda:None);self.core.action('connect',{'port':'TEST'})
        # Test-only model marker. Real upload source checking is tested by the
        # runtime coordinator tests; do not send 15MB through a fake transport.
        self.core.demo.static_fingerprint='TEST_ONLY';from gallery import Gallery
        self.core.demo.install_gallery(Gallery(1));self.core.sync()
    def display(self):
        self.core.display_report(dict(source_id=self.core.source_id,rgb_crc32=self.core.state['source_crc'],
            painted=True,fullscreen=True,viewport_matches=True,physical_width=640,physical_height=480))
    def result(self):
        self.display();self.core.action('arm',{});self.core.action('start',{});self.core.poll()
    def test_offline_has_no_result_or_connection(self):
        s=self.core.snapshot();self.assertFalse(s['connected']);self.assertFalse(s['hardware_connection_enabled']);self.assertIsNone(s['result']);self.assertFalse(s['model_inference_on_PC'])
        with self.assertRaises(RuntimeError):self.core.action('connect',{'port':'COM9'})
        with self.assertRaises(RuntimeError):release_check(None)
    def test_no_display_blocks_capture_without_board_mutation(self):
        self.connected();before=len(self.board.events)
        with self.assertRaises(UserInputError):self.core.action('arm',{})
        self.assertEqual(len(self.board.events),before);self.assertIsNone(self.core.demo.video.held)
    def test_stale_wrong_source_or_geometry_blocks(self):
        self.connected()
        for field,value in [('source_id',999),('rgb_crc32','bad'),('fullscreen',False),('physical_width',1280)]:
            self.display();self.core.report[field]=value;self.assertFalse(self.core.display_ready())
        self.display();self.core.report['received']-=13;self.assertFalse(self.core.display_ready())
    def test_enrollment_result_and_release_integrated(self):
        self.connected();self.result();self.assertFalse(self.core.state['result']['accepted'])
        self.core.action('enroll',{'identity':7,'name':'人员甲'});self.assertIsNone(self.core.state['result']);self.assertFalse(self.core.state['held'])
        self.result();s=self.core.snapshot();self.assertEqual(s['result']['person_name'],'人员甲');self.assertTrue(s['result']['accepted'])
        self.assertEqual(s['result']['source_rgb_sha256'],s['source_sha']);self.assertEqual(len(s['gallery']),1)
        self.assertEqual(self.core.demo.gallery.records[0].provenance['scope'],'offline_fixture')
        self.core.action('release',{});self.assertIsNone(self.core.snapshot()['result'])
        self.assertEqual(len(list(self.path.glob('result_*'))),2)
    def test_owned_frame_blocks_source_changes(self):
        self.connected();self.result();before=self.core.manifest()
        with self.assertRaises(ValueError):self.core.set_source(R/'source/assets_second01')
        self.assertEqual(before,self.core.manifest())
    def test_source_change_clears_display_and_old_result(self):
        self.connected();self.result();self.core.action('release',{})
        old=self.core.state['source_sha'];self.core.set_source(R/'source/assets_second01')
        self.assertNotEqual(old,self.core.state['source_sha']);self.assertIsNone(self.core.state['result']);self.assertFalse(self.core.display_ready())
    def test_delete_and_restore_from_local_backup(self):
        self.connected();self.result();self.core.action('enroll',{'identity':7,'name':'甲'})
        saved=next(self.path.glob('gallery_*')).name
        self.core.action('delete',{'identity':7});self.assertEqual(self.core.snapshot()['gallery'],[])
        self.core.action('restore',{'backup':saved});self.assertEqual(self.core.snapshot()['gallery'][0]['identity'],7)
        with self.assertRaises(ValueError):self.core.action('restore',{'backup':'../gallery'})
    def test_no_face_is_not_identity_or_enrollment(self):
        self.connected();self.board.no_face=True;self.result()
        self.assertFalse(self.core.state['result']['has_face']);self.assertIsNone(self.core.state['result']['person_name'])
        with self.assertRaises(ValueError):self.core.action('enroll',{'identity':1,'name':'bad'})
        self.core.action('release',{})
    def test_http_preview_and_origin_token_rules(self):
        server=Server(0,self.core);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        root=f'http://127.0.0.1:{server.server_port}'
        def post(path,body,origin=root):
            req=urllib.request.Request(root+path,json.dumps(body).encode(),{'Origin':origin,'Content-Type':'application/json'})
            return urllib.request.urlopen(req)
        try:
            html=urllib.request.urlopen(root).read();self.assertIn(b'/console.js',html)
            self.assertIn(server.nonce.encode(),urllib.request.urlopen(root+'/console.js').read())
            self.assertEqual(urllib.request.urlopen(root+'/frame.rgb').read(),self.core.source[1]['frame.rgb'])
            self.assertFalse(json.loads(urllib.request.urlopen(root+'/state').read())['connected'])
            for origin,nonce in [('http://evil.invalid',server.nonce),(root,'bad')]:
                with self.assertRaises(urllib.error.HTTPError):post('/display-report',{'nonce':nonce},origin)
            with self.assertRaises(urllib.error.HTTPError):urllib.request.urlopen(root+'/../firmware01/demo.elf')
            post('/display-report',{'nonce':server.nonce,'source_id':self.core.source_id}).close()
            self.assertFalse(self.core.display_ready());self.assertFalse(self.core.snapshot()['connected'])
        finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main(verbosity=2)
