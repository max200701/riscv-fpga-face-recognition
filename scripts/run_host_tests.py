"""Run the packaged fake-board tests; no serial/JTAG access."""
from pathlib import Path
import sys,unittest
ROOT=Path(__file__).resolve().parents[1];H=ROOT/'host/console'
sys.path.insert(0,str(H))
if not(ROOT/'host/source/assets_reference01/MANIFEST.json').exists():raise SystemExit('Run scripts/prepare_test_assets.py first')
suite=unittest.defaultTestLoader.discover(str(H),pattern='test_*.py')
result=unittest.TextTestRunner(verbosity=1).run(suite)
raise SystemExit(0 if result.wasSuccessful()else 1)
