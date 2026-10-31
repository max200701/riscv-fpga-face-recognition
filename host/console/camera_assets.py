"""Exact RGB source; reference Q16 and PNG are generated only when requested."""
from array import array
from io import BytesIO
import hashlib,sys,zlib,threading
from PIL import Image

def digest(b):return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest(),crc32=f'{zlib.crc32(b)&0xffffffff:08x}')

class LazyAssets(dict):
    def __init__(self,rgb,manifest):
        super().__init__({'frame.rgb':bytes(rgb)});self.manifest=manifest;self.lock=threading.RLock()
    def __missing__(self,key):
        with self.lock:
            if key in self:return self[key]
            rgb=self['frame.rgb']
            if key=='input.bin':
                q=array('i')
                for channel,mean in ((2,104),(1,117),(0,123)):q.extend((v-mean)*65536 for v in rgb[channel::3])
                if q.itemsize!=4:raise RuntimeError('Expected int32')
                if sys.byteorder!='little':q.byteswap()
                value=q.tobytes()
            elif key=='frame.png':
                png=BytesIO();Image.frombytes('RGB',(640,480),rgb).save(png,format='PNG',compress_level=1);value=png.getvalue()
            else:raise KeyError(key)
            self[key]=value;self.manifest['files'][key]=digest(value);return value

def prepare(rgb,token):
    if len(rgb)!=921600:raise ValueError('Camera frame must be exact 640x480 RGB')
    if not isinstance(token,str) or not 1<=len(token)<=100:raise ValueError('Camera frame token')
    manifest=dict(width=640,height=480,source=dict(kind='PC_CAMERA_RGB_LETTERBOX',token=token),files={'frame.rgb':digest(rgb)},model_inference_on_PC=False)
    return manifest,LazyAssets(rgb,manifest)
