"""Delayed fake board: ownership, fresh display, pause, bounded queue and faults."""
import tempfile,time,unittest,hashlib,threading
from pathlib import Path
from demo_console import ConsoleCore,R
from test_runtime_demo import Board
from gallery import Gallery

class DelayedBoard(Board):
    def __init__(self):super().__init__();self.starts=0;self.arms=0;self.releases=0
    def start(self,g):super().start(g);self.ready=False;self.starts+=1
    def request(self,op,**kw):
        from video_protocol import VIDEO_ARM
        if op==VIDEO_ARM:self.arms+=1
        return super().request(op,**kw)
    def rearm(self,g):self.releases+=1;return super().rearm(g)

class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.b=DelayedBoard();self.c=ConsoleCore(Path(self.tmp.name),R/'source/assets_reference01',connector=lambda p:(self.b,lambda:None))
        self.c.action('connect',{'port':'FAKE'});self.c.demo.static_fingerprint='TEST';self.c.demo.install_gallery(Gallery(1));self.c.sync()
        self.p=self.c.pipeline;self.rgb=(R/'source/assets_reference01/frame.rgb').read_bytes();self.other=bytes([114])*921600
    def display(self):
        self.c.display_report(dict(source_id=self.c.source_id,rgb_crc32=self.c.state['source_crc'],painted=True,fullscreen=True,viewport_matches=True,physical_width=640,physical_height=480))
    def launch(self):
        self.p.begin('test');self.p.feed('test',1,self.rgb);self.p.tick();self.display();self.p.tick()
        self.assertEqual(self.b.arms,1);self.assertEqual(self.b.starts,0)
    def test_overlap_after_capture_keeps_original_source_and_result(self):
        self.launch();sid=self.c.source_id;sha=self.c.state['source_sha']
        self.p.feed('test',2,self.other);self.p.tick();self.assertEqual(self.c.source_id,sid,'never change during capture')
        self.c.poll();self.assertEqual(self.b.starts,1);self.assertNotEqual(self.c.source_id,sid)
        self.assertEqual(self.c.demo.video.source['files']['frame.rgb']['sha256'],sha)
        self.display();self.b.ready=True;self.c.poll()
        self.assertEqual(self.p.completed,1);self.assertEqual(self.p.last_result['source_rgb_sha256'],sha)
        self.assertEqual(self.p.preview(sha),self.rgb);self.assertEqual(self.b.releases,1);self.assertEqual(self.b.arms,2)
        self.assertTrue(self.p.last_result['pipeline_timing_ms']['next_display_overlapped'])
    def test_pause_does_not_start_queued_frame_and_preserves_enrollment_frame(self):
        self.launch();self.p.feed('test',2,self.other);self.c.poll();self.display()
        self.p.stop('test');self.p.tick();self.assertTrue(self.p.finishing);self.assertEqual(self.b.releases,0)
        self.b.ready=True;self.c.poll();self.assertFalse(self.p.finishing);self.assertEqual(self.b.arms,1)
        self.assertTrue(self.c.demo.video.held);self.assertEqual(self.c.state['source_sha'],hashlib.sha256(self.rgb).hexdigest())
        self.c.action('enroll',{'identity':7,'name':'test'});self.assertEqual(len(self.c.demo.gallery.records),1)
    def test_fresh_display_required_at_handoff(self):
        self.launch();self.p.feed('test',2,self.other);self.c.poll();self.b.ready=True;self.c.poll()
        self.assertEqual(self.p.completed,1);self.assertEqual(self.b.releases,0);self.assertEqual(self.b.arms,1)
        self.display();self.p.tick();self.assertEqual(self.b.arms,2)
    def test_bound_and_late_frames(self):
        self.p.begin('test')
        for i in range(1,30):self.p.feed('test',i,self.rgb)
        self.assertEqual(self.p.pending['token'],'test:29');self.assertEqual(self.p.replaced,28)
        for run,seq in [('other',30),('test',28),('test',29)]:
            with self.assertRaises(ValueError):self.p.feed(run,seq,self.rgb)
        self.assertEqual(self.p.pending['token'],'test:29')
    def test_pause_before_first_arm(self):
        self.p.begin('test');self.p.feed('test',1,self.rgb);self.p.stop('test');self.p.tick()
        self.assertEqual(self.b.arms,0);self.assertFalse(self.p.finishing)
    def test_heartbeat_expiry_finishes_current_not_next(self):
        self.launch();self.p.feed('test',2,self.other);self.c.poll();self.display();self.p.heartbeat-=9
        self.p.tick();self.assertFalse(self.p.enabled);self.assertTrue(self.p.finishing)
        self.b.ready=True;self.c.poll();self.assertEqual(self.b.arms,1);self.assertFalse(self.p.finishing)
    def test_frame_limit_and_no_repeated_start(self):
        self.p.begin('test',1);self.p.feed('test',1,self.rgb);self.p.tick();self.display();self.p.tick()
        for _ in range(5):self.c.poll()
        self.assertEqual(self.b.starts,1);self.b.ready=True;self.c.poll()
        for _ in range(5):self.c.poll()
        self.assertEqual(self.p.completed,1);self.assertFalse(self.p.enabled);self.assertEqual(self.b.releases,0)
    def test_fault_and_generation_not_hidden(self):
        self.launch();self.b.gen+=1
        with self.assertRaises(ValueError):self.c.poll()
        self.assertEqual(self.b.starts,0);self.assertEqual(self.b.releases,0)
    def test_result_wrong_frame_rejected(self):
        self.launch();self.c.poll();self.c.state['result']={'source_rgb_sha256':'bad','video_source':{'frame':0}}
        with self.assertRaises(ValueError):self.p.tick()
        self.assertEqual(self.b.releases,0)

if __name__=='__main__':unittest.main(verbosity=2)
