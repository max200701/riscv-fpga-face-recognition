"""Bounded host filesystem microbenchmark, separate files; never board sequence."""
from pathlib import Path
import json,statistics,time
from prefetched_sequence import PrefetchedSequence
from video_protocol import PersistentSequence
H=Path(__file__).resolve().parent;out=H/'sequence_bench01';out.mkdir()
result={}
for label,cls in [('old_sync256',PersistentSequence),('new_prefetched16384',PrefetchedSequence)]:
    owner=cls(out/(label+'.json'));owner.take() # Initial durable reservation is outside steady measurements.
    timings=[]
    try:
        for _ in range(8192):
            t=time.perf_counter_ns();owner.take();timings.append((time.perf_counter_ns()-t)/1e6)
        result[label]=dict(samples=len(timings),mean_ms=statistics.mean(timings),max_ms=max(timings),
            over_1ms=sum(t>1 for t in timings),sum_take_ms=sum(timings))
    finally:owner.close()
result['scope']='Real host filesystem sequence allocation microbenchmark; not complete frame latency or FPGA FPS.'
(out/'RESULT.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf8')
print(json.dumps(result,indent=2))
