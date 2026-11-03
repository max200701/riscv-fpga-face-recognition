"""Verify the submitted immutable files, without devices or build tools."""
from pathlib import Path
import hashlib,json,sys
ROOT=Path(__file__).resolve().parents[1]
def main():
 manifest=json.loads((ROOT/'SHA256SUMS.json').read_text(encoding='utf8'));bad=[]
 for name,expected in manifest.items():
  p=(ROOT/name).resolve()
  if not p.is_relative_to(ROOT):raise ValueError('Manifest path escapes package')
  if not p.is_file()or hashlib.sha256(p.read_bytes()).hexdigest()!=expected:bad.append(name)
 if bad:print(json.dumps(dict(status='FAIL',files=bad),ensure_ascii=False));raise SystemExit(1)
 for folder,top in [('01_hardware/QO','mini_face_demo_top'),('06_cpu_coremark/CM','cpu_perf_board')]:
  base=ROOT/folder;files=json.loads((base/'sources.json').read_text())
  assert len(files)==len(set(files))and all((base/f).is_file()for f in files)
 print(json.dumps(dict(status='PASS',verified_files=len(manifest),hardware_file_lists='PASS',device_access=False)))
if __name__=='__main__':main()
