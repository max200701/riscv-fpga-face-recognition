"""Host-only regression. Never opens a COM port or JTAG cable."""
from pathlib import Path
import os,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
tmp=ROOT/'build/host_tests_tmp';tmp.mkdir(parents=True,exist_ok=True)
os.environ['TEMP']=os.environ['TMP']=str(tmp);tempfile.tempdir=str(tmp)
sys.path[:0]=[str(ROOT/'04_host/console'),str(ROOT/'05_tests/host')]
suite=unittest.defaultTestLoader.discover(str(ROOT/'05_tests/host'),pattern='test_*.py')
result=unittest.TextTestRunner(verbosity=1).run(suite)
raise SystemExit(not result.wasSuccessful())
