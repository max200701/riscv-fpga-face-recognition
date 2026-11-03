"""Exact HDMI test/source assets. No face inference or hardware access."""
from pathlib import Path
import argparse, hashlib, json, zlib
import cv2
import numpy as np

def digest(b):
    return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest(),crc32=f'{zlib.crc32(b)&0xffffffff:08x}')

def prepare(output, q16=None, image=None, pattern=False):
    assert sum((q16 is not None,image is not None,bool(pattern)))==1
    if q16 is not None:
        raw=Path(q16).read_bytes()
        if len(raw)!=640*480*3*4: raise ValueError('Q16 extent')
        words=np.frombuffer(raw,dtype='<i4').reshape(3,480,640)
        if np.any(words%65536): raise ValueError('Source Q16 is not an exact integer pixel')
        bgr=(words.astype(np.int64)//65536).transpose(1,2,0)+np.array([104,117,123])
        if np.any((bgr<0)|(bgr>255)): raise ValueError('Source Q16 does not invert into RGB8')
        bgr=bgr.astype(np.uint8);source=dict(kind='FROZEN_Q16_EXACT_INVERSE',path=str(Path(q16).resolve()),**digest(raw))
    elif image is not None:
        raw=Path(image).read_bytes()
        if not 0<len(raw)<=16*1024*1024: raise ValueError('Image size')
        im=cv2.imdecode(np.frombuffer(raw,np.uint8),cv2.IMREAD_COLOR)
        if im is None or max(im.shape[:2])>8192: raise ValueError('Image dimensions')
        h,w=im.shape[:2];scale=min(640/w,480/h);nw,nh=max(1,round(w*scale)),max(1,round(h*scale))
        left,top=(640-nw)//2,(480-nh)//2
        bgr=np.full((480,640,3),114,np.uint8)
        bgr[top:top+nh,left:left+nw]=cv2.resize(im,(nw,nh),interpolation=cv2.INTER_LINEAR)
        source=dict(kind='OL_IDENTICAL_LETTERBOX',path=str(Path(image).resolve()),scale=scale,left=left,top=top,**digest(raw))
    else:
        yy,xx=np.indices((480,640));rgb=np.empty((480,640,3),np.uint8)
        # Full-range ramp + per-channel landmarks expose swaps, range clipping,
        # scale/crop, and HDMI pixel order. It is a transport test, not a face.
        rgb[:,:,0]=xx%256;rgb[:,:,1]=yy%256;rgb[:,:,2]=(xx+3*yy)%256
        rgb[:80]=np.repeat(np.array([[255,0,0],[0,255,0],[0,0,255],[255,255,255],[0,0,0],[255,255,0],[0,255,255],[255,0,255]],np.uint8),80,axis=0)[None,:,:]
        rgb[0,0]=[17,33,65];rgb[-1,-1]=[219,147,83];bgr=rgb[:,:,::-1].copy()
        source=dict(kind='RGB_CHANNEL_RANGE_GEOMETRY_DIAGNOSTIC')
    rgb=bgr[:,:,::-1].copy().tobytes()
    q=((bgr.astype(np.int32)-np.array([104,117,123],np.int32))*65536).transpose(2,0,1).astype('<i4').tobytes()
    if q16 is not None and q!=raw: raise AssertionError('Exact inverse failed')
    ok,png=cv2.imencode('.png',bgr)
    if not ok: raise RuntimeError('PNG encode')
    output=Path(output);output.mkdir(parents=True,exist_ok=False)
    assets={'frame.rgb':rgb,'frame.png':png.tobytes(),'input.bin':q}
    for name,value in assets.items(): (output/name).write_bytes(value)
    m=dict(status='PC_SOURCE_ASSET_READY_NOT_HDMI_OR_INFERENCE_PASS',width=640,height=480,
        input_address='01800000',source=source,files={name:digest(value) for name,value in assets.items()},
        rgb_format='uint8 row-major RGB, R then G then B',q16_format='little endian int32 NCHW BGR minus104/117/123 times65536',
        crc32='IEEE reflected 0xedb88320, initial ffffffff, final xor ffffffff; exact file byte order',
        static_until_server_restart=True,model_inference_on_PC=False,
        requirements=['PC actual HDMI active mode640x480','Exact fullscreen viewport in physical pixels','No HDR/night-light/color enhancement/underscan','Compare captured pixels or CRC before claiming source fidelity'])
    (output/'MANIFEST.json').write_text(json.dumps(m,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    return m

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('out',type=Path);g=p.add_mutually_exclusive_group(required=True)
    g.add_argument('--q16',type=Path);g.add_argument('--image',type=Path);g.add_argument('--pattern',action='store_true')
    a=p.parse_args();m=prepare(a.out,a.q16,a.image,a.pattern);print(json.dumps(m,ensure_ascii=False))
