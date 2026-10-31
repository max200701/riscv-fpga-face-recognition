"""Explicit display ownership. Never select a reporter because it looks healthy."""
import copy,time,threading
NATIVE='WIN32_TK_EXACT_FRAME'
BROWSER='BROWSER'
class DisplaySources:
    def __init__(self):
        # Legacy default supports existing offline fixtures. Production selects native.
        self.selected=(BROWSER,'legacy');self.reports={};self.lock=threading.RLock()
    def put(self,report):
        provider=report.get('provider',BROWSER)
        if provider not in (NATIVE,BROWSER):raise ValueError('Unknown display provider')
        instance=report.get('source_instance','default' if provider==NATIVE else 'legacy')
        if not isinstance(instance,str) or not 1<=len(instance)<=96:raise ValueError('Display instance ID')
        key=(provider,instance);d=copy.deepcopy(report);d.update(provider=provider,source_instance=instance,received=time.monotonic())
        # Bound diagnostics only; the selected owner's report is never evicted.
        with self.lock:
            if key not in self.reports and len(self.reports)>=16:
                victims=[k for k in self.reports if k!=self.selected]
                if victims:self.reports.pop(min(victims,key=lambda k:self.reports[k]['received']))
            self.reports[key]=d
    def select(self,provider,instance):
        if provider not in (NATIVE,BROWSER):raise ValueError('Unknown display provider')
        with self.lock:
            if (provider,instance)!=(NATIVE,'default') and (provider,instance) not in self.reports:raise ValueError('Display window has not reported yet')
            self.selected=(provider,instance)
    def current(self):
        with self.lock:return self.reports.get(self.selected)
    def summary(self):
        now=time.monotonic()
        with self.lock:return dict(provider=self.selected[0],source_instance=self.selected[1],reporters=[dict(provider=k[0],source_instance=k[1],selected=k==self.selected,physical_width=d.get('physical_width'),physical_height=d.get('physical_height'),age_seconds=round(now-d['received'],1)) for k,d in self.reports.items()])
