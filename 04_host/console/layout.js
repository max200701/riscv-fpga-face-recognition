(()=>{
const $=id=>document.getElementById(id),main=document.querySelector('main');
const original=[...document.querySelectorAll('main section')];
const el=(tag,cls,html='')=>{const x=document.createElement(tag);x.className=cls;x.innerHTML=html;return x;};
const move=(parent,...ids)=>ids.forEach(id=>parent.append($(id)));
const row=(parent,...ids)=>{const x=el('div','row');move(x,...ids);parent.append(x);return x;};
const fold=(title)=>{const x=el('details','utility',`<summary>${title}</summary>`);return x;};
const hero=el('div','hero'),visual=el('section','visual','<h2>识别画面 <small>FPGA 已提交结果</small></h2>');
const stage=el('div','stage');move(stage,'view');
const preview=el('div','preview','<span>摄像头实时预览</span>');move(preview,'cameraPreview');stage.append(preview);visual.append(stage);
row(visual,'cameraOpen','cameraRun','cameraPause','cameraClose');
const fileRow=row(visual,'image','recognize','release');fileRow.classList.add('photo-row');
move(visual,'cameraInfo','recognizeHint','error');
const side=el('div','side'),result=el('section','result-card','<h2>识别结果</h2>');move(result,'result');
const metrics=el('div','metrics');['cosine','latency','temperature','phase'].forEach(id=>metrics.append($(id).parentElement));result.append(metrics);
const fps=el('div','fps','<strong id="uiFps">—</strong><span id="uiFpsLabel">有效结果 / 秒（热运行）</span><small>余弦相似度不是准确率</small>');result.append(fps);move(result,'detail');
const enroll=el('section','enroll-card','<h2>登记人员 <small>暂停连续识别后登记当前人脸</small></h2>');row(enroll,'identity','person','enroll');move(enroll,'enrollHint');
const people=fold('已登记人员与图库管理');move(people,'gallery');row(people,'deleteId','delete');row(people,'backups','restore');move(people,'deleteHint','restoreHint');enroll.append(people);
side.append(result,enroll);hero.append(visual,side);
const setup=fold('设备连接与模型装载');row(setup,'port','connect','disconnect');move(setup,'connectHint');row(setup,'resume','upload');move(setup,'progress','uploadHint','resident','releaseHint');
const hdmi=fold('HDMI 输入准备与采集诊断');row(hdmi,'useNative','openSource');move(hdmi,'displayInfo','source');row(hdmi,'arm','start','qualify_pixels','stop','recover','release_recovered');
hdmi.append(el('p','muted','电脑 HDMI 输出连接板上 HDMI IN；Windows 选择扩展屏，使用 640×480 图像输出。')); 
const logs=fold('操作记录');move(logs,'events');
const bench=original.find(s=>s.querySelector('#coremark'));bench.className='benchmark';
const benchLink=el('a','bench-link','CPU CoreMark 独立测试页 ↗');benchLink.href='/coremark';
const utilities=el('div','utilities');utilities.append(setup,hdmi,logs,benchLink);
const hidden=el('div','legacy');hidden.hidden=true;original.forEach(s=>hidden.append(s));
main.replaceChildren(hero,utilities,hidden);
document.querySelector('header p').textContent='电脑输入与显示 · 检测、对齐、特征提取与匹配由 FPGA 执行';
document.querySelector('header').append(benchLink.cloneNode(true));
if(location.pathname==='/coremark'){
 document.body.classList.add('coremark-page');document.title='CPU CoreMark · FPGA 实板测试';
 const panel=el('div','benchmark-page','<a href="/">← 返回人脸识别</a><h1>CPU CoreMark 实板测试</h1><p class="muted">使用同一板端 CPU。请先暂停连续识别，再运行测试；完成后返回人脸模式。</p>');
 panel.append(bench);main.prepend(panel);bench.querySelector('h2').textContent='运行与结果';
}
document.querySelectorAll('a[href="/coremark"],a[href="/"]').forEach(a=>a.addEventListener('click',e=>{if(window.cameraDiagnostics?.().active||window.cameraDiagnostics?.().finishing){e.preventDefault();$('error').textContent='请先暂停连续识别，待本帧完成后再切换页面。';}}));
$('latency').parentElement.title='从START到主机收到结果，包含结果下载，不含采集和换帧；不是整轮耗时。';
window.addEventListener('fpga-state',e=>{const s=e.detail,m=window.FpgaFrameMetrics.view(s);$('uiFps').textContent=m.value;$('uiFps').title=m.detail;$('uiFpsLabel').textContent=m.label;if(!s.connected||!s.model_resident)setup.open=true;});
const cameraInfo=$('cameraInfo');new MutationObserver(()=>{const old=cameraInfo.textContent,next=old.replace('上方为板端已提交结果对应的原图；下方为实时预览。','主画面为板端结果对应的图像；右下角为实时预览。');if(old!==next)cameraInfo.textContent=next;preview.hidden=!$('cameraPreview').srcObject;}).observe(cameraInfo,{childList:true,characterData:true,subtree:true});preview.hidden=true;
// Retain every existing ID/handler: only move presentation nodes.
})();
