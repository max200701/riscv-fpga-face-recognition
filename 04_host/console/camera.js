/* Camera is a bounded latest-pixel producer. FPGA alone performs inference. */
'use strict';
(()=>{
 const video=document.getElementById('cameraPreview'),info=document.getElementById('cameraInfo'),canvas=document.createElement('canvas');canvas.width=640;canvas.height=480;
 const cx=canvas.getContext('2d',{alpha:false,willReadFrequently:true});
 let stream=null,active=false,finishing=false,count=0,started=0,ended=0,frameIndex=0,error='',runId=null,lastFps=0,stopReason='user_pause';
 const sleep=ms=>new Promise(r=>setTimeout(r,ms));
 let cancelFrameWait=null;
 function nextCameraFrame(){return new Promise((resolve,reject)=>{
  let handle=null,finished=false;
  const native=typeof video.requestVideoFrameCallback==='function';
  const done=e=>{if(finished)return;finished=true;clearTimeout(timer);
   if(handle!==null){if(native)video.cancelVideoFrameCallback(handle);else cancelAnimationFrame(handle);}
   cancelFrameWait=null;e?reject(e):resolve();};
  const timer=setTimeout(()=>done(Error('摄像头未产生新帧，已暂停')),3000);
  cancelFrameWait=()=>done();
  handle=native?video.requestVideoFrameCallback(()=>done()):requestAnimationFrame(()=>done());
  if(!active)done();
 });}
 const manual=['image','recognize','arm','start','release','enroll','delete','restore','upload','resume','disconnect','useNative','openSource','qualify_pixels','stop','recover','release_recovered'];
 function controls(s){
  const p=s?.pipeline;
  if(p){count=p.completed;lastFps=p.fps;}
  document.getElementById('cameraOpen').disabled=!!stream||finishing;
  document.getElementById('cameraRun').disabled=!stream||active||finishing||p?.finishing||!s?.connected||!s.model_resident||s.busy||(s.held&&!s.result);
  document.getElementById('cameraPause').disabled=!active;
  document.getElementById('cameraClose').disabled=!stream;
  if(active||finishing)for(const id of manual){const e=document.getElementById(id);if(e)e.disabled=true;}
  info.textContent=error||((active?'跨帧流水识别中':finishing?'正在完成最后一帧':stream?'摄像头已打开，可开始连续识别':'摄像头未打开')+' · '+window.FpgaFrameMetrics.describe(s)+'。上方为板端已提交结果对应的原图；下方为实时预览。');
 }
 async function post(path,p){const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({nonce,...p})});const v=await r.json();if(!r.ok)throw Error(v.error||'请求失败');return v;}
 function capture(){
  if(video.readyState<2||!video.videoWidth||stream?.getVideoTracks()[0]?.readyState!=='live')throw Error('摄像头尚无可用画面');
  const scale=Math.min(640/video.videoWidth,480/video.videoHeight),w=Math.max(1,Math.round(video.videoWidth*scale)),h=Math.max(1,Math.round(video.videoHeight*scale));
  cx.fillStyle='rgb(114,114,114)';cx.fillRect(0,0,640,480);cx.drawImage(video,Math.floor((640-w)/2),Math.floor((480-h)/2),w,h);
  const rgba=cx.getImageData(0,0,640,480).data,rgb=new Uint8Array(921600);for(let a=0,b=0;b<rgb.length;a+=4,b+=3){rgb[b]=rgba[a];rgb[b+1]=rgba[a+1];rgb[b+2]=rgba[a+2];}return rgb;
 }
 function watch(id){return new Promise((resolve,reject)=>{
  let seen=false;
  const done=(e)=>{clearInterval(timer);window.removeEventListener('fpga-state',listen);e?reject(e):resolve();};
  const listen=event=>{const s=event.detail;
   if(!s.connected||s.error)return done(Error(s.error||'开发板断开'));
   if(s.pipeline?.run_id!==id){if(seen)return done(Error('流水会话已改变'));return;}
   seen=true;controls(s);
   if(!s.pipeline.finishing){active=false;finishing=false;ended=performance.now();if(typeof cancelFrameWait==='function')cancelFrameWait();
    const reason=s.pipeline.stop_reason;
    done(reason&&!['user_pause','frame_limit'].includes(reason)?Error('板端流水已安全暂停：'+reason):null);
   }
  };
  const timer=setInterval(()=>{if(Date.now()-window.fpgaTransport.lastStateAt>5000)done(Error('状态连接连续失效超过5秒，安全暂停'));},250);
  window.addEventListener('fpga-state',listen);
 });}
 async function stop(){active=false;if(cancelFrameWait)cancelFrameWait();if(runId&&finishing)try{await post('/pipeline/stop',{run_id:runId,client_reason:stopReason});}catch(e){error=e.message;}controls(state);}
 async function run(){
  if(active||finishing)return;active=true;finishing=true;error='';stopReason='user_pause';count=0;frameIndex=0;started=performance.now();ended=0;runId=crypto.randomUUID();controls(state);
  let observer,frameFailures=0;
  try{
   await post('/pipeline/start',{run_id:runId});window.fpgaTransport.lastStateAt=Date.now();observer=watch(runId).catch(e=>{error=e.message;stopReason='state_or_board_failure';active=false;throw e;});observer.catch(()=>{});
   while(active){
    const data=capture();
    const ctl=new AbortController(),timeout=setTimeout(()=>ctl.abort(),3000);let r,receipt;
    try{
     r=await fetch('/pipeline/frame',{method:'POST',signal:ctl.signal,headers:{'Content-Type':'application/octet-stream','X-Console-Nonce':nonce,'X-Frame-Token':runId+':'+(frameIndex+1),'X-Pipeline-Run':runId,'X-Pipeline-Sequence':String(++frameIndex)},body:data});
     receipt=await r.json();
    }catch(e){
     const transient=['TypeError','AbortError'].includes(e.name);
     if(transient&&active&&++frameFailures<=2&&Date.now()-window.fpgaTransport.lastStateAt<1500&&state?.connected&&!state.error&&state.pipeline?.run_id===runId&&state.pipeline.enabled){
      window.fpgaTransport.skippedFrames=(window.fpgaTransport.skippedFrames||0)+1;
      await sleep(100);continue; // Fresh capture and NEW sequence, never replay START or this frame.
     }
     throw Error('图像连接失败，已安全暂停：'+e.message);
    }finally{clearTimeout(timeout);}
    if(r.status===502&&active&&++frameFailures<=2&&Date.now()-window.fpgaTransport.lastStateAt<1500&&state?.connected&&!state.error&&state.pipeline?.run_id===runId&&state.pipeline.enabled){
     window.fpgaTransport.skippedFrames=(window.fpgaTransport.skippedFrames||0)+1;await sleep(100);continue;
    }
    if(!r.ok){if(!active)break;throw Error(receipt.error||'像素传输失败');}
    if(!receipt.accepted||receipt.token!==runId+':'+frameIndex)throw Error('像素接收回执不匹配');
    frameFailures=0;
    // Wake on actual next camera frame. Still one upload plus one latest slot.
    // No artificial 80ms pacing and no retry of an already submitted START.
    await nextCameraFrame();
   }
   await stop();await observer;
  }catch(e){error=e.message;if(stopReason==='user_pause')stopReason='frame_or_control_failure';await stop();if(observer)try{await observer;}catch(_){} }
  finally{ended=performance.now();active=false;finishing=false;await poll();controls(state);}
 }
 document.getElementById('cameraOpen').onclick=async()=>{
  error='';try{if(!navigator.mediaDevices?.getUserMedia)throw Error('当前浏览器未提供摄像头接口');
   stream=await navigator.mediaDevices.getUserMedia({audio:false,video:{width:{ideal:640},height:{ideal:480},frameRate:{ideal:30}}});video.srcObject=stream;await video.play();
   stream.getVideoTracks()[0].addEventListener('ended',()=>{error='摄像头已停止，等待板端当前帧完成。';stop();});
  }catch(e){if(stream)for(const t of stream.getTracks())t.stop();stream=null;error='摄像头未打开：'+e.message;}controls(state);
 };
 document.getElementById('cameraRun').onclick=run;
 document.getElementById('cameraPause').onclick=stop;
 document.getElementById('cameraClose').onclick=()=>{stop();if(stream)for(const t of stream.getTracks())t.stop();stream=null;video.srcObject=null;controls(state);};
 window.cameraController={render:controls};window.cameraDiagnostics=()=>({active,finishing,count,started,ended,frameIndex,error,open:!!stream,runId,model_inference_on_PC:false});controls(state);
})();
