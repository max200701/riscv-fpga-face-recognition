"""Cold boot probes may reject reuse; only full readback can grant residency."""
from pathlib import Path
from gallery import BASE
from video_protocol import READ
from resident_resume import resume,ResidentBytesMismatch

def resume_if_present(demo,manifest,gallery,progress=lambda a,b:None):
    demo.idle()
    items=[r for r in manifest if r['kind']=='static_model']
    if not items:raise ValueError('No model assets')
    first=items[0];blob=Path(first['path']).read_bytes();blob+=bytes(-len(blob)%32)
    if demo.client.request(READ,address=first['address'],length=min(512,len(blob)))!=blob[:512]:
        return dict(status='MODEL_NOT_RESIDENT',adopted=False)
    if demo.client.request(READ,address=BASE,length=32)!=gallery.binary()[:32]:
        return dict(status='GALLERY_NOT_MATCHED',adopted=False)
    try:
        receipt=resume(demo,manifest,gallery,demo.expected_generation,progress)
    except ResidentBytesMismatch as e:
        return dict(status='RESIDENT_CONTENT_DIFFERENT',adopted=False,error=str(e))
    return dict(receipt,adopted=True)
