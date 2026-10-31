"""Console02 review regressions; all board and serial operations are explicit fakes."""
from pathlib import Path
import json,sys,tempfile,types,unittest
from unittest.mock import patch
from demo_console import ConsoleCore,Worker,LoggedSerial,R
from test_runtime_demo import Board
from test_gallery import Fake,SYNTHETIC_RESULT
from gallery import Gallery,GalleryTransfer,Record,BASE
from video_protocol import Client,WRITE,encode,PersistentSequence,IndeterminateTransportError,ProtocolError

class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.p=Path(self.tmp.name)
        self.core=ConsoleCore(self.p,R/'source/assets_reference01');self.addCleanup(self.core.close)
    def connected(self):
        self.board=Board();self.core.connector=lambda port:(self.board,lambda:None);self.core.connect('FAKE')
        self.core.demo.static_fingerprint='TEST_ONLY';self.core.demo.install_gallery(Gallery(1))
    def result(self):
        self.connected();self.core.display_report(dict(source_id=self.core.source_id,rgb_crc32=self.core.state['source_crc'],painted=True,fullscreen=True,viewport_matches=True,physical_width=640,physical_height=480))
        self.core.action('arm',{});self.core.action('start',{});self.core.poll()
    def work(self,name,p):
        if not hasattr(self,'worker'):self.worker=Worker(self.core);self.worker.start()
        self.worker.queue.put((name,p));self.worker.queue.join()
    def test_invalid_name_and_id_preserve_owned_source_then_valid_enrollment(self):
        self.result();original=self.core.demo;before=len(self.board.events)
        for payload in [dict(identity=7,name=''),dict(identity=7,name='x'*81),dict(identity='oops',name='ok'),dict(identity=0,name='ok')]:
            self.work('enroll',payload);self.assertIs(self.core.demo,original);self.assertTrue(self.core.demo.video.held);self.assertEqual(len(self.board.events),before)
        self.work('enroll',dict(identity=7,name='valid'));self.assertIs(self.core.demo,original);self.assertFalse(self.board.active);self.assertEqual(self.core.demo.gallery.records[0].identity,7)
    def test_unready_display_keeps_idle_connection(self):
        self.connected();original=self.core.demo;before=len(self.board.events);self.work('arm',{})
        self.assertIs(self.core.demo,original);self.assertEqual(len(self.board.events),before)
    def test_failed_constructor_closes_link_and_sequence(self):
        class Link:
            closed=False
            def open(self):pass
            def close(self):self.closed=True
        link=Link();self.core.release='fake'
        with patch('demo_console.release_check',return_value={}),patch.dict(sys.modules,{'serial':types.SimpleNamespace(Serial=lambda *a,**k:link)}),patch('demo_console.RuntimeDemo',side_effect=ProtocolError('initial snapshot failure')):
            self.work('connect',dict(port='COM999'))
        self.assertTrue(link.closed);self.assertIsNone(self.core.demo);self.assertIsNone(self.core.sequences)
        seq=PersistentSequence(self.p/'sequence.json');seq.close()
    def test_failed_serial_open_releases_sequence(self):
        self.core.release='fake'
        def fail(*a,**k):raise OSError('fake port denied')
        with patch('demo_console.release_check',return_value={}),patch.dict(sys.modules,{'serial':types.SimpleNamespace(Serial=fail)}):self.work('connect',dict(port='COM999'))
        self.assertIsNone(self.core.sequences);seq=PersistentSequence(self.p/'sequence.json');seq.close()
    def test_logging_open_failure_closes_acquired_serial(self):
        class Link:
            closed=False
            def open(self):pass
            def close(self):self.closed=True
        link=Link();(self.p/'serial_rx.bin').write_bytes(b'existing')
        with self.assertRaises(FileExistsError):LoggedSerial(link,self.p)
        self.assertTrue(link.closed)
    def test_health_protocol_and_failed_write_are_not_user_validation(self):
        for error in (ProtocolError('health fault'),ProtocolError('source generation changed'),TimeoutError('indeterminate ACK')):
            with self.subTest(error=str(error)):
                self.core.close();self.connected()
                with patch.object(self.core,'action',side_effect=error):self.work('upload',{})
                self.assertIsNone(self.core.demo);self.assertIn(str(error),self.core.state['error'])
    def test_gallery_sizes_obey_actual_endpoint_4k_geometry(self):
        feature=SYNTHETIC_RESULT.read_bytes()[64:]
        for count in (1,2,5,16):
            with self.subTest(count=count):
                board=Fake();g=Gallery(1,tuple(Record(i+1,'fixture',feature,{'scope':'offline_fixture'})for i in range(count)))
                receipt=GalleryTransfer(board,lambda:None).install(g)
                self.assertEqual(board.memory[:len(g.binary())],g.binary());self.assertEqual(receipt['count'],count)
                for op,a,n,payload in board.events:self.assertLessEqual((a&4095)+n,4096);self.assertEqual(n%32,0)
                writes=[x for x in board.events if x[0]==WRITE]
                self.assertEqual(writes[0],(WRITE,BASE,32,bytes(32)));self.assertEqual(writes[-1],(WRITE,BASE,32,g.binary()[:32]))
                if count>1:self.assertTrue(any(n==480 for op,a,n,payload in writes))

class TransportTests(unittest.TestCase):
    def client(self,mode):
        class Seq:
            def take(self):return 19
        class Link:
            def __init__(self):self.writes=[];self.reply=b'';self.fail_receive=False
            def write(self,b):
                self.writes.append(b)
                if len(self.writes)==1:
                    if mode=='short':return len(b)-1
                    if mode=='write_timeout':raise TimeoutError('fake write deadline')
                    if mode=='receive_timeout':self.fail_receive=True
                self.reply=encode(WRITE|0x80,19,address=0x10000);return len(b)
            def flush(self):pass
            def read(self,n):
                if self.fail_receive:self.fail_receive=False;raise TimeoutError('fake ACK lost')
                data,self.reply=self.reply[:n],self.reply[n:];return data
        link=Link();return Client(link,Seq()),link
    def test_partial_write_is_never_retransmitted(self):
        c,l=self.client('short')
        with self.assertRaises(IndeterminateTransportError):c.request(WRITE,address=0x10000,length=32,payload=bytes(32))
        self.assertEqual(len(l.writes),1)
    def test_submission_timeout_is_never_retransmitted(self):
        c,l=self.client('write_timeout')
        with self.assertRaises(IndeterminateTransportError):c.request(WRITE,address=0x10000,length=32,payload=bytes(32))
        self.assertEqual(len(l.writes),1)
    def test_complete_packet_lost_ack_replays_exact_request(self):
        c,l=self.client('receive_timeout');self.assertEqual(c.request(WRITE,address=0x10000,length=32,payload=bytes(32)),b'')
        self.assertEqual(len(l.writes),2);self.assertEqual(l.writes[0],l.writes[1])

if __name__=='__main__':unittest.main(verbosity=2)
