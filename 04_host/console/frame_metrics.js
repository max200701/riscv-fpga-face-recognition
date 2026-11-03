/* Completion throughput uses every interval in the same bounded warm window.
   Preview, uploaded, replaced and uncommitted frames never enter this count. */
(function(root){
 'use strict';
 function view(s){
  const p=s?.pipeline||{},n=p.window_intervals||0;
  const valid=n>0&&Number.isFinite(p.recent_fps)&&p.recent_fps>0&&Number.isFinite(p.mean_interval_ms);
  const running=!!s?.connected&&!s?.error&&!!p.finishing;
  const stale=running&&valid&&p.result_age_seconds>Math.max(2,3*p.mean_interval_ms/1000);
  const stage=!s?.connected?'未连接':s?.error?'已停止':!p.finishing?'已暂停':stale?'等待新结果':'热运行';
  const parts=[(running?'本轮':'上次运行')+'已完成 '+(p.completed||0)+' 帧'];
  if(valid){
   parts.push('最近 '+n+' 个完成间隔：平均 '+p.mean_interval_ms.toFixed(1)+' ms / '+p.recent_fps.toFixed(2)+' 帧/秒');
   parts.push('最后间隔 '+p.interval_ms.toFixed(1)+' ms（单间隔折算 '+p.latest_interval_fps.toFixed(2)+' 帧/秒）');
   parts.push('其中有脸 '+p.window_face_frames+' 帧、无脸 '+p.window_no_face_frames+' 帧');
   if(!running)parts.push('以上为历史统计，当前'+stage);
   else if(stale)parts.push('已 '+p.result_age_seconds.toFixed(1)+' 秒无新结果，当前速率待更新');
  }else parts.push('热运行统计等待至少两次完成');
  return {value:running&&!stale&&valid?p.recent_fps.toFixed(2):'—',
   label:running&&!stale?'有效结果 / 秒（热运行）':stage+' · 当前帧率 —',
   detail:parts.join(' · ')};
 }
 const api={view,describe:s=>view(s).detail};
 if(typeof module!=='undefined'&&module.exports)module.exports=api;
 else root.FpgaFrameMetrics=api;
})(typeof window==='undefined'?globalThis:window);
