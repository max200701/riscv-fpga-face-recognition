import struct,unittest
from video_session import parse_video
from video_protocol import ProtocolError

def packet(flags):
    w=[0]*16;w[0:3]=[0x31444956,1,flags]
    return struct.pack('<16I',*w)

class VideoFlags(unittest.TestCase):
    def test_old_flags(self):
        v=parse_video(packet(0x2001))
        self.assertTrue(v['start_permitted']);self.assertTrue(v['rx_configured'])
        self.assertFalse(v['dual_frame_capable']);self.assertEqual(v['shown_slot'],0)
    def test_both_slots(self):
        for shown in range(2):
            for active in range(2):
                v=parse_video(packet(0x40000|shown<<16|active<<17|0x2001))
                self.assertTrue(v['dual_frame_capable'])
                self.assertEqual((v['shown_slot'],v['active_slot']),(shown,active))
                self.assertTrue(v['start_permitted']);self.assertTrue(v['rx_configured'])
    def test_reject_unknown_or_unadvertised(self):
        for flags in (0x80000,0x10000,0x20000,0x30000):
            with self.assertRaises(ProtocolError):parse_video(packet(flags))

if __name__=='__main__':unittest.main()
