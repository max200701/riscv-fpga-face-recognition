"""Pure presentation policy. Hardware/protocol validation remains authoritative."""
import time

def display_diagnostics(core):
    d=core.report or {}; age=time.monotonic()-d.get('received',0)
    reasons=[]
    if not d or age>=12: reasons.append('尚未收到图像窗口心跳：请打开 HDMI 图像窗口，并保持窗口打开。')
    else:
        if d.get('source_id')!=core.source_id or d.get('rgb_crc32')!=core.state['source_crc'] or not d.get('painted'):
            reasons.append('图像窗口尚未显示本次图片，等待图片同步。')
        if not d.get('fullscreen'): reasons.append('请在图像窗口点击“全屏显示图片”，不要只按浏览器 F11。')
        if not d.get('viewport_matches') or (d.get('physical_width'),d.get('physical_height'))!=(640,480):
            reasons.append(f"图像窗口当前为 {d.get('physical_width','?')}×{d.get('physical_height','?')}；请把 FPGA 扩展显示器设为 640×480，再移入并全屏。")
    return dict(ready=not reasons,reasons=reasons,report={k:v for k,v in d.items() if k!='received'},age_seconds=None if not d else round(age,1))

def action_policy(s,display,backups):
    h=s.get('health') or {};v=s.get('video') or {};r=s.get('result');busy=s['busy'];held=s['held']
    connected=s['connected'];idle=connected and not held
    blocked='正在执行操作，请等待完成。' if busy else ''
    def why(*pairs):return blocked or next((message for condition,message in pairs if condition),'')
    offline=(not connected,'请先连接开发板。')
    occupied=(held,'当前帧仍由 FPGA 持有；请等待结果，再登记或释放。')
    ready=why(offline,occupied,(not s['model_resident'],'请先装载模型。'),(s['gallery_revision'] is None,'请先初始化板端图库（装载模型时自动完成）。'),(not display['ready'],' '.join(display['reasons'])))
    return {
      'resume':why(offline,occupied,(s['model_resident'],'驻留资产已经核对。')),
      'camera_frame':why(offline,(held and not r,'等待上一帧结果。')),
      'select_display':why(occupied),
      'connect':why((connected,'已经连接。'),(not s.get('hardware_connection_enabled',True),'此入口为离线测试。')),
      'disconnect':why(offline,occupied),
      'image':why((held and not r,'采集或计算正在进行，请等待结果。')),
      'upload':why(offline,occupied,(s['model_resident'] and s['gallery_revision'] is not None,'模型已驻留，无需重复装载。')),
      'arm':ready,'recognize':ready,
      'start':why(offline,(not held,'请先采集图片，或使用“一键采集并识别”。'),(bool(s.get('auto_stage')),'一键流程正在自动推进。'),(not v.get('frame_ready'),'等待完整帧写入 DDR。'),(not v.get('start_permitted'),'当前阶段不允许重复 START。')),
      'release':why(offline,(not held or not r,'需要先收到本帧结果。')),
      'enroll':why(offline,(not held or not r or not r.get('has_face'),'先识别一张人脸图片，再登记本次 FPGA 特征。')),
      'delete':why(offline,occupied,(not s['gallery'],'图库为空，没有可删除人员。')),
      'restore':why(offline,occupied,(not backups,'尚无图库备份；登记成功后会自动保存。')),
      'qualify_pixels':why(offline,(not held or h.get('phase')!=0 or not v.get('frame_ready') or v.get('application_selected') or bool(s.get('auto_stage')),'仅手动采集完成、识别开始前可读回像素。')),
      'stop':why(offline,(not held or not v.get('stop_permitted'),'仅尚未完成的采集可以取消；完整帧应识别后释放。')),
      'recover':why(offline,(not held or not v.get('recover_permitted') or not v.get('source_stopped'),'等待板端真实停止和排空。')),
      'release_recovered':why(offline,(not held or v.get('video_reserved') or not v.get('arm_permitted'),'尚未观察到恢复后的释放。')),
    }

def next_step(s,display):
    if s['busy']:return s.get('task_label') or '正在处理请求，请等待。'
    if not s['connected']:return '第 1 步：连接板端 UART 串口。图片可以先选好。'
    if not s['model_resident']:return '第 2 步：装载模型。仅首次连接需要；请保持板子供电。'
    if s.get('result') and s['held']:
        if s['result'].get('has_face'):return '识别已完成。首次使用请填写姓名并登记；也可释放换图。未登记时显示“未知人员”是正常结果。'
        return '本帧没有检测到人脸。可直接选择另一张照片，程序会先正常释放本帧。'
    if s['held']:return '等待 FPGA 完成采集和识别；当前图片保持锁定。'
    if not display['ready']:return '第 3 步：打开 HDMI 图像窗口。'+ ' '.join(display['reasons'])
    return '第 4 步：点击“一键采集并识别”。结果出来后可登记，再换另一张照片验证。'
