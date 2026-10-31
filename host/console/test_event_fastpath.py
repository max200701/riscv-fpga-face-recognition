import json,queue,struct,tempfile,threading,time,unittest
from pathlib import Path
from unittest.mock import patch
from prefetched_sequence import PrefetchedSequence
from video_protocol import PersistentSequence,Client,encode,ProtocolError
from async_serial_records import AsyncLoggedSerial
from demo_console import ConsoleCore,Worker,R

class SequenceTests(unittest.TestCase):
    def test_unique_durable_sequences_and_reopen_above_reserved_high_water(self):
        with tempfile.TemporaryDirectory() as d:
            class Ledger(PrefetchedSequence):
                durable=0
                def _persist(self,previous):
                    old,end=super()._persist(previous);self.durable=end;return old,end
            p=Path(d)/'s.json';s=Ledger(p,block=64,low_water=32)
            try:
                values=[]
                for _ in range(300):
                    value=s.take();values.append(value)
                    self.assertLessEqual(value,s.durable)
                self.assertEqual(values,list(range(1,301)))
                with self.assertRaises(RuntimeError):PersistentSequence(p)
            finally:s.close()
            high=json.loads(p.read_text())['reserved_through'];next_owner=PersistentSequence(p)
            try:self.assertGreater(next_owner.take(),high)
            finally:next_owner.close()

    def test_slow_refill_does_not_block_already_durable_pool(self):
        entered=threading.Event();unblock=threading.Event()
        class Slow(PrefetchedSequence):
            def _persist(self,previous):
                if previous is not None:entered.set();unblock.wait(2)
                return super()._persist(previous)
        with tempfile.TemporaryDirectory() as d:
            s=Slow(Path(d)/'s.json',block=64,low_water=32)
            try:
                for _ in range(32):s.take()
                self.assertTrue(entered.wait(1))
                values=[];consumer=threading.Thread(target=lambda:values.extend(s.take() for _ in range(16)))
                consumer.start();consumer.join(.2)
                self.assertFalse(consumer.is_alive(),'No disk completion dependency while durable pool remains')
                self.assertEqual(values,list(range(33,49)))
            finally:unblock.set();s.close()

    def test_failed_reservation_does_not_allocate_unpersisted_number(self):
        class Broken(PrefetchedSequence):
            def _persist(self,previous):raise OSError('disk failure')
        with tempfile.TemporaryDirectory() as d:
            s=Broken(Path(d)/'s.json',block=64,low_water=32)
            try:
                with self.assertRaisesRegex(RuntimeError,'reservation failed'):s.take()
                self.assertEqual(s.next_value,0)
            finally:s.close()

    def test_closed_owner_refuses_take(self):
        with tempfile.TemporaryDirectory() as d:
            s=PrefetchedSequence(Path(d)/'s.json');s.take();s.close()
            with self.assertRaises(RuntimeError):s.take()

class FakeSerial:
    def __init__(self,response=b''):self.response=bytearray(response);self.read_calls=[];self.written=[];self.closed=False
    def read(self,n):
        self.read_calls.append(n);value=bytes(self.response[:n]);del self.response[:n];return value
    def write(self,b):self.written.append(bytes(b));return len(b)
    def close(self):self.closed=True

class IOTests(unittest.TestCase):
    def test_same_call_video_substitutes_only_pre_result_generation_query(self):
        from video_protocol import CPU_BUILD
        result=[0x31445246,1,CPU_BUILD,15,1,1,1,1,0x3f000000,1,0x3ecccccd,1,0,0,0,0]
        class Scripted(Client):
            def __init__(self):self.calls=[];self.generation=7
            def request(self,op,address=0,**kw):
                self.calls.append(op)
                if op==6:return struct.pack('<16I',*result)
                if op==13:return b''
                if op==7:return struct.pack('<16I',0x31534553,1,self.generation,14,0,1,1,32,*([0]*8))
                raise AssertionError(op)
        valid=dict(result_ready=True,result_source_id=1,session_generation=7,held_session_generation=7,result_session_generation=7)
        c=Scripted();r,_=c.collect_from_video(7,valid,include_embedding=False)
        self.assertEqual(c.calls,[6,13,7]);self.assertEqual(r['generation'],7)
        c=Scripted()
        with self.assertRaises(ProtocolError):c.collect_from_video(7,dict(valid,session_generation=8),False)
        self.assertEqual(c.calls,[])
        c=Scripted();c.generation=8
        with self.assertRaises(ProtocolError):c.collect_from_video(7,valid,False)
        self.assertEqual(c.calls,[6,13,7]) # Final generation/ACK is still fresh and mandatory.

    def test_raw_record_order_and_exact_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);raw=FakeSerial(b'123456');s=AsyncLoggedSerial(raw,p)
            s.write(b'abc');self.assertEqual(s.read(2),b'12');s.flush();s.read(4)
            s.record_transaction({'seq':9});s.close()
            self.assertTrue(raw.closed);self.assertEqual((p/'serial_tx.bin').read_bytes(),b'abc')
            self.assertEqual((p/'serial_rx.bin').read_bytes(),b'123456')
            self.assertEqual(json.loads((p/'transactions.jsonl').read_text())['seq'],9)

    def test_evidence_error_blocks_next_device_write(self):
        with tempfile.TemporaryDirectory() as d:
            raw=FakeSerial();s=AsyncLoggedSerial(raw,Path(d));s.failure=OSError('disk')
            try:
                with self.assertRaises(RuntimeError):s.write(b'must not submit')
                self.assertEqual(raw.written,[])
            finally:s.close()

    def test_receive_header_single_read_and_resynchronization(self):
        class Seq:
            def take(self):return 1
        for garbage in (b'',b'garbage!'):
            packet=encode(0x85,1,length=64,payload=bytes(range(64)))
            raw=FakeSerial(garbage+packet);raw.flush=lambda:None
            c=Client(raw,Seq(),attempts=1)
            self.assertEqual(c.request(5),bytes(range(64)))
            if not garbage:self.assertEqual(raw.read_calls,[24,64])

class EventTests(unittest.TestCase):
    def test_http_action_returns_receipt_after_queue_and_wake(self):
        import urllib.request
        from demo_console import Server
        with tempfile.TemporaryDirectory() as d:
            c=ConsoleCore(d,R/'source/assets_reference01');s=Server(0,c)
            threading.Thread(target=s.serve_forever,daemon=True).start()
            try:
                url='http://127.0.0.1:'+str(s.server_port)
                payload=json.dumps(dict(nonce=s.nonce,action='select_display',provider='WIN32_TK_EXACT_FRAME',source_instance='default')).encode()
                req=urllib.request.Request(url+'/action',payload,{'Origin':url,'Content-Type':'application/json'})
                with urllib.request.urlopen(req,timeout=2) as response:
                    self.assertEqual(response.status,202);self.assertTrue(json.load(response)['queued'])
            finally:s.shutdown();s.server_close()

    def test_worker_does_not_lose_wake_arriving_inside_poll(self):
        # Inject an event at the exact old poll->wait race; stop the daemon via BaseException.
        class Finish(BaseException):pass
        class Core:
            def __init__(self):
                self.state={'auto_stage':None};self.pipeline=type('Pipeline',(),{'wake':threading.Event()})()
                self.calls=0;self.elapsed=None
            def poll(self):
                self.calls+=1
                if self.calls==1:self.t=time.perf_counter();self.pipeline.wake.set()
                else:self.elapsed=time.perf_counter()-self.t;raise Finish()
            def notify_observation(self):pass
        core=Core();worker=Worker(core)
        with self.assertRaises(Finish):worker.run()
        self.assertLess(core.elapsed,.015,'Event must not incur the old 20ms race window')

    def test_ddr_counter_changes_do_not_flood_ui_but_result_does(self):
        with tempfile.TemporaryDirectory() as d:
            c=ConsoleCore(d,R/'source/assets_reference01')
            c.state['health']={'phase':1,'read_bytes':1};c.notify_observation();rev=c.revision
            for i in range(100):c.state['health']['read_bytes']=i;c.notify_observation()
            self.assertEqual(c.revision,rev)
            c.state['health']['result_committed']=True;c.notify_observation();self.assertGreater(c.revision,rev)

if __name__=='__main__':unittest.main(verbosity=2)
