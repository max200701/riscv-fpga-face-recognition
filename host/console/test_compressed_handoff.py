import copy,json,tempfile,time,unittest
from pathlib import Path
from unittest.mock import patch
from run_qualification import LockedQualification
from async_records import AsyncRecords
import test_host_pipeline as fixtures
from video_protocol import Client,REARM,ProtocolError

class LeaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);p=Path(self.tmp.name)
        self.asset=p/'asset';self.asset.write_bytes(b'frozen')
        docs=[p/name for name in ('manifest','sources','old','upload','receipt')]
        for path,value in zip(docs,({'pins':{str(self.asset):'x'}},{str(self.asset):'x'},{},[],{})):
            path.write_text(json.dumps(value))
        self.calls=0
        def check(path):self.calls+=1;return {'checked':True}
        self.q=LockedQualification(check,*docs);self.addCleanup(self.q.end);self.m=docs[0]
    def test_active_frozen_files_cannot_be_written_or_deleted(self):
        self.q.begin()
        with self.assertRaises(OSError):self.asset.write_bytes(b'changed')
        with self.assertRaises(OSError):self.asset.unlink()
        for _ in range(100):self.assertTrue(self.q.authorize(self.m)['checked'])
        self.assertEqual(self.calls,1)
        self.q.end();self.asset.write_bytes(b'changed');self.q.authorize(self.m);self.assertEqual(self.calls,2)
    def test_existing_writer_prevents_qualification(self):
        with self.asset.open('r+b'):
            with self.assertRaises(OSError):self.q.begin()
        self.assertFalse(self.q.handles)
    def test_checker_failure_releases_handles(self):
        self.q.checker=lambda path:(_ for _ in ()).throw(ValueError('bad pin'))
        with self.assertRaises(ValueError):self.q.begin()
        self.asset.write_bytes(b'released');self.assertFalse(self.q.handles)
    def test_different_release_rejected(self):
        self.q.begin()
        with self.assertRaises(RuntimeError):self.q.authorize(self.asset)

class RecordTests(unittest.TestCase):
    def test_order_and_snapshot_not_mutable_reference(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp);q=AsyncRecords();self.addCleanup(q.close)
            value={'i':1};q.submit('append',p/'log',value);value['i']=99
            q.submit('append',p/'log',{'i':2});q.submit('result',p/'result',{'ok':True},b'123');q.flush()
            self.assertEqual([json.loads(l)['i']for l in (p/'log').read_text().splitlines()],[1,2])
            self.assertEqual((p/'result/embedding.bin').read_bytes(),b'123')
    def test_failure_is_visible_and_rejects_new_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            q=AsyncRecords();self.addCleanup(q.close);q.submit('append',Path(tmp)/'missing/log',{})
            with self.assertRaises(RuntimeError):q.flush()
            with self.assertRaises(RuntimeError):q.submit('append',Path(tmp)/'ok',{})

class ReceiptClient:
    rearm_checked=Client.rearm_checked
    def __init__(self):self.ops=[];self.gen=4
    def request(self,op,**kw):self.ops.append(op);self.gen+=1
    def session(self):return dict(generation=self.gen,start_allowed=True,pages_seen=0)

class ProtocolTests(unittest.TestCase):
    def test_rearm_reuses_only_valid_completion_receipt(self):
        c=ReceiptClient();before=dict(generation=4,rearm_allowed=True,memory_drained=True,results_acknowledged=True)
        self.assertEqual(c.rearm_checked(4,before)['generation'],5);self.assertEqual(c.ops,[REARM])
    def test_bad_receipts_do_not_mutate_board(self):
        valid=dict(generation=4,rearm_allowed=True,memory_drained=True,results_acknowledged=True)
        for key,value in [('generation',3),('memory_drained',False),('results_acknowledged',False),('rearm_allowed',False)]:
            c=ReceiptClient();bad=dict(valid,**{key:value})
            with self.assertRaises(RuntimeError):c.rearm_checked(4,bad)
            self.assertEqual(c.ops,[])

class HandoffTests(unittest.TestCase):
    setUp=fixtures.Tests.setUp;display=fixtures.Tests.display;launch=fixtures.Tests.launch
    def enable_receipt(self):
        old_collect=self.b.collect;old_rearm=self.b.rearm
        def collect(*a,**kw):
            result=old_collect(*a,**kw)
            self.b.last_collect_session=dict(generation=self.b.gen,rearm_allowed=True,memory_drained=True,results_acknowledged=True)
            return result
        self.b.collect=collect;self.used=0
        def rearm_checked(g,receipt):
            self.assertEqual(receipt['generation'],g);self.used+=1;return old_rearm(g)
        self.b.rearm_checked=rearm_checked
    def test_same_call_reuses_receipt_and_keeps_source(self):
        self.enable_receipt();self.launch();self.p.feed('test',2,self.other);self.c.poll();self.display()
        self.b.ready=True;self.c.poll()
        self.assertEqual(self.used,1);self.assertEqual(self.b.arms,2);self.assertEqual(self.b.releases,1)
        self.assertIsNone(self.c._immediate_arm_checked)
    def test_delayed_display_does_not_reuse_old_receipt(self):
        self.enable_receipt();self.launch();self.p.feed('test',2,self.other);self.c.poll()
        self.b.ready=True;self.c.poll();self.assertEqual(self.used,0)
        self.display();self.p.tick();self.assertEqual(self.used,0);self.assertEqual(self.b.arms,2)
    def test_rearm_health_fault_blocks_next_arm(self):
        self.enable_receipt();self.launch();self.p.feed('test',2,self.other);self.c.poll();self.display();old=self.b.snapshot
        initial=self.b.gen
        def bad_after_rearm():
            s=old()
            if self.b.gen>initial:s['over_temp']=True
            return s
        self.b.snapshot=bad_after_rearm;self.b.ready=True
        with self.assertRaises(ProtocolError):self.c.poll()
        self.assertEqual(self.b.arms,1);self.assertIsNone(self.c._immediate_arm_checked)
    def test_high_resolution_response_uses_perf_counter(self):
        self.launch()
        with patch('runtime_demo.time.perf_counter',side_effect=[1.0,1.0001]):
            self.c.demo.start();self.b.ready=True;r,_=self.c.demo.collect()
        self.assertAlmostEqual(r['host_observed_seconds'],.0001)
    def test_pause_freezes_recent_fps_without_counting_preview(self):
        self.launch();self.c.poll();self.b.ready=True;self.c.poll();self.p.stop('test');self.p.tick()
        a=self.p.snapshot();self.assertEqual(a['completed'],1);self.assertIsNone(a['recent_fps'])
        self.assertEqual(a['fps'],self.p.snapshot()['fps'])

if __name__=='__main__':unittest.main(verbosity=2)
