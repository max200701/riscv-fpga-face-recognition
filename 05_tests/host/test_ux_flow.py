import base64,json,tempfile,time,unittest
from pathlib import Path
from unittest.mock import patch
from demo_console import ConsoleCore,R,UserInputError
from test_runtime_demo import Board
from gallery import Gallery
from pin_cache import PinCache

class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.p=Path(self.tmp.name);self.b=Board()
        self.c=ConsoleCore(self.p,R/'05_tests/fixtures/reference',connector=lambda p:(self.b,lambda:None));self.addCleanup(self.c.close)
    def ready(self):
        self.c.connect('FAKE');self.c.demo.static_fingerprint='TEST_ONLY';self.c.demo.install_gallery(Gallery(1));self.display();self.c.poll()
    def display(self):self.c.display_report(dict(source_id=self.c.source_id,rgb_crc32=self.c.state['source_crc'],painted=True,fullscreen=True,viewport_matches=True,physical_width=640,physical_height=480))
    def run_one(self):self.c.action('recognize',{});self.c.poll();self.c.poll()
    def test_reason_states(self):
        s=self.c.snapshot();self.assertIn('连接',s['actions']['recognize']);self.assertEqual(s['actions']['image'],'')
        self.ready();self.c.report=None;s=self.c.snapshot();self.assertIn('心跳',s['actions']['recognize'])
        self.assertIn('图库为空',s['actions']['delete']);self.assertIn('尚无图库备份',s['actions']['restore'])
        self.display();self.assertEqual(self.c.snapshot()['actions']['recognize'],'')
    def test_one_click_enroll_release_second_recognition(self):
        self.ready();self.run_one();s=self.c.snapshot();self.assertTrue(s['result']['has_face']);self.assertFalse(s['result']['accepted'])
        self.c.action('enroll',dict(identity=8,name='甲'));self.assertFalse(self.c.snapshot()['held']);self.assertTrue(self.c.backups())
        self.display();self.run_one();self.assertEqual(self.c.snapshot()['result']['person_name'],'甲')
        self.c.action('release',{});self.assertFalse(self.b.active);self.assertEqual(self.b.gen,5)
    def test_capture_timeout_keeps_owner_and_connection(self):
        self.ready();self.c.action('recognize',{});self.c.auto_deadline=0
        original=self.b.video_status
        def waiting():return dict(original(),frame_ready=False,start_permitted=False)
        with patch.object(self.b,'video_status',waiting):
            with self.assertRaises(UserInputError):self.c.poll()
        self.assertIsNotNone(self.c.demo);self.assertTrue(self.c.demo.video.held);self.assertFalse(self.b.ready)
        self.c.action('start',{});self.c.poll();self.assertIsNotNone(self.c.state['result'])
    def test_no_face_still_releases(self):
        self.ready();self.b.no_face=True;self.run_one();self.assertIn('人脸',self.c.snapshot()['actions']['enroll'])
        self.c.action('release',{});self.assertFalse(self.c.snapshot()['held'])
    def test_image_change_releases_completed_frame_before_new_source(self):
        self.ready();self.run_one();old=self.c.source_id
        data=base64.b64encode(self.c.source[1]['frame.png']).decode()
        self.c.action('image',dict(data=data));self.assertFalse(self.b.active);self.assertEqual(self.b.gen,4)
        self.assertGreater(self.c.source_id,old);self.assertFalse(self.c.display_ready());self.assertIsNone(self.c.state['result'])
    def test_bad_file_retains_result_and_connection(self):
        self.ready();self.run_one()
        with self.assertRaises(UserInputError):self.c.action('image',dict(data=base64.b64encode(b'not an image').decode()))
        self.assertTrue(self.b.active);self.assertIsNotNone(self.c.state['result'])
    def test_no_double_start_when_polling(self):
        self.ready()
        with patch.object(self.b,'start',wraps=self.b.start) as start:
            self.run_one()
            for i in range(8):self.c.poll()
            self.assertEqual(start.call_count,1)
    def test_pin_cache_reuses_unchanged_and_detects_mutation(self):
        p=self.p/'asset';p.write_bytes(b'abcd');cache=PinCache();before=cache.sha(p)
        for i in range(200):self.assertEqual(cache.sha(p),before)
        self.assertEqual(cache.hash_calls,1);self.assertEqual(cache.hashed_bytes,4)
        p.write_bytes(b'efgh');self.assertNotEqual(cache.sha(p),before);self.assertEqual(cache.hash_calls,2)

if __name__=='__main__':unittest.main(verbosity=2)
