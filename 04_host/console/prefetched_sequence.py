"""Persist sequence high-water ahead of consumption, never after submission."""
import json, os, threading, time
from video_protocol import PersistentSequence

class PrefetchedSequence(PersistentSequence):
    def __init__(self,path,block=16384,low_water=8192):
        if not 0 < low_water < block:raise ValueError('Sequence reserve bounds')
        super().__init__(path,block)
        self.low_water=low_water;self.condition=threading.Condition()
        self.stopping=False;self.requested=True;self.failure=None
        self.reservations=0;self.empty_waits=0;self.max_reserve_ms=0
        self.thread=threading.Thread(target=self._refill,name='sequence-high-water',daemon=True)
        self.thread.start()

    def _persist(self,previous):
        # One lifetime file lock and one writer. Other owners remain rejected.
        disk=0
        if self.path.exists():
            state=json.loads(self.path.read_text(encoding='utf8'))
            if state.get('schema')!='OL_SEQUENCE_V1':raise RuntimeError('Sequence schema changed')
            disk=state['reserved_through']
            if type(disk)is not int or not 0<=disk<=0xfffffffe:raise RuntimeError('Sequence high-water invalid')
        if previous is not None and previous != disk:raise RuntimeError('Sequence file changed under exclusive ownership')
        end=min(disk+self.block,0xfffffffe)
        if end<=disk:raise RuntimeError('Sequence exhausted; explicit new board session required')
        temporary=self.path.with_suffix('.new')
        with temporary.open('w',encoding='utf8') as f:
            json.dump(dict(schema='OL_SEQUENCE_V1',reserved_through=end),f)
            f.flush();os.fsync(f.fileno())
        os.replace(temporary,self.path)
        return disk,end

    def _refill(self):
        while True:
            with self.condition:
                self.condition.wait_for(lambda:self.requested or self.stopping)
                if self.stopping:return
                self.requested=False;previous=self.limit-1 if self.limit else None
            began=time.perf_counter()
            try:
                old,end=self._persist(previous)
                with self.condition:
                    if self.next_value==0:self.next_value=old+1
                    self.limit=end+1;self.reservations+=1
                    self.requested=self.limit-self.next_value<=self.low_water
                    self.max_reserve_ms=max(self.max_reserve_ms,(time.perf_counter()-began)*1000)
                    self.condition.notify_all()
            except BaseException as e:
                with self.condition:self.failure=e;self.condition.notify_all()
                return

    def take(self):
        with self.condition:
            if self.stopping:raise RuntimeError('Sequence owner closed')
            if self.next_value==self.limit:
                self.empty_waits+=1;self.requested=True;self.condition.notify_all()
                if not self.condition.wait_for(lambda:self.next_value<self.limit or self.failure or self.stopping,timeout=5):
                    raise RuntimeError('Sequence reserve not yet durable; nothing submitted')
            if self.failure:raise RuntimeError('Sequence reservation failed') from self.failure
            if self.stopping:raise RuntimeError('Sequence owner closed')
            value=self.next_value;self.next_value+=1
            if self.limit-self.next_value<=self.low_water:
                self.requested=True;self.condition.notify_all()
            return value

    def close(self):
        if hasattr(self,'condition'):
            with self.condition:self.stopping=True;self.condition.notify_all()
            self.thread.join() # Do not release the OS lock during a pending durable write.
        super().close()
