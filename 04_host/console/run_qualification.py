"""Batch evidence reuse while Win32 handles prohibit asset modification/deletion.

Does not cache board health, frame ownership, DDR contents or session generation.
"""
from pathlib import Path
import ctypes, json, threading
from ctypes import wintypes

class LockedQualification:
    def __init__(self, checker, manifest, source_pins, old_manifest, upload, receipt):
        self.checker=checker; self.manifest=Path(manifest)
        self.documents=list(map(Path,(manifest,source_pins,old_manifest,upload,receipt)))
        self.lock=threading.RLock();self.handles=[];self.value=None
        self.kernel=ctypes.WinDLL('kernel32',use_last_error=True)
        self.kernel.CreateFileW.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,ctypes.c_void_p,wintypes.DWORD,wintypes.DWORD,wintypes.HANDLE]
        self.kernel.CreateFileW.restype=wintypes.HANDLE
        self.kernel.CloseHandle.argtypes=[wintypes.HANDLE];self.kernel.CloseHandle.restype=wintypes.BOOL
    def paths(self):
        manifest,source,old,upload,receipt=self.documents
        paths=set(self.documents)
        paths.update(map(Path,json.loads(manifest.read_text())['pins']))
        paths.update(map(Path,json.loads(source.read_text())))
        paths.update(Path(r['path']) for r in json.loads(upload.read_text()) if r['kind']=='static_model')
        return sorted({str(p.resolve()) for p in paths})
    def begin(self):
        with self.lock:
            if self.handles:raise RuntimeError('Asset qualification already leased')
            try:
                paths=self.paths()
                for path in paths:
                    # Read access, SHARE_READ only; reject concurrent writers and deletes.
                    h=self.kernel.CreateFileW(path,0x80000000,1,None,3,0x80,None)
                    if h==ctypes.c_void_p(-1).value:raise ctypes.WinError(ctypes.get_last_error())
                    self.handles.append(h)
                if self.paths()!=paths:raise RuntimeError('Asset list changed while locking')
                self.value=self.checker(self.manifest)
            except BaseException:
                self.end();raise
    def authorize(self,path):
        with self.lock:
            if Path(path)!=self.manifest:raise RuntimeError('Different release identity')
            return self.value if self.handles and self.value is not None else self.checker(path)
    def end(self):
        with self.lock:
            self.value=None
            while self.handles:self.kernel.CloseHandle(self.handles.pop())

