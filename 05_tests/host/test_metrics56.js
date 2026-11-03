'use strict';
const assert=require('node:assert/strict'),m=require('../../04_host/console/frame_metrics.js');
const state={connected:true,error:null,pipeline:{finishing:true,completed:84,recent_fps:5.098126443671696,mean_interval_ms:196.15048999839928,interval_ms:168.05550002027303,latest_interval_fps:5.950415189502081,window_intervals:20,window_face_frames:6,window_no_face_frames:14,result_age_seconds:.1}};
let v=m.view(state);assert.equal(v.value,'5.10');assert.match(v.detail,/本轮已完成 84 帧/);assert.match(v.detail,/196.2 ms \/ 5.10/);assert.match(v.detail,/最后间隔 168.1/);assert.match(v.detail,/有脸 6 帧、无脸 14 帧/);
state.connected=false;v=m.view(state);assert.equal(v.value,'—');assert.match(v.detail,/上次运行已完成 84 帧/);assert.match(v.detail,/历史统计/);
state.connected=true;state.pipeline.result_age_seconds=3;v=m.view(state);assert.equal(v.value,'—');assert.match(v.label,/等待新结果/);
state.pipeline.finishing=false;assert.equal(m.view(state).value,'—');
assert.equal(m.view({connected:true,pipeline:{}}).value,'—');
console.log('METRICS56_UI_MATCHED_WINDOW_HISTORY_AND_STALE_PASS');
