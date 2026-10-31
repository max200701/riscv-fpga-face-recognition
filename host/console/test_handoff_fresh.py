import unittest
from unittest.mock import patch
import test_host_pipeline as fixture
class Tests(unittest.TestCase):
    setUp=fixture.Tests.setUp;display=fixture.Tests.display;launch=fixture.Tests.launch
    def test_delayed_display_uses_fresh_release_but_no_second_idle_query(self):
        self.launch();self.p.feed('test',2,self.other);self.c.poll();self.b.ready=True;self.c.poll()
        self.assertEqual(self.b.releases,0)
        self.display()
        with patch.object(self.c.demo.transfer,'idle',side_effect=AssertionError('redundant idle reads')):
            self.p.tick()
        self.assertEqual(self.b.releases,1);self.assertEqual(self.b.arms,2)
        self.assertIsNone(self.c._immediate_arm_checked)

if __name__=='__main__':unittest.main()
