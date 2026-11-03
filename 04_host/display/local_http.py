"""Bounded persistent loopback HTTP connections. No request is ever retried.

Each lease owns its connection until the complete response has been consumed.
Unknown POST outcome is returned as an error, never replayed. Idle connections
are discarded before the backend's 12-second keepalive timeout.
"""
import http.client,queue,socket,threading,time

class LocalPool:
    def __init__(self,port,capacity=3,idle_seconds=8,timeout=3):
        self.port=port;self.capacity=capacity;self.idle_seconds=idle_seconds;self.timeout=timeout
        self.available=queue.LifoQueue(capacity);self.slots=threading.BoundedSemaphore(capacity)
        self.lock=threading.Lock();self.stats=dict(requests=0,opened=0,reused=0,errors=0,active=0,peak_active=0)

    def request(self,method,path,body=None,headers=None):
        if not path.startswith('/') or path.startswith('//'):raise ValueError('Loopback relative path only')
        if not self.slots.acquire(timeout=self.timeout):raise TimeoutError('Local HTTP admission timeout')
        conn=None;healthy=False
        with self.lock:
            self.stats['requests']+=1;self.stats['active']+=1
            self.stats['peak_active']=max(self.stats['active'],self.stats['peak_active'])
        try:
            try:
                conn,last=self.available.get_nowait()
                if conn.sock is None or time.monotonic()-last>=self.idle_seconds:
                    conn.close();conn=None
            except queue.Empty:pass
            if conn is None:
                conn=http.client.HTTPConnection('127.0.0.1',self.port,timeout=self.timeout)
                conn.connect();conn.sock.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
                with self.lock:self.stats['opened']+=1
            else:
                with self.lock:self.stats['reused']+=1
            conn.request(method,path,body=body,headers=headers or {})
            response=conn.getresponse();data=response.read()
            meta={key.lower():value for key,value in response.getheaders()}
            healthy=conn.sock is not None and not response.will_close
            return response.status,data,meta
        except BaseException:
            with self.lock:self.stats['errors']+=1
            raise
        finally:
            if conn:
                if healthy:self.available.put_nowait((conn,time.monotonic()))
                else:conn.close()
            with self.lock:self.stats['active']-=1
            self.slots.release()

    def snapshot(self):
        with self.lock:return dict(self.stats)

    def close_idle(self):
        while True:
            try:conn,_=self.available.get_nowait();conn.close()
            except queue.Empty:return
