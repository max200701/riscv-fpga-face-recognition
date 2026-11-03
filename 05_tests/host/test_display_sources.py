import time,unittest
from display_sources import DisplaySources,NATIVE,BROWSER
import test_ux_flow as flow
from demo_console import UserInputError
class RegistryTests(unittest.TestCase):
    def test_interleaved_browser_cannot_override_native(self):
        d=DisplaySources();d.select(NATIVE,'default')
        for i in range(48):
            d.put(dict(provider=NATIVE,physical_width=640,physical_height=480,painted=True))
            d.put(dict(provider=BROWSER,source_instance='popup',physical_width=1230,physical_height=975,painted=False))
            self.assertEqual(d.current()['provider'],NATIVE);self.assertEqual(d.current()['physical_width'],640)
        self.assertEqual(len(d.summary()['reporters']),2)
    def test_failed_native_never_falls_back_to_healthy_browser(self):
        d=DisplaySources();d.select(NATIVE,'default')
        d.put(dict(provider=NATIVE,painted=False,error='monitor removed'))
        d.put(dict(provider=BROWSER,source_instance='popup',painted=True,fullscreen=True))
        self.assertFalse(d.current()['painted']);self.assertEqual(d.current()['error'],'monitor removed')
    def test_explicit_browser_selection_isolated_from_other_windows(self):
        d=DisplaySources();d.put(dict(provider=BROWSER,source_instance='one',physical_width=640));d.select(BROWSER,'one')
        d.put(dict(provider=BROWSER,source_instance='two',physical_width=1230))
        self.assertEqual(d.current()['source_instance'],'one')
    def test_unknown_selection_rejected(self):
        d=DisplaySources()
        with self.assertRaises(ValueError):d.select(BROWSER,'not-reported')
        with self.assertRaises(ValueError):d.put(dict(provider='FAKE'))
class IntegrationTests(unittest.TestCase):
    setUp=flow.Tests.setUp
    ready=flow.Tests.ready
    display=flow.Tests.display
    run_one=flow.Tests.run_one
    def test_active_native_stale_fails_even_browser_recent(self):
        self.ready();self.c.select_display(NATIVE,'default')
        report=dict(source_id=self.c.source_id,rgb_crc32=self.c.state['source_crc'],painted=True,fullscreen=True,viewport_matches=True,physical_width=640,physical_height=480)
        self.c.display_report(dict(report,provider=NATIVE));self.assertTrue(self.c.display_ready())
        self.c.report['received']-=13
        self.c.display_report(dict(report,provider=BROWSER,source_instance='other'))
        self.assertFalse(self.c.display_ready())
    def test_active_frame_cannot_change_selected_source(self):
        self.ready();self.run_one()
        before=self.c.display_sources.selected
        with self.assertRaises(UserInputError):self.c.action('select_display',dict(provider=NATIVE,source_instance='default'))
        self.assertEqual(self.c.display_sources.selected,before);self.assertTrue(self.b.active)
if __name__=='__main__':unittest.main(verbosity=2)
