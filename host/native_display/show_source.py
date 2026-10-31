"""Exact RGB display on the dedicated FPGA monitor. No serial or face inference.

Owns only its own borderless Tk window. Never changes Windows display modes.
Browser /display-report contract is reused with an explicit native provider tag.
"""
from pathlib import Path
import ctypes as C
from ctypes import wintypes as W
import hashlib,json,msvcrt,re,sys,time,urllib.request,zlib,queue,threading,struct
H=Path(__file__).resolve().parent
BASE='http://127.0.0.1:8783'
from local_http import LocalPool
local_pool=LocalPool(8783,capacity=2)
u=C.WinDLL('user32',use_last_error=True)
u.SetProcessDpiAwarenessContext.argtypes=[W.HANDLE]
u.SetProcessDpiAwarenessContext(W.HANDLE(-4))
class MI(C.Structure):
    _fields_=[('size',W.DWORD),('rect',W.RECT),('work',W.RECT),('flags',W.DWORD),('device',W.WCHAR*32)]
CALLBACK=C.WINFUNCTYPE(W.BOOL,W.HANDLE,W.HDC,C.POINTER(W.RECT),W.LPARAM)
u.GetMonitorInfoW.argtypes=[W.HANDLE,C.POINTER(MI)]
u.GetClientRect.argtypes=[W.HWND,C.POINTER(W.RECT)]
u.ClientToScreen.argtypes=[W.HWND,C.POINTER(W.POINT)]
def monitors():
    found=[]
    @CALLBACK
    def collect(handle,dc,rect,data):
        m=MI();m.size=C.sizeof(m)
        if not u.GetMonitorInfoW(handle,C.byref(m)):return False
        found.append(dict(device=m.device,x=m.rect.left,y=m.rect.top,width=m.rect.right-m.rect.left,height=m.rect.bottom-m.rect.top,primary=bool(m.flags&1)))
        return True
    if not u.EnumDisplayMonitors(None,None,collect,0):raise OSError('EnumDisplayMonitors failed')
    return found
def get(path):
    status,data,_=local_pool.request('GET',path)
    if status!=200:raise RuntimeError('Source HTTP '+str(status))
    return data
def report(nonce,payload):
    status,data,_=local_pool.request('POST','/display-report',json.dumps(dict(payload,nonce=nonce)).encode(),{'Content-Type':'application/json','Origin':BASE})
    if status!=200:raise RuntimeError('Display report HTTP '+str(status))
def record(value):
    value=dict(time=time.strftime('%Y-%m-%dT%H:%M:%S'),**value)
    (H/'STATUS.json').write_text(json.dumps(value,ensure_ascii=False,indent=2),encoding='utf8')
    return value
def main():
    options=[m for m in monitors() if not m['primary'] and (m['width'],m['height'])==(640,480)]
    if len(options)!=1:raise RuntimeError('需要唯一的非主屏 640×480 FPGA 扩展显示器；未更改任何显示设置。')
    target=options[0]
    lock=(H/'source.lock').open('a+b');lock.seek(0)
    if not lock.read(1):lock.write(b'0');lock.flush()
    lock.seek(0);msvcrt.locking(lock.fileno(),msvcrt.LK_NBLCK,1)
    import tkinter as tk
    root=tk.Tk();root.title('FPGA HDMI exact RGB source');root.overrideredirect(True);root.attributes('-topmost',True)
    root.geometry(f"640x480{target['x']:+d}{target['y']:+d}")
    canvas=tk.Label(root,borderwidth=0,highlightthickness=0,padx=0,pady=0);canvas.pack(fill='both',expand=True)
    root.bind('<Escape>',lambda e:root.destroy())
    current=None;photo=None;nonce=None;last_error=None;last_source=None;last_topology=0
    inbox=queue.Queue(maxsize=1);quit_event=threading.Event()
    def fetch_frames():
        previous=-1
        while not quit_event.is_set():
            try:
                fetch_started=time.perf_counter();body=get('/source-frame?after='+str(previous));fetch_elapsed=time.perf_counter()-fetch_started
                size=struct.unpack_from('<I',body)[0];m=json.loads(body[4:4+size]);rgb=body[4+size:];m['_fetch_ms']=fetch_elapsed*1000
                if rgb:
                    expected=m['files']['frame.rgb']
                    if len(rgb)!=921600 or hashlib.sha256(rgb).hexdigest()!=expected['sha256']:raise RuntimeError('Source payload SHA/extent mismatch')
                elif m['source_id']!=previous:raise RuntimeError('New source without RGB')
                inbox.put((m,rgb,None));previous=m['source_id'];root.event_generate('<<SourcePacket>>',when='tail')
            except Exception as e:
                inbox.put((None,None,str(e)));root.event_generate('<<SourcePacket>>',when='tail');quit_event.wait(.25)
    def refresh(event=None):
        nonlocal current,photo,nonce,last_error,last_source,last_topology
        try:
            m,rgb,error=inbox.get_nowait()
        except queue.Empty:
            return
        try:
            if error:raise RuntimeError(error)
            stages={};refresh_started=time.perf_counter();nonce=m['nonce']
            if time.monotonic()-last_topology>2:
                if target not in monitors():raise RuntimeError('FPGA display mode changed')
                last_topology=time.monotonic()
            if current is None or current['source_id']!=m['source_id']:
                if not rgb:raise RuntimeError('Initial source requires RGB')
                image_started=time.perf_counter();ppm=b'P6\n640 480\n255\n'+rgb
                candidate=tk.PhotoImage(data=ppm,format='PPM',master=root)
                returned=root.tk.call(str(candidate),'data','-format','ppm')
                if not isinstance(returned,bytes) or returned.split(b'\n',3)[-1]!=rgb:raise RuntimeError('Tk photo store byte mismatch')
                canvas.configure(image=candidate);photo=candidate;current=m;root.update_idletasks()
                # Wait for the real Windows compositor presentation, not an arbitrary pacing delay.
                present_started=time.perf_counter();stages['image_ms']=(present_started-image_started)*1000
                if C.WinDLL('dwmapi').DwmFlush()!=0:raise RuntimeError('DWM presentation not confirmed')
                stages['dwm_present_ms']=(time.perf_counter()-present_started)*1000
            rect=W.RECT();origin=W.POINT(0,0)
            if not u.GetClientRect(root.winfo_id(),C.byref(rect)) or not u.ClientToScreen(root.winfo_id(),C.byref(origin)):raise RuntimeError('Cannot verify native window rectangle')
            exact=(rect.right,rect.bottom,origin.x,origin.y)==(640,480,target['x'],target['y'])
            if not exact:raise RuntimeError('Source window does not cover exact FPGA pixel rectangle')
            payload=dict(source_id=current['source_id'],rgb_crc32=current['files']['frame.rgb']['crc32'],painted=True,fullscreen=True,viewport_matches=True,physical_width=640,physical_height=480,provider='WIN32_TK_EXACT_FRAME',monitor=target)
            report_started=time.perf_counter();report(nonce,payload);stages['report_ms']=(time.perf_counter()-report_started)*1000
            stages['refresh_total_ms']=(time.perf_counter()-refresh_started)*1000;stages['fetch_longpoll_ms']=m.get('_fetch_ms')
            if last_source!=current['source_id'] or last_error:
                with (H/'presentation.jsonl').open('a',encoding='utf8') as f:f.write(json.dumps(dict(t=time.perf_counter(),source_id=current['source_id'],stages_ms=stages))+'\n')
                record(dict(status='DISPLAY_READY_NOT_BOARD_CAPTURE',**payload,stages_ms=stages,http_pool=local_pool.snapshot(),model_inference_on_PC=False,scope='exact Tk photo bytes and rectangle; event-driven source; not board capture'))
            last_source=current['source_id'];last_error=None
        except Exception as e:
            if nonce:
                try:report(nonce,dict(painted=False,fullscreen=False,provider='WIN32_TK_EXACT_FRAME',error=str(e)))
                except Exception:pass
            if last_error!=str(e):record(dict(status='DISPLAY_ERROR',error=str(e),monitor=target))
            last_error=str(e)
    root.bind('<<SourcePacket>>',refresh)
    root.after(0,lambda:threading.Thread(target=fetch_frames,daemon=True).start())
    try:root.mainloop()
    finally:
        quit_event.set()
        if nonce:
            try:report(nonce,dict(painted=False,fullscreen=False,provider='WIN32_TK_EXACT_FRAME'))
            except Exception:pass
        lock.close()
if __name__=='__main__':
    try:main()
    except Exception as e:record(dict(status='FAILED_RETAINED',error=repr(e)));raise
