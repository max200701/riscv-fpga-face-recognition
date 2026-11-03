"""Bounded asynchronous raw UART records; never buffer or replay device commands."""
import json,queue,threading,time

class AsyncLoggedSerial:
    def __init__(self,link,folder,capacity=4096):
        self.link=link;self.queue=queue.Queue(capacity);self.failure=None;self.closed=False
        self.streams={}
        try:
            self.streams['tx']=(folder/'serial_tx.bin').open('xb',buffering=65536)
            self.streams['rx']=(folder/'serial_rx.bin').open('xb',buffering=65536)
            self.streams['transactions']=(folder/'transactions.jsonl').open('x',encoding='utf8',buffering=65536)
        except BaseException:
            for f in self.streams.values():f.close()
            link.close();raise
        self.thread=threading.Thread(target=self._writer,name='raw-uart-recorder',daemon=True);self.thread.start()
    def check(self):
        if self.failure:raise RuntimeError('Raw serial evidence writer failed') from self.failure
        if self.closed:raise RuntimeError('Raw serial evidence writer closed')
        if self.queue.full():raise RuntimeError('Raw serial evidence queue full; stop transport')
    def _put(self,kind,value):
        self.check()
        try:self.queue.put_nowait((kind,value))
        except queue.Full:raise RuntimeError('Raw serial evidence queue full; stop transport') from None
    def write(self,b):
        self.check();n=self.link.write(b);self._put('tx',bytes(b[:n]));return n
    def read(self,n):
        self.check();b=self.link.read(n)
        if b:self._put('rx',bytes(b))
        return b
    def flush(self):self.check() # Hardware reply remains the completion evidence.
    def record_transaction(self,row):self._put('transactions',dict(row,t=time.perf_counter()))
    def _writer(self):
        count=0
        while True:
            try:item=self.queue.get(timeout=.1)
            except queue.Empty:
                try:
                    for f in self.streams.values():f.flush()
                except BaseException as e:self.failure=e
                continue
            try:
                if item is None:return
                if self.failure:continue
                kind,value=item
                self.streams[kind].write(json.dumps(value)+'\n' if kind=='transactions' else value)
                count+=1
                if count>=128:
                    for f in self.streams.values():f.flush()
                    count=0
            except BaseException as e:self.failure=e
            finally:self.queue.task_done()
    def drain_records(self):
        self.queue.join();self.check()
    def close(self):
        if self.closed:return
        try:self.link.close()
        finally:
            self.queue.put(None);self.thread.join();self.closed=True
            for f in self.streams.values():f.close()
