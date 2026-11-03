import json,struct,tempfile,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock
from coremark_mode import CoreMarkMixin,decode_benchmark,encode
from video_protocol import ProtocolError,decode
import threading

WORDS=[0x314b4d43,1,0x26102601,6,31250000,2500,450000000,0,0xe9f5,0xe714,0x1fd7,0x8e3a,0,2000,0,1]
class Tests(unittest.TestCase):
    def test_validation_seed_mode(self):
        w=WORDS[:];w[3]|=8;w[8:12]=[0x18f2,0xe3c1,0x0747,0x8d84]
        self.assertTrue(decode_benchmark(struct.pack('<16I',*w),2,2500)['crc_pass'])
        with self.assertRaises(ProtocolError):decode_benchmark(struct.pack('<16I',*w),1,2500)
        for mode in (0,3,True,'2'):
            from demo_console import UserInputError
            with self.assertRaises(UserInputError):CoreMarkMixin().action('coremark',{'mode':mode})
    def test_timer_crc_and_threshold(self):
        result=decode_benchmark(struct.pack('<16I',*WORDS),1,2500)
        self.assertEqual(result['timed_seconds'],14.4)
        for index,value in [(3,2),(6,10),(8,0),(14,1),(4,125000000),(5,1)]:
            w=WORDS[:];w[index]=value
            with self.assertRaises(ProtocolError):decode_benchmark(struct.pack('<16I',*w),1,2500)
    def test_mode_frame_and_normal_unchanged(self):
        b=encode(14,100,4,16,struct.pack('<4I',1,2500,0,0))
        self.assertEqual(len(b),40)
        self.assertEqual(decode(encode(5,101))['op'],5)
        with self.assertRaises(ProtocolError):encode(14,100,4,15,bytes(15))
    def test_worker_success_restores_mode_and_generation(self):
        h=dict(supported=True,ddr_ready=True,safety_ready=True,temp_valid=True,temp_fault=0,over_temp=False,fault=False,done=True,cpu_status=1,result_committed=True)
        client=Mock();client.snapshot.return_value=h;client.result_page.return_value=struct.pack('<16I',*WORDS);client.rearm.return_value={'generation':11}
        d=SimpleNamespace(video=SimpleNamespace(held=None),result=None,embedding=None,static_fingerprint='resident',gallery=SimpleNamespace(revision=6,records=[1]),client=client,idle=Mock(return_value=10),expected_generation=10)
        with tempfile.TemporaryDirectory() as t:
            obj=CoreMarkMixin();obj.pipeline=SimpleNamespace(finishing=False,lock=threading.Lock(),last_result=None);obj.demo=d;obj.state={};obj.new_dir=lambda x:Path(t)/x;obj.qualification=Mock();obj.event=Mock();obj.notify_observation=Mock();obj.sync=Mock()
            obj.action('coremark',{'iterations':2500})
            self.assertEqual(d.expected_generation,11)
            self.assertEqual(obj.state['coremark']['status'],'PASS')
            modecalls=[c for c in client.request.call_args_list if c.args[0]==14]
            self.assertEqual(len(modecalls),2)
            self.assertEqual(modecalls[-1].kwargs['payload'],bytes(16))
            self.assertEqual(json.loads((Path(t)/'coremark/RESULT.json').read_text())['gallery_revision'],6)

if __name__=='__main__':unittest.main()
