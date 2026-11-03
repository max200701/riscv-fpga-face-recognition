'use strict';
const nonce='__NONCE__',$=id=>document.getElementById(id),ctx=$('view').getContext('2d');let state=null,version=null,picture=null,pictureSha=null,pending=false,localError='',readingFile=false;
async function action(name,p={}){
 if(pending)return;pending=true;localError='';if(state)render(state);
 try{const r=await fetch('/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({nonce,action:name,...p})});const v=await r.json();if(!r.ok)throw Error(v.error);}
 catch(e){localError=e.message;}finally{pending=false;await poll();}
}
function draw(){ctx.clearRect(0,0,640,480);if(picture)ctx.drawImage(picture,0,0,640,480);const r=state?.pipeline?.last_result||state?.result;if(r?.has_face&&r.source_rgb_sha256===pictureSha){const [x,y,x2,y2]=r.box_xyxy;ctx.strokeStyle=r.accepted?'#19ca94':'#ffc85b';ctx.lineWidth=3;ctx.strokeRect(x,y,x2-x,y2-y);}}
function options(id,items,empty){const e=$(id),before=e.value,encoded=JSON.stringify(items);if(e.dataset.items===encoded)return;e.dataset.items=encoded;e.replaceChildren(...(items.length?items:[['',empty]]).map(([key,label])=>{const o=document.createElement('option');o.value=key;o.textContent=label;return o;}));if(items.some(x=>String(x[0])===before))e.value=before;}
function render(s){state=s;const r=s.pipeline?.last_result||s.result,h=s.health,v=s.video;
 $('mode').textContent=s.mode;$('next').textContent=s.next_step;$('error').textContent=localError||s.error||'';
 $('result').textContent=r?(r.has_face?(r.accepted?'已识别：'+r.person_name:'检测到人脸 · 未登记或未通过匹配'):'本帧未检测到人脸'):'等待 FPGA 结果';
 $('detail').textContent=r?'板端 CPU 已提交 · 帧 '+r.video_source.frame+' · 代际 '+r.generation+' · 图库版本 '+r.gallery_revision:'没有运行电脑端人脸识别。此处只显示板端提交的结果。';
 $('temperature').textContent=h?.temperature_C==null?'—':h.temperature_C.toFixed(1)+' °C';$('phase').textContent=s.busy?'正在处理':s.held?(s.result?'结果已提交':v?.application_selected?'计算中':'采集中'):s.connected?'等待输入':'未连接';
 $('cosine').textContent=r?.has_match?r.cosine.toFixed(4):'—';$('latency').textContent=r?.host_observed_seconds==null?'—':r.host_observed_seconds.toFixed(3)+' s';
 $('resident').textContent=(s.model_resident?'模型已驻留，无需重复装载':'模型尚未装载')+' · 图库 '+s.gallery.length+' 人'+(s.busy?' · '+s.progress+'%':'');$('progress').value=s.progress;
 $('source').textContent='图片 CRC32 '+s.source_crc+' · '+(s.display_ready?'图像窗口已就绪':'HDMI 图像窗口未就绪');
 $('useNative').disabled=!!s.actions.select_display||pending;$('openSource').disabled=!!s.actions.select_display||pending;
 $('displayInfo').textContent=(s.display_selection?.provider==='WIN32_TK_EXACT_FRAME'?'当前选中：自动扩展屏输出。\n':'当前选中：浏览器图像窗口。\n')+(s.display_ready?'选中的窗口已绘制当前图片，640×480 全屏。':s.display.reasons.join('\n'));
 $('releaseHint').textContent=s.hardware_connection_enabled?'QO DEBUG136：双角8项时序检查通过；30次固定图板测通过。检测、识别与人员匹配均在 FPGA 上完成。':'当前是离线测试入口。';
 for(const [id,reason]of Object.entries(s.actions)){if(!$(id))continue;$(id).disabled=!!reason||pending||readingFile;$(id).title=reason;const hint=$(id+'Hint');if(hint)hint.textContent=reason;}
 $('enroll').disabled=$('enroll').disabled||!$('person').value.trim();if(!s.actions.enroll&&!$('person').value.trim())$('enrollHint').textContent='填写人员姓名即可登记。';
 $('gallery').replaceChildren(...(s.gallery.length?s.gallery:[{identity:'',name:'尚未登记人员'}]).map(p=>{const li=document.createElement('li');li.textContent=(p.identity?p.identity+' · ':'')+p.name;return li;}));
 options('deleteId',s.gallery.map(p=>[String(p.identity),p.identity+' · '+p.name]),'图库为空');options('backups',s.backups.map(k=>[k,k]),'暂无备份');
 $('events').textContent=s.events.map(e=>e.time+' '+e.message).join('\n')||'等待操作';
 const pr=s.pipeline?.last_result,displayVersion=pr?'result:'+pr.source_rgb_sha256:'source:'+s.source_id;
 if(version!==displayVersion){version=displayVersion;const id=version;
  if(pr){const hash=pr.source_rgb_sha256;fetch('/result-frame.rgb?sha='+hash).then(r=>{if(!r.ok)throw Error('Result image expired');return r.arrayBuffer();}).then(b=>{if(version!==id)return;const rgb=new Uint8Array(b);if(rgb.length!==921600)throw Error('RGB extent');const cv=document.createElement('canvas');cv.width=640;cv.height=480;const cc=cv.getContext('2d'),im=cc.createImageData(640,480);for(let a=0,z=0;a<rgb.length;a+=3,z+=4){im.data[z]=rgb[a];im.data[z+1]=rgb[a+1];im.data[z+2]=rgb[a+2];im.data[z+3]=255;}cc.putImageData(im,0,0);picture=cv;pictureSha=hash;draw();}).catch(()=>{if(version===id)version=null;});}
  else{const im=new Image();im.onload=()=>{if(version===id){picture=im;pictureSha=s.source_sha;draw();}};im.src='/frame.png?v='+s.source_id;}
 }else draw();
 window.cameraController?.render(s);
 window.dispatchEvent(new CustomEvent('fpga-state',{detail:s}));
}
for(const name of ['resume','upload','recognize','arm','start','release','disconnect','qualify_pixels','stop','recover','release_recovered'])$(name).onclick=()=>action(name);
$('connect').onclick=()=>action('connect',{port:$('port').value.trim()});$('enroll').onclick=()=>action('enroll',{identity:$('identity').value,name:$('person').value});$('person').oninput=()=>{if(state)render(state);};
$('delete').onclick=()=>action('delete',{identity:$('deleteId').value});$('restore').onclick=()=>action('restore',{backup:$('backups').value});
$('useNative').onclick=()=>action('select_display',{provider:'WIN32_TK_EXACT_FRAME',source_instance:'default'});
$('openSource').onclick=()=>{const w=window.open('/source','fpga_hdmi_source','popup,width=820,height=650');if(!w){localError='浏览器阻止了图像窗口。请允许弹窗，或打开 '+location.origin+'/source';$('error').textContent=localError;}};
$('image').onchange=async()=>{const f=$('image').files[0];if(!f)return;if(f.size>16*1024*1024){localError='图片须小于 16 MiB';render(state);return;}readingFile=true;if(state)render(state);const reader=new FileReader();reader.onerror=()=>{readingFile=false;localError='无法读取所选文件';if(state)render(state);};reader.onload=async()=>{readingFile=false;await action('image',{data:reader.result.split(',')[1]});$('image').value='';};reader.readAsDataURL(f);};
let polling=false;
async function poll(){if(polling)return;polling=true;try{const r=await fetch('/state');if(!r.ok)throw Error('HTTP '+r.status);render(await r.json());}catch(e){$('next').textContent='本地服务未连接。请运行 Start-Console.ps1，再刷新页面。';$('error').textContent=e.message;for(const id of Object.keys(state?.actions||{}))if($(id))$(id).disabled=true;}finally{polling=false;}}
window.demoDiagnostics=()=>({connected:state?.connected,source:state?.source_sha,mode:state?.mode,result:state?.pipeline?.last_result||state?.result||null,actions:state?.actions,model_inference_on_PC:false});
window.fpgaTransport={version:16,readFailures:0,recovered:0,lastStateAt:Date.now(),streak:0};
(async()=>{let revision;for(;;){const started=performance.now(),controller=new AbortController(),timer=setTimeout(()=>controller.abort(),3500);
 try{const r=await fetch('/state'+(revision==null?'':'?after='+revision),{signal:controller.signal});if(!r.ok)throw Error('HTTP '+r.status);const s=await r.json();revision=s.revision;
  const t=window.fpgaTransport;if(t.streak)t.recovered++;t.streak=0;t.lastStateAt=Date.now();render(s);
 }catch(e){const t=window.fpgaTransport;t.readFailures++;t.streak++;revision=undefined;
  $('error').textContent='状态查询暂时中断，正在恢复（'+t.streak+'次）：'+e.message;
  await new Promise(r=>setTimeout(r,Math.min(1000,100*2**Math.min(t.streak-1,3))));
 }finally{clearTimeout(timer);}
 // Backend long-poll wakes for meaningful observations/results, not every DDR
 // counter increment. Re-arm immediately; no extra healthy-path 50ms delay.
}})();

$('coremark').onclick=()=>action('coremark',{iterations:2500});
window.addEventListener('fpga-state',e=>{const b=e.detail.coremark;if(!b)return;$('coremarkResult').textContent=b.status==='PASS'?`CPU ${b.cpu_Hz/1e6} MHz\n${b.coremark_per_second.toFixed(3)} CoreMark\n${b.coremark_per_MHz.toFixed(6)} CoreMark/MHz\n${b.iterations} iterations / ${b.timed_seconds.toFixed(6)} s\nCRC PASS · 已回人脸模式`:JSON.stringify(b,null,2);});
