import unittest,struct,tempfile,json
from pathlib import Path
from types import SimpleNamespace
from video_protocol import parse_status
from video_session import VideoSession,BoardHealthError
from demo_console import ConsoleCore

RAW=[826556998,1,638592032,837,31250000,125000000,125000000,2801,1,0,8,12423,3809969760,2861732480,78974,1280]
class TestHealth(unittest.TestCase):
 def snap(self,raw=None):return parse_status(struct.pack('<16I',*(RAW if raw is None else raw)))
 def test_actual_initial_fault_is_client_not_heat(self):
  s=self.snap();self.assertTrue(s['client_fault']);self.assertTrue(s['transport_fault']);self.assertFalse(s['core_fault']);self.assertFalse(s['over_temp']);self.assertEqual(s['ddr_bridge_fault_code'],0)
 def test_actual_later_cpu_secondary_fault(self):
  r=RAW.copy();r[9]=206;r[15]=0x700;s=self.snap(r)
  self.assertTrue(s['core_fault']);self.assertTrue(s['client_fault']);self.assertEqual(s['cpu_status'],206)
 def test_health_retains_original_snapshot_and_issues_one_request(self):
  calls=[];s=self.snap();v=VideoSession(SimpleNamespace(snapshot=lambda:(calls.append('STATUS'),s)[1]),lambda:None)
  with self.assertRaises(BoardHealthError)as c:v.health()
  self.assertEqual(calls,['STATUS']);self.assertEqual(c.exception.health_snapshot,s);self.assertIn('DDR访问适配器',str(c.exception));self.assertNotIn('过温保护',str(c.exception))
 def test_healthy_no_extra_protocol(self):
  r=RAW.copy();r[3]=448;r[15]=0;s=self.snap(r);calls=[]
  v=VideoSession(SimpleNamespace(snapshot=lambda:(calls.append('STATUS'),s)[1]),lambda:None)
  self.assertEqual(v.health(),s);self.assertEqual(calls,['STATUS'])
 def test_overtemp_still_blocks(self):
  r=RAW.copy();r[8]=17;r[15]=0;s=self.snap(r)
  with self.assertRaises(BoardHealthError)as c:VideoSession(SimpleNamespace(snapshot=lambda:s),lambda:None).health()
  self.assertIn('过温保护',str(c.exception))
 def test_fault_archived_without_release_or_reset(self):
  with tempfile.TemporaryDirectory()as folder:
   core=SimpleNamespace(state={},new_dir=lambda prefix:Path(folder)/prefix)
   ConsoleCore.preserve_health_failure(core,BoardHealthError(self.snap()))
   r=json.loads(Path(core.state['last_board_fault_path']).read_text(encoding='utf8'))
   self.assertEqual(r['health']['raw'],RAW);self.assertFalse(r['board_reset']);self.assertFalse(r['release_issued'])
 def test_non_health_error_not_mislabelled(self):
  core=SimpleNamespace(state={});ConsoleCore.preserve_health_failure(core,ValueError('serial disconnected'));self.assertEqual(core.state,{})
if __name__=='__main__':unittest.main()
