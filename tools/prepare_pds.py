"""Generate separate PDS 2025.2 projects without starting an implementation job."""
from pathlib import Path
import argparse,json,re,shutil,time
ROOT=Path(__file__).resolve().parents[1]
def main():
 ap=argparse.ArgumentParser();ap.add_argument('target',choices=['QO','CM']);ap.add_argument('--output',type=Path);a=ap.parse_args()
 src=ROOT/('01_hardware/QO' if a.target=='QO' else '06_cpu_coremark/CM');out=(a.output or ROOT/'build'/(a.target+'_'+str(time.time_ns()))).resolve();out.mkdir(parents=True,exist_ok=False)
 s=out/'source';shutil.copytree(src,s);top='mini_face_demo_top' if a.target=='QO' else 'cpu_perf_board'
 for p in s.rglob('*'):
  if p.suffix in ('.v','.sv','.vh'):
   text=p.read_text();text=re.sub(r'"(application_rom\.hex|sigmoid(?:_even|_odd)?\.hex)"',lambda m:'"'+(s/m[1]).as_posix()+'"',text);p.write_text(text,encoding='utf8')
 if a.target=='QO':shutil.copy2(s/'oj_ms7200_table.vh',s/'hdmi_rx/oj_ms7200_table.vh')
 design=json.loads((s/'sources.json').read_text());assert all((s/n).is_file()for n in design)
 arch='set_arch -family Logos2 -device PG2L200H -speedgrade -6 -package FBB676\n'
 prefix=arch+''.join('add_design {'+(s/n).as_posix()+'}\n' for n in design)
 for n in ('board.fdc','mini_ddr.rcf' if a.target=='QO' else 'board.pcf'):prefix+='add_constraint {'+(s/n).as_posix()+'}\n'
 syn=out/'01_synthesis';syn.mkdir();db=syn/('prj_tasks/syn_1/synthesize/'+top+'_syn.adf')
 (out/'01_synthesis.tcl').write_text(prefix+'compile -verilog_standard SystemVerilog -top_module '+top+'\nsynthesize -ads\nsave_project\nputs {SUBMISSION_SYNTH_DONE}\nexit\n',encoding='utf8')
 fic=(s/'debug/cpu_debug.fic').read_text();fic=re.sub(r'(?m)^Project.device.designInputFile=.*$', 'Project.device.designInputFile='+db.as_posix(),fic);(s/'debug/cpu_debug.fic').write_text(fic)
 mp=out/'02_mapping';mp.mkdir();mapped=mp/('prj_tasks/pnr_1/device_map/'+top+'_map.adf')
 (out/'02_mapping.tcl').write_text(prefix+'add_fic {'+(s/'debug/cpu_debug.fic').as_posix()+'}\nsave_project\ndev_map -force_to_run -top_module '+top+' -input_db_file {'+db.as_posix()+'}\nsave_project\nputs {SUBMISSION_MAP_DONE}\nexit\n')
 pl=out/'03_placement';pl.mkdir();placed=pl/('prj_tasks/pnr_1/place_route/'+top+'_plc.adf')
 pc='add_constraint {'+(s/'board_only.pcf').as_posix()+'}\n' if a.target=='QO' else ''
 (out/'03_placement.tcl').write_text(prefix+pc+'set_option max_threads 8 [current_project]\nsave_project\nplace -force_to_run -input_db_file {'+mapped.as_posix()+'} -mode normal -plc_decongestion 1 -dc_duplication Global -gplace_seed 1 -optimize_gp_recovery TRUE\nputs {SUBMISSION_PLACE_DONE}\nexit\n')
 # Endpoints depend on actual packing. CDC/placement reference files are supplied
 # for review; they are deliberately not applied blindly to a new netlist.
 for name,delay in [('timing_max','max'),('timing_min','min')]:
  (out/(name+'.tcl')).write_text(arch+'report_timing -force_to_run -input_db_file {'+(ROOT/'08_bitstreams'/a.target/'routed.adf').as_posix()+'} -delay_type '+delay+' -max_path 30000 -nworst 1 -report_exception TRUE -report_max_skew -report_io_datasheet\nexit\n')
 (out/'export_existing.tcl').write_text(arch+'gen_bit_stream -force_to_run -input_db_file {'+(ROOT/'08_bitstreams'/a.target/'routed.adf').as_posix()+'} -create_bit_file TRUE -disable_cyclic_redundancy_checking FALSE -write_drm_data TRUE -scbv {High Voltage} -unused_io_status {UNUSED}\nexit\n')
 (out/'run_stage.ps1').write_text('param([Parameter(Mandatory=$true)][string]$PdsBin,[ValidateSet("01_synthesis","02_mapping","03_placement","timing_max","timing_min","export_existing")][string]$Stage="01_synthesis")\n$ErrorActionPreference="Stop"\n$w=Join-Path $PSScriptRoot $Stage\nNew-Item -ItemType Directory -Path $w -Force | Out-Null\n$t=Join-Path $w "tmp"\nNew-Item -ItemType Directory -Path $t -Force | Out-Null\n$env:TEMP=$t; $env:TMP=$t\nPush-Location (Join-Path $PSScriptRoot "source")\ntry { & (Join-Path $PdsBin "pds_shell.exe") -file (Join-Path $PSScriptRoot ($Stage+".tcl")) -work_dir $w -project_name ("submission_"+$Stage); if($LASTEXITCODE -ne 0){throw "PDS process failed"} } finally {Pop-Location}\n',encoding='utf8')
 (out/'README.txt').write_text('Generated only, no PDS has been run. Run stages 01/02/03 separately. Inspect success markers, resources and actual mapped CDC endpoints before routing. Final timing and bitstream are reproducible from the included routed.adf with matching PDS 2025.2 build 211867. Source rebuilds do not promise identical placement/timing.\n',encoding='utf8')
 print(out)
if __name__=='__main__':main()
