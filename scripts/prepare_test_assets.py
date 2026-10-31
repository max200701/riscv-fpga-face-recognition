"""Create a synthetic color pattern only; no camera/person/gallery data."""
from pathlib import Path
import sys,json,zlib,hashlib,struct
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
def main():
 out=ROOT/'host/source/assets_reference01'
 if out.exists():raise SystemExit('Synthetic test assets already exist; not overwriting')
 out.mkdir(parents=True)
 rgb=bytes([17,33,65])*(640*480)
 q=b''.join(struct.pack('<i',(v-b)*65536)*(640*480)for v,b in [(65,104),(33,117),(17,123)])
 (out/'frame.rgb').write_bytes(rgb);(out/'input.bin').write_bytes(q)
 Image.frombytes('RGB',(640,480),rgb).save(out/'frame.png')
 rows={}
 for n in ('frame.rgb','input.bin','frame.png'):
  b=(out/n).read_bytes();rows[n]=dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest(),crc32=f'{zlib.crc32(b)&0xffffffff:08x}')
 (out/'MANIFEST.json').write_text(json.dumps(dict(width=640,height=480,files=rows,source={'kind':'SYNTHETIC_NO_PERSON'},model_inference_on_PC=False),indent=2))
 words=[0x31445246,1,0x261007a1,9,2,2,1,0xffffffff,0,0,0x3ecccccd,1,320<<16,240<<16,80<<16,100<<16]
 # Unit vector, not a measured human embedding. These bytes exercise protocol
 # and lifecycle assertions only and are never board numerical evidence.
 fixture=struct.pack('<16I',*words)+struct.pack('<512f',1.0,*([0.0]*511))
 (out/'synthetic_result.bin').write_bytes(fixture)
 second=out.parent/'assets_second01';second.mkdir(exist_ok=False)
 alt=bytes([65,33,17])*(640*480)
 raw=b''.join(struct.pack('<i',(v-b)*65536)*(640*480)for v,b in [(17,104),(33,117),(65,123)])
 (second/'frame.rgb').write_bytes(alt);(second/'input.bin').write_bytes(raw)
 Image.frombytes('RGB',(640,480),alt).save(second/'frame.png')
 ar={}
 for n in ('frame.rgb','input.bin','frame.png'):
  b=(second/n).read_bytes();ar[n]=dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest(),crc32=f'{zlib.crc32(b)&0xffffffff:08x}')
 (second/'MANIFEST.json').write_text(json.dumps(dict(width=640,height=480,files=ar,source={'kind':'SYNTHETIC_NO_PERSON'},model_inference_on_PC=False),indent=2))
 print(out)
if __name__=='__main__':main()
