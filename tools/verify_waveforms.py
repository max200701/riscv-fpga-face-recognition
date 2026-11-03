"""Compare exported board samples and their decoded views."""
from pathlib import Path
import csv,hashlib,json,re

ROOT=Path(__file__).resolve().parents[1]
W=ROOT/'10_board_waveforms'

def sha(p):
    with p.open('rb')as f:return hashlib.file_digest(f,'sha256').hexdigest()

def vcd(path):
    raw=path.read_text(encoding='ascii')
    defs=re.findall(r'\$var wire (\d+) (\S+) (\S+) \$end',raw)
    state={};times=[];rows=[];active=False
    for line in raw.split('$enddefinitions $end',1)[1].splitlines():
        line=line.strip()
        if line.startswith('#'):
            if active:rows.append([state[c]for _,c,_ in defs])
            times.append(int(line[1:]));active=True
        elif line.startswith('b'):
            bits,code=line[1:].split();state[code]=int(bits,2)
        elif line and line[0]in '01'and line[1:].startswith('n'):
            state[line[1:]]=int(line[0])
    if active:rows.append([state[c]for _,c,_ in defs])
    return defs,times,rows

def main():
    index=json.loads((W/'INDEX.json').read_text(encoding='utf8'))
    for f in index['copied_files']:assert sha(W/f['file'])==f['sha256'],f['file']
    for f in index['bound_files'].values():assert sha(ROOT/f['file'])==f['sha256'],f['file']
    total=0
    for window in index['windows']:
        p=W/window['path'];spec=json.loads((W/'probes'/(window['kind']+'.json')).read_text())
        groups=spec['groups']
        rows=[[int(x,16)for x in line.split()]for line in (p/'wave.txt').read_text().splitlines()if line.strip()]
        defs,times,vrows=vcd(p/'wave.vcd')
        assert len(rows)==2048 and rows==vrows,window['path']
        assert times==list(range(2048))
        assert len(groups)==len(defs)
        assert sum(g['width']for g in groups)==(138 if window['kind']=='CM'else 136)
        for (width,code,label),g in zip(defs,groups):
            assert int(width)==g['width']
            assert label==(g['label']if g['width']>1 else g['nets'][0].replace(' ',''))
        defs2,physical_times,physical_rows=vcd(p/'physical_time.vcd')
        assert defs2==defs and physical_rows==rows
        assert physical_times==[round(i*1e6/window['clock_MHz'])for i in range(2048)]
        with (p/'samples.csv').open(newline='',encoding='utf8')as f:decoded=list(csv.DictReader(f))
        assert len(decoded)==2048
        data=[dict(zip([g['label']for g in groups],r))for r in rows]
        for i,(r,view) in enumerate(zip(data,decoded)):
            assert int(view['sample'])==i
            assert all(int(view[k])==v for k,v in r.items())
            for g in groups:
                if g.get('display_left_shift'):
                    assert int(view[g['label'].replace('_word','')])==r[g['label']]<<g['display_left_shift']
        for i,(a,b) in enumerate(zip(data,data[1:])):
            assert (b['cycle12']-a['cycle12'])%4096==1
            retired=(b['instret16']-a['instret16'])%65536
            expected=a['wb0_valid']+a['wb1_valid']if window['kind']=='CM'else a['wb_success']*(1+a['wb1_valid'])
            assert retired==expected==int(decoded[i]['retired_to_next'])
        total+=len(rows)
    print(json.dumps(dict(status='PASS',windows=len(index['windows']),samples=total,figures=len(index['figures']),
                          TXT_VCD_CSV_values_equal=True,physical_time_values_equal=True,continuous_sampling=True)))

if __name__=='__main__':main()
