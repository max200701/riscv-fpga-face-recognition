"""Restore the original PDS text reports from the repository's XZ files."""
from pathlib import Path
import hashlib,json,lzma,os

ROOT=Path(__file__).resolve().parents[1]
def digest(path):
    with path.open('rb')as f:return hashlib.file_digest(f,'sha256').hexdigest()
def main():
    rows=json.loads((ROOT/'07_docs/COMPRESSED_REPORTS.json').read_text())
    for r in rows:
        src=ROOT/r['file'];dst=ROOT/r['restored_file']
        if dst.is_file():
            if digest(dst)!=r['restored_sha256']:raise RuntimeError('Existing report has different content: '+str(dst))
            print('Ready:',r['restored_file']);continue
        tmp=dst.with_name(dst.name+'.tmp')
        h=hashlib.sha256();count=0
        with lzma.open(src,'rb')as reader,tmp.open('xb')as writer:
            while chunk:=reader.read(1024*1024):writer.write(chunk);h.update(chunk);count+=len(chunk)
        if h.hexdigest()!=r['restored_sha256']or count!=r['restored_bytes']:
            raise RuntimeError('Report checksum mismatch: '+str(tmp))
        os.replace(tmp,dst);print('Restored:',r['restored_file'])
if __name__=='__main__':main()
