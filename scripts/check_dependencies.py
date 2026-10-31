"""Report missing/mismatched external inputs. No downloads, devices or tools."""
from pathlib import Path
import argparse,hashlib,json
ROOT=Path(__file__).resolve().parents[1]
def check(prefix=None):
 rows=json.loads((ROOT/'docs/external_files.json').read_text(encoding='utf-8'))
 out=[]
 for row in rows:
  if prefix and not any(row['path'].startswith(p)for p in prefix):continue
  p=ROOT/row['path'];status='MISSING'
  if p.is_file():status='OK' if hashlib.sha256(p.read_bytes()).hexdigest()==row['sha256'] else 'HASH_MISMATCH'
  out.append(dict(path=row['path'],status=status))
 return out
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--prefix',action='append');a=p.parse_args()
 result=check(a.prefix);print(json.dumps(result,indent=2))
 raise SystemExit(int(any(x['status']!='OK'for x in result)))
