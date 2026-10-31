"""Import exact dependencies from an explicitly supplied local package tree.

No network, board access, overwrite, or filename-based substitution.
The source tree must already use paths from docs/external_files.json.
"""
from pathlib import Path
import argparse
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--from-dir', type=Path, required=True)
    parser.add_argument('--apply', action='store_true', help='copy validated missing files; default is read-only')
    args = parser.parse_args()
    source = args.from_dir.resolve(strict=True)
    rows = json.loads((ROOT / 'docs/external_files.json').read_text(encoding='utf-8'))
    plan, problems = [], []
    for row in rows:
        name = row['path']
        src, dst = (source / name).resolve(), (ROOT / name).resolve()
        if not src.is_relative_to(source) or not dst.is_relative_to(ROOT):
            problems.append({'path': name, 'status': 'UNSAFE_PATH'})
            continue
        existing = dst if dst.exists() else src
        if not existing.is_file():
            problems.append({'path': name, 'status': 'MISSING'})
        elif hashlib.sha256(existing.read_bytes()).hexdigest() != row['sha256']:
            problems.append({'path': name, 'status': 'HASH_MISMATCH'})
        elif not dst.exists():
            plan.append((src, dst, row))
    # Validate the complete set before copying anything.
    if problems:
        print(json.dumps({'status': 'BLOCKED_NO_COPY', 'problems': problems}, indent=2))
        return 1
    if args.apply:
        for src, dst, row in plan:
            dst.parent.mkdir(parents=True, exist_ok=True)
            with src.open('rb') as inp, dst.open('xb') as out:
                shutil.copyfileobj(inp, out)
            if hashlib.sha256(dst.read_bytes()).hexdigest() != row['sha256']:
                raise RuntimeError('Copied dependency changed: ' + row['path'])
    print(json.dumps({'status': 'IMPORTED' if args.apply else 'PLAN_PASS',
                      'files': [row['path'] for _, _, row in plan]}, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
