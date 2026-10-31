"""Generate independent synthesis/Map Tcl; never run PDS implicitly."""
from pathlib import Path
import argparse,json,shutil
from check_dependencies import check,ROOT
def main():
 p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);a=p.parse_args()
 bad=[x for x in check(['hardware/'])if x['status']!='OK']
 if bad:raise SystemExit(json.dumps(bad,indent=2))
 out=a.out.resolve()
 if out.exists():raise SystemExit('Output already exists')
 out.mkdir(parents=True)
 shutil.copytree(ROOT/'hardware',out/'work');w=out/'work'
 entries=json.loads((ROOT/'hardware/design_files.json').read_text())
 prefix='set_arch -family Logos2 -device PG2L200H -speedgrade -6 -package FBB676\n'
 for n in entries:prefix+='add_design {'+(w/Path(n).relative_to('hardware')).as_posix()+'}\n'
 for n in ('board.fdc','mini_ddr.rcf'):prefix+='add_constraint {'+(w/n).as_posix()+'}\n'
 (out/'synth.tcl').write_text(prefix+'compile -system_verilog -top_module mini_face_demo_top\nsynthesize -ads\nputs {PUBLIC_SYNTH_DONE}\nexit\n')
 (out/'map.tcl').write_text(prefix+'dev_map -force_to_run -override_pcf TRUE -input_db_file {'+(w/'synthesize/mini_face_demo_top_syn.adf').as_posix()+'}\nputs {PUBLIC_MAP_DONE}\nexit\n')
 print('Prepared; run each with pds_shell -file SCRIPT -work_dir',w,'-project_name mini_face_demo')
if __name__=='__main__':main()
