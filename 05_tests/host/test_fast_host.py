import unittest,threading,time,tempfile,json,struct,urllib.request,hashlib
from pathlib import Path
from demo_console import ConsoleCore,Server,R
from camera_assets import prepare
import test_ux_flow as flow

class FastHost(unittest.TestCase):
    def test_no_driver_drain_sleep_but_exact_ack_still_required(self):
        from demo_console import LoggedSerial
        from video_protocol import Client,encode
        class Serial:
            def __init__(self):self.response=bytearray(encode(0x84,1,status=0));self.flushed=False
            def write(self,b):return len(b)
            def read(self,n):v=bytes(self.response[:n]);del self.response[:n];return v
            def flush(self):self.flushed=True;raise AssertionError('redundant driver flush')
            def close(self):pass
        class Seq:
            def take(self):return 1
        with tempfile.TemporaryDirectory() as tmp:
            serial=Serial();log=LoggedSerial(serial,Path(tmp));c=Client(log,Seq());self.assertEqual(c.request(4),b'');self.assertFalse(serial.flushed);log.close()

    def test_unused_reference_not_generated_then_exact(self):
        source=R/'05_tests/fixtures/reference';rgb=(source/'frame.rgb').read_bytes()
        m,a=prepare(rgb,'lazy:1');self.assertEqual(set(a),{'frame.rgb'});self.assertEqual(set(m['files']),{'frame.rgb'})
        self.assertEqual(a['input.bin'],(source/'input.bin').read_bytes());self.assertIs(a['input.bin'],a['input.bin'])
        self.assertEqual(m['files']['input.bin']['sha256'],hashlib.sha256(a['input.bin']).hexdigest())
    def test_source_packet_atomic_and_event_wakeup(self):
        with tempfile.TemporaryDirectory() as tmp:
            c=ConsoleCore(tmp,R/'05_tests/fixtures/reference');server=Server(0,c)
            threading.Thread(target=server.serve_forever,daemon=True).start();url='http://127.0.0.1:'+str(server.server_port)
            try:
                raw=urllib.request.urlopen(url+'/source-frame?after=-1').read();n=struct.unpack_from('<I',raw)[0];m=json.loads(raw[4:4+n]);rgb=raw[4+n:]
                self.assertEqual(m['files']['frame.rgb']['sha256'],hashlib.sha256(rgb).hexdigest());self.assertEqual(m['nonce'],server.nonce)
                revision=c.revision;done=[]
                def waiting():done.append(json.loads(urllib.request.urlopen(url+'/state?after='+str(revision)).read()))
                t=threading.Thread(target=waiting);t.start();time.sleep(.02);c.notify();t.join(1);self.assertFalse(t.is_alive());self.assertGreater(done[0]['revision'],revision)
                self.assertRaises(urllib.error.HTTPError,urllib.request.urlopen,urllib.request.Request(url+'/camera-frame',rgb,{'Origin':url,'X-Console-Nonce':'wrong','X-Frame-Token':'x'}))
            finally:server.shutdown();server.server_close()

class CheckedFlow(unittest.TestCase):
    setUp=flow.Tests.setUp;ready=flow.Tests.ready;display=flow.Tests.display
    def test_start_collect_reuse_only_same_call_observations(self):
        self.ready();counts={'snapshot':0,'video':0}
        old_s=self.b.snapshot;old_v=self.b.video_status
        def s():counts['snapshot']+=1;return old_s()
        def v():counts['video']+=1;return old_v()
        self.b.snapshot=s;self.b.video_status=v
        self.c.action('recognize',{});self.assertEqual(counts,{'snapshot':1,'video':1})
        self.c.poll();self.c.poll();self.assertTrue(self.c.state['result']['has_face'])
        self.assertEqual(counts['snapshot'],4);self.assertEqual(counts['video'],4)
    def test_fault_rejected_even_fast_path(self):
        self.ready();self.c.action('recognize',{});old=self.b.snapshot
        def bad():d=old();d['over_temp']=True;return d
        self.b.snapshot=bad
        with self.assertRaises(ValueError):self.c.poll()
        self.assertFalse(self.b.ready)
if __name__=='__main__':unittest.main(verbosity=2)
