"""Finite off-thread evidence writer. Failure/full queue prevents new work."""
import copy,json,queue,threading

class AsyncRecords:
    def __init__(self,capacity=128):
        self.queue=queue.Queue(capacity);self.failure=None;self.closed=False
        self.thread=threading.Thread(target=self.run,name='demo-evidence-writer',daemon=True);self.thread.start()
    def check(self):
        if self.failure:raise RuntimeError('Evidence writer failed: '+repr(self.failure))
        if self.closed:raise RuntimeError('Evidence writer closed')
    def submit(self,kind,path,value,extra=None):
        self.check()
        try:self.queue.put_nowait((kind,path,copy.deepcopy(value),extra))
        except queue.Full:raise RuntimeError('Evidence queue full; no new frame may start') from None
    def run(self):
        while True:
            item=self.queue.get()
            try:
                if item is None:return
                kind,path,value,extra=item
                if self.failure:continue
                if kind=='append':
                    with path.open('a',encoding='utf8') as f:f.write(json.dumps(value,ensure_ascii=False)+'\n')
                elif kind=='result':
                    path.mkdir()
                    (path/'result.json').write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
                    (path/'embedding.bin').write_bytes(extra)
                else:raise ValueError(kind)
            except BaseException as e:self.failure=e
            finally:self.queue.task_done()
    def flush(self):
        self.queue.join();self.check()
    def close(self):
        self.queue.join();self.closed=True;self.queue.put(None);self.thread.join(5)

