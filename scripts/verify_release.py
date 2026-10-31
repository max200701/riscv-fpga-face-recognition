"""Check the published source snapshot, not external binaries or board state."""
from pathlib import Path
import ast,hashlib,json,re,sys
ROOT=Path(__file__).resolve().parents[1]
def main():
 manifest=json.loads((ROOT/'MANIFEST.json').read_text(encoding='utf-8'))
 errors=[];total=0
 blocked_suffix={'.bin','.sbit','.bit','.elf','.exe','.lic','.adf','.vp','.onnx','.pth','.snpkg','.jpg','.jpeg','.png','.mp4','.jsonl'}
 for name,h in manifest['files'].items():
  p=(ROOT/name).resolve()
  if not p.is_relative_to(ROOT):errors.append(name+': path traversal');continue
  if not p.is_file():errors.append(name+': missing');continue
  b=p.read_bytes();total+=len(b)
  if hashlib.sha256(b).hexdigest()!=h:errors.append(name+': hash mismatch')
  if p.suffix.lower()in blocked_suffix:errors.append(name+': prohibited artifact type')
  if any(x in p.relative_to(ROOT).parts for x in ('external','data','handoff01','.venv','build')):errors.append(name+': private/generated subtree')
  try:t=b.decode('utf-8-sig')
  except UnicodeDecodeError:errors.append(name+': unexpected binary');continue
  if re.search(r'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',t):errors.append(name+': credential pattern')
  if re.search(r'[A-Z]:[/\\]Users[/\\]',t,re.I):errors.append(name+': personal absolute path')
  if p.suffix=='.py':
   try:ast.parse(t,filename=name)
   except SyntaxError as e:errors.append(name+': '+str(e))
 inputs=json.loads((ROOT/'hardware/design_files.json').read_text())
 external={x['path']for x in json.loads((ROOT/'docs/external_files.json').read_text())}
 for n in inputs:
  if (n in manifest['files'])==(n in external):errors.append(n+': must be exactly one of published/external')
 top=sum(len(re.findall(r'\bmodule\s+mini_face_demo_top\b',(ROOT/n).read_text()))for n in inputs if n in manifest['files'])
 if top!=1:errors.append('unique top count != 1')
 print(json.dumps(dict(status='FAIL'if errors else'SOURCE_RELEASE_CHECK_PASS',files=len(manifest['files']),bytes=total,design_inputs=len(inputs),external_inputs=len(external),unique_board_top=top,errors=errors,full_build_or_board_acceptance=False),indent=2))
 return bool(errors)
if __name__=='__main__':raise SystemExit(main())
