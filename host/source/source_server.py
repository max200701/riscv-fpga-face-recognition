"""Read-only loopback source display; never opens serial/JTAG or starts FPGA."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import argparse, hashlib, json, secrets, time, zlib

H=Path(__file__).resolve().parent
def load_assets(folder):
    folder=Path(folder);m=json.loads((folder/'MANIFEST.json').read_text(encoding='utf8'))
    if (m['width'],m['height'])!=(640,480): raise ValueError('VGA source only')
    assets={}
    for name in ('frame.rgb','frame.png','input.bin'):
        b=(folder/name).read_bytes();r=m['files'][name]
        if len(b)!=r['bytes'] or hashlib.sha256(b).hexdigest()!=r['sha256'] or f'{zlib.crc32(b)&0xffffffff:08x}'!=r['crc32']:
            raise ValueError('Source changed: '+name)
        assets[name]=b
    if len(assets['frame.rgb'])!=921600 or len(assets['input.bin'])!=3686400: raise ValueError('Frame extent')
    return m,assets

class SourceServer(ThreadingHTTPServer):
    daemon_threads=True
    def __init__(self,port,folder):
        self.manifest,self.assets=load_assets(folder)
        self.nonce=secrets.token_hex(16);self.display=None
        super().__init__(('127.0.0.1',port),Handler)

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def reply(self,b,kind='application/json',status=200):
        self.send_response(status);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(b)))
        self.send_header('Cache-Control','no-store');self.send_header('X-Content-Type-Options','nosniff');self.end_headers();self.wfile.write(b)
    def do_GET(self):
        if self.path=='/': self.reply((H/'source.html').read_bytes().replace(b'__NONCE__',self.server.nonce.encode()),'text/html; charset=utf-8')
        elif self.path=='/frame.rgb': self.reply(self.server.assets['frame.rgb'],'application/octet-stream')
        elif self.path=='/manifest': self.reply(json.dumps(self.server.manifest,ensure_ascii=False).encode())
        elif self.path=='/status':
            d=self.server.display
            self.reply(json.dumps(dict(scope='BROWSER_DISPLAY_ONLY_NOT_CAPTURE_PROOF',source=self.server.manifest['files']['frame.rgb'],
                report=d,report_fresh=bool(d and time.monotonic()-d['received_monotonic']<3),hardware_connected=False,serial_access=False)).encode())
        else: self.reply(b'{}',status=404)
    def do_POST(self):
        if self.path!='/display-report': return self.reply(b'{}',status=404)
        try:
            if self.headers.get('Origin')!=f'http://127.0.0.1:{self.server.server_port}': raise ValueError('Origin')
            size=int(self.headers.get('Content-Length','0'))
            if not 0<size<=2048: raise ValueError('Size')
            d=json.loads(self.rfile.read(size))
            if d.pop('nonce',None)!=self.server.nonce: raise ValueError('Token')
            for k in ('physical_width','physical_height','rgb_crc32','fullscreen','painted','viewport_matches'):
                if k not in d: raise ValueError('Missing field')
            # This receipt is diagnostics only. Never let browser input authorize FPGA.
            d['received_monotonic']=time.monotonic();self.server.display=d
            self.reply(b'{"saved":true}')
        except (ValueError,TypeError,json.JSONDecodeError): self.reply(b'{"saved":false}',status=400)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('assets',type=Path);p.add_argument('--port',type=int,default=8772);a=p.parse_args()
    server=SourceServer(a.port,a.assets)
    print(f'PC source only: http://127.0.0.1:{server.server_port}/ ; no hardware access',flush=True)
    server.serve_forever()
