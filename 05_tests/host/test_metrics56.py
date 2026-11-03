import json,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from host_pipeline import HostPipeline

class Tests(unittest.TestCase):
 def setUp(self):
  self.p=HostPipeline(SimpleNamespace(qualification=None))
 def test_actual_last_twenty_result_timestamps(self):
  # Archived QM timestamps test the estimator, not this QO service's live FPS.
  h=Path(__file__).resolve().parents[2]/'05_tests/fixtures/metrics_results.jsonl'
  rows=[json.loads(x)for x in h.read_text(encoding='utf8').splitlines()]
  rows=[r for r in rows if r['run_id']=='3112f4b0-bb74-469e-bf9d-ecabaf64dd5b'][-21:]
  for a,b in zip(rows,rows[1:]):
   self.p.intervals.append(b['time']-a['time']);self.p.interval_faces.append(b['result']['has_face'])
  s=self.p.snapshot()
  self.assertEqual(s['window_intervals'],20)
  self.assertAlmostEqual(s['recent_fps'],5.098126443671696)
  self.assertAlmostEqual(s['mean_interval_ms'],196.15048999839928)
  self.assertAlmostEqual(s['recent_fps']*s['mean_interval_ms'],1000)
  self.assertAlmostEqual(s['interval_ms'],168.05550002027303)
  self.assertAlmostEqual(s['latest_interval_fps'],5.950415189502081)
  self.assertEqual((s['window_face_frames'],s['window_no_face_frames']),(6,14))
 def test_repeated_close_does_not_extend_stopped_denominator(self):
  self.p.started=10;self.p.completed=10
  with patch('host_pipeline.time.perf_counter',return_value=12):self.p.abort('fault')
  with patch('host_pipeline.time.perf_counter',return_value=100):self.p.abort('reconnect_failed');s=self.p.snapshot()
  self.assertEqual(s['fps'],5);self.assertEqual(self.p.ended,12)
 def test_average_is_count_over_time_not_average_inverse(self):
  self.p.intervals.extend([.1,.3]);s=self.p.snapshot()
  self.assertEqual(s['recent_fps'],5);self.assertEqual(s['mean_interval_ms'],200)
 def test_empty_is_unavailable_not_infinite(self):
  s=self.p.snapshot();self.assertIsNone(s['recent_fps']);self.assertIsNone(s['mean_interval_ms'])

if __name__=='__main__':unittest.main()
