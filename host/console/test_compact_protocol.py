"""Real host collection logic with a bounded protocol fixture, no serial IO."""
import struct,unittest
from video_protocol import Client,SESSION,RESULT,SUMMARY_ACK,CPU_BUILD,ProtocolError
class Fixture(Client):
 def __init__(self):
  self.gen=4;self.mask=0;self.ack=False;self.calls=[];self.stale=False
 def request(self,op,address=0,length=0,payload=b''):
  self.calls.append((op,address))
  if op==SESSION:
   gen=self.gen+int(self.stale and self.ack)
   return struct.pack('<16I',0x31534553,1,gen,6|((self.ack or self.mask==(1<<33)-1)<<3),self.mask>>32,self.mask&0xffffffff,1,32,*([0]*8))
  if op==RESULT:
   self.mask|=1<<address
   if address:return struct.pack('<16f',*([.125]*16))
   return struct.pack('<16I',0x31445246,1,CPU_BUILD,15,2,2,1,7,0x3f800000,1,0x3ecccccd,1,0,0,1<<16,1<<16)
  if op==SUMMARY_ACK:
   assert address==self.gen and self.mask&1;self.ack=True;return b''
  raise AssertionError(op)
class Tests(unittest.TestCase):
 def test_compact_preserves_real_page_mask(self):
  c=Fixture();result,embedding=c.collect(4,include_embedding=False)
  self.assertEqual(embedding,b'');self.assertEqual(result['result_page_mask'],1)
  self.assertEqual(c.calls,[(SESSION,0),(RESULT,0),(SUMMARY_ACK,4),(SESSION,0)])
  self.assertEqual(result['export_mode'],'summary')
 def test_enrollment_can_fetch_after_summary(self):
  c=Fixture();c.collect(4,include_embedding=False);result,embedding=c.collect(4,include_embedding=True)
  self.assertEqual(len(embedding),2048);self.assertEqual(result['result_page_mask'],(1<<33)-1)
  self.assertEqual(result['embedding_words'],512)
 def test_stale_generation_rejected(self):
  c=Fixture();c.stale=True
  with self.assertRaises(ProtocolError):c.collect(4,include_embedding=False)
 def test_full_export_does_not_need_summary_ack(self):
  c=Fixture();r,b=c.collect(4)
  self.assertEqual(len(b),2048);self.assertFalse(any(op==SUMMARY_ACK for op,a in c.calls))
if __name__=='__main__':unittest.main(verbosity=2)
