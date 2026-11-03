"""Reuse SHA evidence for unchanged frozen files; never reuse board residency."""
import hashlib
from pathlib import Path

class PinCache:
    def __init__(self):self.cache={};self.hashed_bytes=0;self.hash_calls=0
    @staticmethod
    def identity(p):
        s=p.stat();return (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
    def sha(self,path):
        p=Path(path).resolve();key=str(p);before=self.identity(p)
        previous=self.cache.get(key)
        if previous and previous[0]==before:return previous[1]
        digest=hashlib.sha256()
        with p.open('rb') as f:
            while blob:=f.read(1024*1024):digest.update(blob)
        if self.identity(p)!=before:raise RuntimeError('Pinned file changed during hash: '+key)
        result=digest.hexdigest();self.hashed_bytes+=before[2];self.hash_calls+=1
        self.cache[key]=(before,result);return result
