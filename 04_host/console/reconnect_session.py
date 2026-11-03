"""Recover an interrupted serial owner through real protocol acknowledgements.

Never resets the FPGA, starts a captured image, uploads assets, or fabricates ACKs.
An orphaned committed result is archived before consuming/releasing it.
"""
import time
from gallery import GalleryTransfer
from video_session import VideoSession
from video_protocol import ProtocolError


def recover_idle(client, authorize, record=lambda value: None, timeout=30):
    authorize()
    video=VideoSession(client,authorize)
    deadline=time.monotonic()+timeout
    generation=None; ownership=None; stopped=False; recovered=False
    while True:
        health,v=video.check();s=client.session()
        if s['generation']!=v['session_generation']:
            raise ProtocolError('Reconnect generation differs between SESSION and VIDEO_STATUS')
        if generation is None:generation=s['generation']
        if generation!=s['generation']:raise ProtocolError('Reconnect generation changed unexpectedly')
        if health['phase']==0 and not v['video_reserved'] and not v['capture_busy'] and not v['application_selected']:
            GalleryTransfer(client,authorize).qualify_idle(health,s,v,generation)
            result=dict(status='IDLE_CONFIRMED',generation=generation,stopped_capture=stopped,recovered_capture=recovered)
            record(result);return result
        if v['video_reserved']:
            held={k:v['held_'+name] for k,name in (('session','session_generation'),('capture','capture_generation'),('frame','frame_id'))}
            if held['session']!=generation:raise ProtocolError('Reconnect owner belongs to another session')
            if ownership is not None and ownership!=held:raise ProtocolError('Reconnect capture owner changed')
            ownership=held;video.held=held
        if v.get('result_ready'):
            if not health.get('done') or not health.get('result_committed') or not s['memory_drained'] or ownership is None:
                raise ProtocolError('Reconnect result lacks CPU COMMIT, owner or physical drain')
            if v['result_source_id']!=1 or [v['result_session_generation'],v['result_capture_generation'],v['result_frame_id']]!=[ownership[k] for k in ('session','capture','frame')]:
                raise ProtocolError('Reconnect result source differs from held image')
            # Read-only archive precedes SUMMARY_ACK, so failed recording cannot silently consume a result.
            from video_protocol import parse_result
            archived=parse_result(client.result_page(0))
            record(dict(status='ORPHAN_RESULT_OBSERVED',generation=generation,owner=ownership,result=archived))
            result,_=client.collect_from_video(generation,v,include_embedding=False)
            after=client.video_status();video.matched(after)
            for key in ('result_source_id','result_session_generation','result_capture_generation','result_frame_id'):
                if after[key]!=v[key]:raise ProtocolError('Reconnect result changed during acknowledgement')
            record(dict(status='ORPHAN_RESULT_ACKNOWLEDGED',generation=generation,owner=ownership,result=result))
            authorize();released=client.rearm(generation)
            health,last=video.check();s=client.session()
            if released['generation']!=generation+1 or s['generation']!=released['generation']:
                raise ProtocolError('Reconnect REARM generation not incremented exactly once')
            GalleryTransfer(client,authorize).qualify_idle(health,s,last,released['generation'])
            receipt=dict(status='ORPHAN_RESULT_RELEASED',previous_generation=generation,generation=released['generation'],owner=ownership)
            record(receipt);return receipt
        if health['phase']==0 and ownership is not None:
            if v.get('stop_permitted') and not stopped:
                video.stop();stopped=True;record(dict(status='CAPTURE_STOP_REQUESTED',owner=ownership))
            elif v.get('recover_permitted') and v.get('source_stopped') and not recovered:
                video.recover();recovered=True;record(dict(status='CAPTURE_RECOVERY_REQUESTED',owner=ownership))
            elif not stopped and not recovered:
                raise ProtocolError('Captured frame cannot currently be cancelled; preserved without START or reset')
        if time.monotonic()>=deadline:
            raise ProtocolError('Reconnect is still waiting for real completion/drain; board state preserved')
        time.sleep(.05)
