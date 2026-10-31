// Deterministic MMIO master and finite shared HMIC memory model.
// This driver NEVER computes graph results or installs intermediate activations.
// Golden files are read only by comparison commands, after actual RTL writes.
#include "Vdemo_board_logic.h"
#include "verilated.h"
#include <array>
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <deque>
#include "bounded_reads.hpp"
#include "release_observations.hpp"

struct Write { uint64_t visible; uint32_t address,mask;std::array<uint32_t,8> data; };
struct Sim {
 bool hdmi_mode=std::getenv("DEMO_HDMI")!=nullptr,video_run=false;
 uint32_t request_sequence=0,video_x=0,video_y=480;uint64_t nextp=19860;
 std::vector<uint8_t>video_pixels,expected_input;
 void video_inputs(){
  top.video_vs=video_run&&video_y>=490&&video_y<492;
  top.video_de=video_run&&video_y<480&&video_x<640;
  top.video_rgb=0;
  if(top.video_de){size_t i=(video_y*640+video_x)*3;top.video_rgb=(uint32_t(video_pixels[i])<<16)|(uint32_t(video_pixels[i+1])<<8)|video_pixels[i+2];}
  if(video_run&&++video_x==800){video_x=0;if(++video_y==525)video_y=0;}
 }
 std::vector<uint8_t> video_control(uint8_t op,uint32_t address,const std::vector<uint8_t>&payload={}){
  received.clear();uint32_t seq=++request_sequence;
  std::vector<uint8_t>h={0x46,0x42,0x44,0x31,1,op,0,0};
  for(uint32_t v:{seq,address,uint32_t(payload.size())})for(unsigned k=0;k<4;k++)h.push_back(v>>(8*k));
  auto cb=h;cb.insert(cb.end(),payload.begin(),payload.end());uint32_t c=crc32(cb,cb.size());
  for(unsigned k=0;k<4;k++)h.push_back(c>>(8*k));h.insert(h.end(),payload.begin(),payload.end());
  for(auto byte:h){uart_bit_send(false);for(unsigned k=0;k<8;k++)uart_bit_send((byte>>k)&1);uart_bit_send(true);}
  uint64_t limit=ddrcycles+180000;while(received.size()<24&&ddrcycles<limit)step();
  if(received.size()<24)fail("video reply header timeout");
  auto u32=[&](size_t at){uint32_t v=0;for(unsigned k=0;k<4;k++)v|=uint32_t(received[at+k])<<(8*k);return v;};
  uint32_t n=u32(16);if(n>64)fail("video reply extent");while(received.size()<24+n&&ddrcycles<limit)step();
  if(received.size()!=24+n||received[5]!=(op|0x80)||received[6]||u32(8)!=seq||u32(12)!=address)fail("video reply identity/status");
  cb.assign(received.begin(),received.begin()+20);cb.insert(cb.end(),received.begin()+24,received.end());if(u32(20)!=crc32(cb,cb.size()))fail("video reply CRC");
  return {received.begin()+24,received.end()};
 }
 static uint32_t word(const std::vector<uint8_t>&v,unsigned n){if(v.size()<(n+1)*4)throw std::runtime_error("short video status");uint32_t x=0;for(unsigned k=0;k<4;k++)x|=uint32_t(v[n*4+k])<<(k*8);return x;}
 void capture_input(unsigned epoch){
  if(video_pixels.size()!=640*480*3||expected_input.size()!=3686400)fail("HDMI fixtures extent");
  auto st=video_control(10,0);if(word(st,0)!=0x31444956||word(st,3)!=epoch||!(word(st,2)&(1<<9)))fail("video ARM status");
  std::vector<uint8_t>p;for(uint32_t v:{0x1000u+epoch,word(st,4),0u,0u})for(unsigned k=0;k<4;k++)p.push_back(v>>(8*k));
  uint64_t rb=readbytes,wb=writebytes,begin=npucycles;
  video_control(9,epoch,p);video_run=true;
  do{st=video_control(10,0);if((word(st,2)&(1<<5))||word(st,14))fail("video capture fault");if(npucycles-begin>12000000)fail("video finite capture timeout");}while(!(word(st,2)&(1<<4)));
  if(word(st,5)!=epoch||word(st,6)!=0x1000u+epoch||word(st,7)!=epoch||word(st,8)!=307200||word(st,9)!=7200)fail("video captured metadata/ACK");
  if(readbytes-rb!=0||writebytes-wb!=3686400||rleft||wleft||!pending.empty())fail("video physical extent/drain");
  for(size_t i=0;i<expected_input.size();i++)if(mem[0x01800000+i]!=expected_input[i])fail("HDMI actual DDR input mismatch byte="+std::to_string(i));
  std::vector<uint8_t>actual(mem.begin()+0x01800000,mem.begin()+0x01800000+expected_input.size());
  std::cout<<"ACTUAL_HDMI_CAPTURE_DDR_PASS epoch="<<epoch<<" generation="<<word(st,5)<<" frame="<<word(st,6)<<" input_crc="<<crc32(actual,actual.size())<<" cycles="<<npucycles-begin<<" physical_read="<<readbytes-rb<<" physical_write="<<writebytes-wb<<std::endl;
 }


 std::vector<std::pair<uint32_t,std::vector<uint8_t>>> gallery_records;
 static std::vector<uint8_t> read_file(const std::string& name,size_t size){
  std::ifstream f(name,std::ios::binary|std::ios::ate);
  if(!f||size_t(f.tellg())!=size)throw std::runtime_error("fixture extent "+name);
  std::vector<uint8_t>v(size);f.seekg(0);if(!f.read(reinterpret_cast<char*>(v.data()),size))throw std::runtime_error("fixture read "+name);return v;
 }
 std::vector<uint8_t> memory_uart(uint8_t op,uint32_t address,uint32_t length,const std::vector<uint8_t>& payload={}){
  if((op!=2&&op!=3)||length==0||length>512||length%32||address%32||payload.size()!=(op==3?length:0))fail("memory request shape");
  uint32_t seq=++request_sequence;received.clear();std::vector<uint8_t>h={0x46,0x42,0x44,0x31,1,op,0,0};
  for(uint32_t v:{seq,address,length})for(unsigned k=0;k<4;k++)h.push_back(v>>(8*k));
  auto cb=h;cb.insert(cb.end(),payload.begin(),payload.end());uint32_t crc=crc32(cb,cb.size());
  for(unsigned k=0;k<4;k++)h.push_back(crc>>(8*k));h.insert(h.end(),payload.begin(),payload.end());
  for(auto byte:h){uart_bit_send(false);for(unsigned k=0;k<8;k++)uart_bit_send((byte>>k)&1);uart_bit_send(true);}
  uint64_t limit=ddrcycles+1000000;while(received.size()<24&&ddrcycles<limit)step();
  if(received.size()<24)fail("memory response header timeout");
  uint32_t n=word(received,4);if(n!=(op==2?length:0))fail("memory reply extent");
  while(received.size()<24+n&&ddrcycles<limit)step();
  if(received.size()!=24+n||received[5]!=(op|0x80)||received[6]||word(received,2)!=seq||word(received,3)!=address)fail("memory response identity/status");
  cb.assign(received.begin(),received.begin()+20);cb.insert(cb.end(),received.begin()+24,received.end());
  if(word(received,5)!=crc32(cb,cb.size()))fail("memory reply CRC");
  return {received.begin()+24,received.end()};
 }
 void install_gallery(uint32_t generation,uint32_t revision){
  if(gallery_records.empty()||gallery_records.size()>16)fail("gallery record count");
  for(size_t i=0;i<gallery_records.size();i++){if(!gallery_records[i].first||gallery_records[i].second.size()!=2048)fail("enrollment identity/extent");for(size_t j=0;j<i;j++)if(gallery_records[i].first==gallery_records[j].first)fail("duplicate identity");}
  auto e=control_uart(7,0,++request_sequence);auto v=video_control(10,0);
  if(word(e,2)!=generation||(word(e,3)&5)!=5||(word(v,2)&(1<<2)))fail("gallery not exclusive BOOT/drained");
  uint64_t begin=npucycles,rb=readbytes,wb=writebytes;
  std::vector<uint8_t>payload;
  for(const auto&record:gallery_records){for(uint32_t w:{record.first,0u,0u,0u,0u,0u,0u,0u})for(int k=0;k<4;k++)payload.push_back(w>>(8*k));payload.insert(payload.end(),record.second.begin(),record.second.end());}
  std::vector<uint8_t>header;for(uint32_t w:{0x31424447u,1u,uint32_t(gallery_records.size()),revision,crc32(payload,payload.size()),2080u,0u,0u})for(int k=0;k<4;k++)header.push_back(w>>(8*k));
  memory_uart(3,0x0a000000u,32,std::vector<uint8_t>(32,0));
  if(memory_uart(2,0x0a000000u,32)!=std::vector<uint8_t>(32,0))fail("invalid gallery header not visible");
  for(size_t i=0;i<payload.size();){uint32_t address=0x0a000020u+i;size_t n=std::min(std::min(size_t(512),payload.size()-i),size_t(4096-(address&4095)));std::vector<uint8_t>b(payload.begin()+i,payload.begin()+i+n);memory_uart(3,address,n,b);if(memory_uart(2,address,n)!=b)fail("enrollment record readback");i+=n;}
  memory_uart(3,0x0a000000u,32,header);if(memory_uart(2,0x0a000000u,32)!=header)fail("gallery header commit readback");
  if(rleft||wleft||!pending.empty())fail("gallery ACK before physical drain");
  std::ofstream f("gallery_revision_"+std::to_string(revision)+".bin",std::ios::binary);f.write(reinterpret_cast<char*>(header.data()),header.size());f.write(reinterpret_cast<char*>(payload.data()),payload.size());if(!f)fail("gallery receipt save");
  std::cout<<"ACTUAL_UART_GALLERY_INSTALL_PASS generation="<<generation<<" revision="<<revision<<" records="<<gallery_records.size()<<" cycles="<<npucycles-begin<<" physical_read="<<readbytes-rb<<" physical_write="<<writebytes-wb<<std::endl;
 }
 std::string golden_prefix;unsigned epoch_id=0;uint64_t input_bytes=0;bool runtime_fault=false,fault_injected=false;
 VerilatedContext context;Vdemo_board_logic top{&context};
 std::vector<uint8_t> mem=std::vector<uint8_t>(256*1024*1024,0xa5);
 uint64_t ps=0,nextc=12000,nextd=4000,ddrcycles=0,cpucycles=0,npucycles=0;
 uint64_t readbytes=0,writebytes=0,usefulbytes=0,bursts=0;
 uint32_t rbase=0,wbase=0,rid=0,wid=0,rleft=0,wleft=0,rdelay=0,credit=0,rate=750,tag=0;
 bool choose=false;std::deque<Write> pending;BoundedReads reads;uint32_t first_latency=3;
 unsigned uart_state=0,uart_wait=0,uart_bit=0,uart_value=0;std::vector<uint8_t>received;
 Sim(int argc,char**argv){if(const char*p=std::getenv("DDR_FIRST_LATENCY")){first_latency=std::stoul(p);if(first_latency<1||first_latency>4096)throw std::runtime_error("latency scenario range");}
 std::cout<<"PHYSICAL_MEMORY_MODEL requests=8 beats=64 first_latency="<<first_latency<<" ui_Hz=125000000 shared_limit_Bps=3000000000"<<std::endl;context.commandArgs(argc,argv);top.video_pclk=0;top.video_prst=1;top.video_pixel_lock=1;top.video_vs=0;top.video_de=0;top.video_rgb=0;
 top.video_rx_configured=1;top.video_rx_candidate=1;top.video_rx_fault=0;top.video_rx_fault_code=0;top.video_rx_raw_status=0x20000;
 top.rst=1;top.clk_cpu=0;top.clk_ui=0;top.ddr_init_done=0;top.uart_rx=1;top.safety_ready=1;top.temperature=uint64_t(2600)<<32|uint64_t(1)<<44;top.physical_flags=0;top.eval();for(int i=0;i<100;i++)step();top.rst=0;top.video_prst=0;top.ddr_init_done=1;top.eval();}
 void rx_uart(){
  if(!uart_state){if(!top.uart_tx){uart_state=1;uart_wait=68;}}
  else if(--uart_wait==0){
   if(uart_state==1){if(top.uart_tx){uart_state=0;return;}uart_state=2;uart_bit=0;uart_value=0;uart_wait=136;}
   else if(uart_state==2){uart_value|=(unsigned(top.uart_tx)<<uart_bit);uart_bit++;uart_wait=136;if(uart_bit==8)uart_state=3;}
   else{if(!top.uart_tx)fail("UART stop bit");received.push_back(uint8_t(uart_value));uart_state=0;}
  }
 }
 void uart_bit_send(bool bit){top.uart_rx=bit;top.eval();uint64_t target=ddrcycles+136;while(ddrcycles<target)step();}
 static uint32_t crc32(const std::vector<uint8_t>&v,size_t n){uint32_t c=~0u;for(size_t i=0;i<n;i++){c^=v[i];for(int j=0;j<8;j++)c=c>>1^((c&1)?0xedb88320u:0);}return ~c;}
 void start_uart(uint32_t generation=0,uint32_t sequence=1){
  received.clear();
  for(int i=0;i<8;i++)uart_bit_send(true);
  std::vector<uint8_t>h={0x46,0x42,0x44,0x31,1,4,0,0}; for(uint32_t v:{sequence,generation,0u})for(int k=0;k<4;k++)h.push_back(v>>(8*k));
  uint32_t c=crc32(h,20);for(int k=0;k<4;k++)h.push_back(c>>(8*k));
  for(auto byte:h){uart_bit_send(false);for(int b=0;b<8;b++)uart_bit_send((byte>>b)&1);uart_bit_send(true);}
  uint64_t limit=ddrcycles+50000;while(received.size()<24&&ddrcycles<limit)step();
  if(received.size()!=24||received[5]!=0x84||received[6]!=0)fail("UART START rejected/truncated");
  uint32_t got=0;for(int k=0;k<4;k++)got|=uint32_t(received[20+k])<<(8*k);
  if(got!=crc32(received,20))fail("UART START CRC");
  std::cout<<"ACTUAL_UART_START_ACK_PASS ui_cycles="<<ddrcycles<<std::endl;
 }
 std::vector<uint8_t> result_uart(unsigned page,unsigned sequence){
  received.clear();std::vector<uint8_t>h={0x46,0x42,0x44,0x31,1,6,0,0};
  for(uint32_t v:{sequence,page,0u})for(int k=0;k<4;k++)h.push_back(v>>(8*k));
  uint32_t c=crc32(h,20);for(int k=0;k<4;k++)h.push_back(c>>(8*k));
  for(auto byte:h){uart_bit_send(false);for(int b=0;b<8;b++)uart_bit_send((byte>>b)&1);uart_bit_send(true);}
  uint64_t limit=ddrcycles+160000;while(received.size()<88&&ddrcycles<limit)step();
  if(received.size()!=88||received[5]!=0x86||received[6]||received[16]!=64)fail("UART result status/extent");
  auto u32=[&](size_t at){uint32_t v=0;for(int k=0;k<4;k++)v|=uint32_t(received[at+k])<<(8*k);return v;};
  if(u32(8)!=sequence||u32(12)!=page)fail("UART result identity");
  std::vector<uint8_t>crcbytes(received.begin(),received.begin()+20);crcbytes.insert(crcbytes.end(),received.begin()+24,received.end());
  if(u32(20)!=crc32(crcbytes,crcbytes.size()))fail("UART result CRC");
  return {received.begin()+24,received.end()};
 }

 std::vector<uint8_t> control_uart(uint8_t opcode,uint32_t address,uint32_t sequence){
  received.clear();std::vector<uint8_t>h={0x46,0x42,0x44,0x31,1,opcode,0,0};
  for(uint32_t v:{sequence,address,0u})for(int k=0;k<4;k++)h.push_back(v>>(8*k));
  uint32_t c=crc32(h,20);for(int k=0;k<4;k++)h.push_back(c>>(8*k));
  for(auto byte:h){uart_bit_send(false);for(int b=0;b<8;b++)uart_bit_send((byte>>b)&1);uart_bit_send(true);}
  uint64_t limit=ddrcycles+160000;while(received.size()<24&&ddrcycles<limit)step();
  if(received.size()<24)fail("control header timeout");
  auto u32=[&](size_t at){uint32_t v=0;for(int k=0;k<4;k++)v|=uint32_t(received[at+k])<<(8*k);return v;};
  uint32_t n=u32(16);if(n>64)fail("control length");
  while(received.size()<24+n&&ddrcycles<limit)step();
  if(received.size()!=24+n||received[5]!=(opcode|0x80)||received[6]||u32(8)!=sequence||u32(12)!=address)fail("control reply identity/status");
  std::vector<uint8_t>cb(received.begin(),received.begin()+20);cb.insert(cb.end(),received.begin()+24,received.end());
  if(u32(20)!=crc32(cb,cb.size()))fail("control reply CRC");
  return {received.begin()+24,received.end()};
 }
 [[noreturn]] void fail(const std::string& what){throw std::runtime_error(what+" npu_cycles="+std::to_string(npucycles));}
 void commits(){while(!pending.empty()&&pending.front().visible<=ddrcycles){auto w=pending.front();pending.pop_front();for(int i=0;i<32;i++)if(w.mask&(1u<<i))mem[w.address+i]=(w.data[i/4]>>((i%4)*8))&255;}}
 void ddr_inputs(){
  commits();credit=std::min(credit+rate,2000u);
  top.axi_arready=!top.rst&&reads.can_accept(top.axi_arlen+1)&&(ddrcycles%7!=0);
  top.axi_awready=!top.rst&&!wleft&&(ddrcycles%5!=0);
  top.axi_rvalid=0;top.axi_wready=0;
  bool r=reads.ready(ddrcycles),w=wleft;
  if(credit>=1000&&(r||w)){
   bool wr=w&&(!r||choose);choose=!choose;
   if(wr){top.axi_wready=1;top.axi_wusero_id=wid;top.axi_wusero_last=wleft==1;}
   else{
    const auto& req=reads.front();rbase=req.address;
    top.axi_rvalid=1;top.axi_rid=req.id;top.axi_rlast=req.left==1;
    for(int i=0;i<8;i++){uint32_t v=0;for(int j=0;j<4;j++)v|=uint32_t(mem[rbase+i*4+j])<<(j*8);top.axi_rdata[i]=v;}
   }
  }
 }
 void ddr_sample(){
  if(top.axi_arvalid&&top.axi_arready){
   uint64_t b=uint64_t(top.axi_araddr)*4;uint32_t n=top.axi_arlen+1;
   if(!reads.can_accept(n)||b%32||b+n*32>mem.size()||(b%4096)+n*32>4096)fail("invalid read burst");
   rid=top.axi_aruser_id; if(rid==8)fail("release emitted diagnostic verify read");
   if(runtime_fault&&!fault_injected&&top.cpu_phase==8&&b>=0x07000000u&&b<0x07480000u){rid^=1;fault_injected=true;std::cout<<"INJECT_PROGRAM_RID address="<<b<<std::endl;}
   reads.push(b,n,rid,ddrcycles+first_latency);rleft+=n;
  }
  if(top.axi_awvalid&&top.axi_awready){
   uint64_t b=uint64_t(top.axi_awaddr)*4;uint32_t n=top.axi_awlen+1;
   if(wleft||b%32||b+n*32>mem.size()||(b%4096)+n*32>4096)fail("invalid write burst");
   wbase=b;wleft=n;wid=top.axi_awuser_id;bursts++;
  }
  if(top.axi_rvalid){reads.consume();rleft--;readbytes+=32;credit-=1000;}
  if(rleft!=reads.beats)fail("model queue/drain accounting");
  if(top.axi_wready){
   Write w;w.visible=ddrcycles+3;w.address=wbase;w.mask=top.axi_wstrb;
   for(int i=0;i<8;i++)w.data[i]=top.axi_wdata[i];pending.push_back(w);
   usefulbytes+=__builtin_popcount(w.mask);wleft--;wbase+=32;writebytes+=32;credit-=1000;
  }
 }
 // Returns whether this event is a CPU rising edge. All handshakes are sampled
 // before that edge, and inputs remain stable until the following bus phase.
 bool step(){
  uint64_t t=std::min(std::min(nextc,nextd),nextp);context.time(t);ps=t;
  bool pp=t==nextp;bool cp=t==nextc,dd=t==nextd;bool cr=cp&&!top.clk_cpu,dr=dd&&!top.clk_ui;
  if(dr){ddr_sample();rx_uart();}
  if(cp){top.clk_cpu=!top.clk_cpu;nextc+=16000;if(cr)cpucycles++;}
  if(dd){top.clk_ui=!top.clk_ui;nextd+=4000;if(dr){ddrcycles++;npucycles++;}}
  if(pp){top.video_pclk=!top.video_pclk;nextp+=19860;if(!top.video_pclk)video_inputs();}
  top.eval();if(dd&&!top.clk_ui){ddr_inputs();top.eval();}
  if(top.fault&&!top.rst&&!runtime_fault&&!std::getenv("PW_BAD_IMAGE"))fail("board/application fault status="+std::to_string(top.cpu_status));
  if(context.gotFinish())fail("unexpected RTL finish");return cr;
 }
 struct Passive {uint32_t address,bytes,id;uint64_t began;};
 std::deque<Passive> passive;
 void schedule_compare(uint32_t address,uint32_t bytes,uint32_t id){passive.push_back({address,bytes,id,npucycles});}
 bool target_busy(const Passive&o){
  auto overlap=[&](uint32_t a,uint32_t n){return uint64_t(a)<uint64_t(o.address)+o.bytes&&uint64_t(o.address)<uint64_t(a)+n;};
  if(wleft&&overlap(wbase,wleft*32))return true;
  for(const auto&w:pending)if(overlap(w.address,32))return true;
  return false;
 }
 void service_observations(uint64_t&checks){
  while(!passive.empty()){
   const auto o=passive.front();
   if(target_busy(o)){if(npucycles-o.began>4096)fail("passive target visibility deadline id="+std::to_string(o.id));return;}
   compare(o.address,o.bytes,o.id);passive.pop_front();checks++;
  }
 }
 void compare(uint32_t address,uint32_t bytes,uint32_t id){
  for(const auto&w:pending)if(uint64_t(w.address)<uint64_t(address)+bytes&&uint64_t(address)<uint64_t(w.address)+32)
   fail("passive target still pending id="+std::to_string(id));
  std::ifstream f(golden_prefix+"gold_"+std::to_string(id)+".bin",std::ios::binary);std::vector<char> gold(bytes);
  if(!f.read(gold.data(),bytes))fail("missing/truncated golden file");
  for(uint32_t i=0;i<bytes;i++)if(mem[address+i]!=uint8_t(gold[i]))fail("GOLD id="+std::to_string(id)+" byte="+std::to_string(i)+" addr="+std::to_string(address+i)+" actual="+std::to_string(mem[address+i])+" expected="+std::to_string(uint8_t(gold[i])));
  if(address==0x05800000u||address==0x05a00000u){
   std::ofstream actual("actual_"+golden_prefix+std::to_string(id)+".bin",std::ios::binary);
   actual.write(reinterpret_cast<const char*>(mem.data()+address),bytes);
   if(!actual)fail("cannot save observed final output");
   std::ofstream epoch_output("epoch_"+std::to_string(epoch_id)+"_actual_"+golden_prefix+std::to_string(id)+".bin",std::ios::binary);
   epoch_output.write(reinterpret_cast<const char*>(mem.data()+address),bytes);
   if(!epoch_output)fail("cannot preserve epoch output");
  }
 }
};


static void pw_mode(Sim&s,uint32_t generation,uint32_t mode,uint32_t n){
 std::vector<uint8_t>p;for(auto w:{mode,n,0u,0u})for(int j=0;j<4;j++)p.push_back(w>>(8*j));
 s.video_control(14,generation,p);
}
static void pw_coremark(Sim&s,uint32_t generation,uint32_t mode,uint32_t n,bool upload){
 auto before=s.mem;
 if(upload){
  std::ifstream f("coremark_image.bin",std::ios::binary|std::ios::ate);if(!f)s.fail("benchmark image missing");
  size_t count=f.tellg();f.seekg(0);std::vector<uint8_t>b(count);f.read(reinterpret_cast<char*>(b.data()),count);
  if(count<32||count>0xe020||(count&31))s.fail("benchmark image geometry");
  for(size_t i=0;i<count;){uint32_t addr=0x0c000000u+i;size_t k=std::min({size_t(512),count-i,size_t(4096-(addr&4095))});
   s.memory_uart(3,addr,k,std::vector<uint8_t>(b.begin()+i,b.begin()+i+k));i+=k;}
  if(!std::equal(b.begin(),b.end(),s.mem.begin()+0x0c000000u))s.fail("actual upload differs");
  std::copy(b.begin(),b.end(),before.begin()+0x0c000000u);
  std::cout<<"PW_ACTUAL_UART_UPLOAD_PASS bytes="<<count<<std::endl;
 }
 pw_mode(s,generation,mode,n);s.start_uart(generation,++s.request_sequence);auto started=s.npucycles;
 bool seen=s.top.mark_toggle;while(!s.top.finished){
  s.step();if(std::getenv("PW_BAD_IMAGE")&&s.top.fault)break;if(s.top.mark_toggle!=seen){seen=s.top.mark_toggle;std::cout<<"PW_COREMARK_MARK id="<<s.top.mark_a<<" value="<<s.top.mark_b<<std::endl;}
  if(s.npucycles-started>100000000ULL)s.fail("benchmark timeout pc="+std::to_string(s.top.cpu_pc));
 }
 if(std::getenv("PW_BAD_IMAGE")){
  if(!s.top.fault||s.top.cpu_status!=unsigned(std::atoi(std::getenv("PW_EXPECT_ERROR")))||s.top.npu_macs||s.top.vector_elements||s.mem!=before)s.fail("bad image executed or published");
  std::cout<<"PW_BAD_IMAGE_REJECT_PASS status="<<s.top.cpu_status<<std::endl;return;
 }
 if(s.top.cpu_status!=1||s.top.fault||s.top.npu_macs||s.top.vector_elements)s.fail("benchmark CPU/error/NPU activity status="+std::to_string(s.top.cpu_status));
 auto result=s.result_uart(0,++s.request_sequence);auto w=[&](unsigned i){return Sim::word(result,i);};
 uint64_t cycles=uint64_t(w(6))|(uint64_t(w(7))<<32);
 if(w(0)!=0x314b4d43u||w(1)!=1||!(w(3)&2)||w(3)&5||bool(w(3)&8)!=(mode==2)||w(4)!=31250000||w(5)!=n||!cycles||w(13)!=2000||w(14)||w(15)!=1)s.fail("benchmark result contract");
 if(w(8)!=(mode==2?0x18f2u:0xe9f5u)||w(9)!=(mode==2?0xe3c1u:0xe714u)||w(10)!=(mode==2?0x0747u:0x1fd7u)||w(11)!=(mode==2?0x8d84u:0x8e3au))s.fail("benchmark CRC");
 std::ofstream out("coremark_"+std::to_string(generation)+".bin",std::ios::binary);out.write(reinterpret_cast<char*>(result.data()),result.size());out.close();
 s.control_uart(8,generation,++s.request_sequence);auto st=s.control_uart(7,0,++s.request_sequence);
 if(Sim::word(st,2)!=generation+1||s.top.finished||s.mem!=before||s.rleft||s.wleft||!s.pending.empty())s.fail("benchmark release or model preservation");
 std::cout<<"PW_COREMARK_ACTUAL_CPU_PASS generation="<<generation<<" mode="<<mode<<" iterations="<<n<<" cycles="<<cycles<<" real_uart=1 NPU_ops=0 DDR_unchanged=1 release=1 official10s=0"<<std::endl;
}
static void pw_face_return(Sim&s,uint32_t generation,const std::vector<uint8_t>&expected){
 pw_mode(s,generation,0,0);s.video_run=false;s.epoch_id=0;s.golden_prefix="e4_";
 s.start_uart(generation,++s.request_sequence);uint64_t checks=0,started=s.npucycles;std::array<bool,219>audited{};
 uint32_t last_base=~0u,last_index=~0u;bool seen=s.top.mark_toggle;
 while(!s.top.finished){
  s.step();
  if((s.top.audit_state==1||s.top.audit_done)&&s.top.audit_base){
   unsigned model=s.top.audit_base==0x07000000u?0u:1u,ix=s.top.audit_done?(model==0?14481u:4005u):s.top.audit_index;
   if(s.top.audit_base!=last_base||ix!=last_index){last_base=s.top.audit_base;last_index=ix;
    if(model==1&&ix==0&&!audited[218]){s.schedule_compare(0x01c00000u,150528,218);audited[218]=true;}
    for(const auto&o:observations)if(o.model==model&&o.index==ix&&!audited[o.id]){s.schedule_compare(o.address,o.bytes,o.id);audited[o.id]=true;}
   }
  }
  s.service_observations(checks);
  if(s.top.mark_toggle!=seen){seen=s.top.mark_toggle;std::cout<<"PW_RETURN_FACE_MARK id="<<s.top.mark_a<<" value="<<s.top.mark_b<<std::endl;}
  if(s.npucycles-started>100000000ULL)s.fail("return face timeout");
 }
 s.service_observations(checks);if(s.top.cpu_status!=1||s.top.fault||checks!=219||!s.passive.empty())s.fail("return face full numerical checks");
 auto result=s.result_uart(0,++s.request_sequence);if(result!=expected)s.fail("face result changed after benchmark");
 auto gold=Sim::read_file("e4_gold_217.bin",2048);if(!std::equal(gold.begin(),gold.end(),s.mem.begin()+0x05a00000u))s.fail("return embedding");
 s.control_uart(13,generation,++s.request_sequence);s.control_uart(8,generation,++s.request_sequence);
 auto st=s.control_uart(7,0,++s.request_sequence);if(Sim::word(st,2)!=generation+1||s.top.finished)s.fail("return face release");
 std::cout<<"PW_FACE_COREMARK_FACE_PASS checks=219 feature_bytes=2048 metadata_bytes=64 same_bitstream=1 reuploaded_model_bytes=0 generation="<<generation+1<<std::endl;
}

int main(int argc,char**argv){
 try{
  Sim s(argc,argv);
  if(std::getenv("PW_COREMARK_ONLY")){
   pw_coremark(s,0,1,1,true);if(std::getenv("PW_BAD_IMAGE"))return 0;
   pw_coremark(s,1,2,1,false);pw_coremark(s,2,1,3,false);pw_mode(s,3,0,0);
   std::cout<<"PW_COREMARK_THREE_RUNS_PASS"<<std::endl;return 0;
  }if(argc>1)s.rate=std::stoul(argv[1]);
  std::ifstream index("segments.txt");uint32_t address;std::string file;
  while(index>>std::hex>>address>>file){std::ifstream f(file,std::ios::binary|std::ios::ate);if(!f)throw std::runtime_error("missing segment "+file);size_t n=f.tellg();f.seekg(0);if(uint64_t(address)+n>s.mem.size())throw std::runtime_error("segment range");if(address==0x01800000u){s.input_bytes=n;s.expected_input.resize(n);f.read(reinterpret_cast<char*>(s.expected_input.data()),n);if(!s.hdmi_mode)std::copy(s.expected_input.begin(),s.expected_input.end(),s.mem.begin()+address);}
  else f.read(reinterpret_cast<char*>(s.mem.data()+address),n);}
  if(s.hdmi_mode){std::ifstream f("frame.rgb",std::ios::binary|std::ios::ate);if(!f||f.tellg()!=640*480*3)s.fail("missing RGB fixture");s.video_pixels.resize(640*480*3);f.seekg(0);f.read(reinterpret_cast<char*>(s.video_pixels.data()),s.video_pixels.size());}
  unsigned epochs=5;
  if(!s.hdmi_mode||std::getenv("DEMO_PREFLIGHT_ONLY")||std::getenv("FLOW_CHECKPOINT_SMOKE"))s.fail("full dynamic HDMI test required");
  s.gallery_records.push_back({7,Sim::read_file("seed_feature.bin",2048)});s.install_gallery(0,1);uint64_t epoch_start=s.npucycles;
  for(unsigned epoch=0;epoch<epochs;epoch++){
  s.epoch_id=epoch;
  s.golden_prefix="e"+std::to_string(epoch)+"_";
  s.video_pixels=Sim::read_file("epoch_"+std::to_string(epoch)+"_frame.rgb",640*480*3);
  s.expected_input=Sim::read_file("epoch_"+std::to_string(epoch)+"_input.bin",3686400);
  if(s.rleft||s.wleft||!s.pending.empty())s.fail("frame swap before drain");
  uint64_t epoch_read=s.readbytes,epoch_write=s.writebytes,epoch_useful=s.usefulbytes;
  std::cout<<"RESIDENT_EPOCH_BEGIN epoch="<<epoch<<" absolute_cycles="<<s.npucycles<<std::endl;
  if(s.hdmi_mode)s.capture_input(epoch);s.start_uart(epoch,++s.request_sequence);uint64_t checks=0;bool seen=s.top.mark_toggle;uint64_t last_progress=0;bool cold_checked=false;uint64_t checkpoint_cycle=0;int validation_mode=-1;bool validation_receipt=false;
  std::array<bool,219> audited{};uint32_t last_audit_base=~0u,last_audit_index=~0u;
  while(!s.top.finished){
   s.step();
   // Passive simulator-only observation. Never inserts a bus transaction or clock.
   // Removed records are mapped to the next actual command boundary, or graph done.
   if((s.top.audit_state==1||s.top.audit_done)&&s.top.audit_base){
    unsigned model=s.top.audit_base==0x07000000u?0u:1u;
    unsigned ix=s.top.audit_done?(model==0?14481u:4005u):s.top.audit_index;
    if(s.top.audit_base!=last_audit_base||ix!=last_audit_index){
     last_audit_base=s.top.audit_base;last_audit_index=ix;
     if(model==1&&ix==0&&!audited[218]){s.schedule_compare(0x01c00000u,150528,218);audited[218]=true;}
     for(const auto&o:observations)if(o.model==model&&o.index==ix&&!audited[o.id]){
      s.schedule_compare(o.address,o.bytes,o.id);audited[o.id]=true;
     }
     if(ix==0||s.top.audit_done)std::cout<<"RELEASE_GRAPH_STAGE model="<<model<<" done="<<int(s.top.audit_done)<<" cycles="<<s.npucycles<<" read="<<s.readbytes<<" write="<<s.writebytes<<std::endl;
    }
   }
   s.service_observations(checks);
   if(s.top.mark_toggle!=seen){
    seen=s.top.mark_toggle;
    if(s.top.mark_kind==0x200){s.compare(s.top.mark_a,s.top.mark_b,s.top.mark_c);checks++;}
    else if(s.top.mark_kind==0x201){
     if(s.top.mark_a==0xfffffff5u)validation_mode=int(s.top.mark_b);
     if(s.top.mark_a==0xfffffff6u){if(s.top.mark_b!=0x50454d31u)s.fail("bad model validation receipt");validation_receipt=true;}
     std::cout<<"CPU_GRAPH_STAGE id="<<s.top.mark_a<<" frame="<<s.top.mark_b<<" commands="<<s.top.command_index+1<<" cpu_cycles="<<s.top.cpu_cycles<<" cycles="<<s.npucycles<<" read="<<s.readbytes<<" write="<<s.writebytes<<" mac="<<s.top.npu_macs<<" vector="<<s.top.vector_elements<<std::endl;
    }
    else s.fail("unknown CPU diagnostic marker");
   }
   if(s.cpucycles-last_progress>=5000000 && (last_progress=s.cpucycles))std::cout<<"CPU_PROGRESS cycles="<<s.cpucycles<<" command="<<s.top.command_index<<" phase="<<s.top.cpu_phase<<" pc="<<s.top.cpu_pc<<std::endl;
   if(s.top.cpu_phase==8&&!cold_checked){
    if(!s.top.audit_model_verified||!s.top.audit_gallery_verified||validation_receipt==(epoch!=0))s.fail("release model/gallery validation receipt");
    if(s.top.npu_macs||s.top.vector_elements||checks)s.fail("preflight stop after computation");
    std::cout<<"BOARD_LOGIC_ACTUAL_CPU_RESIDENCY_GATE_PASS cpu_cycles="<<s.top.cpu_cycles<<" read="<<s.readbytes<<std::endl;
    cold_checked=true;checkpoint_cycle=s.npucycles;
    if(std::getenv("DEMO_PREFLIGHT_ONLY"))return 0;
   }
   if(cold_checked&&std::getenv("FLOW_CHECKPOINT_SMOKE")&&s.npucycles>=checkpoint_cycle+64){
    std::cout<<"CHECKPOINT_CONTINUED_SAME_PROCESS_SMOKE_PASS npu_cycles="<<s.npucycles<<" checkpoint_cycle="<<checkpoint_cycle<<" cpu_cycles="<<s.top.cpu_cycles<<" read="<<s.readbytes<<std::endl;
    return 0;
   }
   if(s.cpucycles>1000000000ULL)s.fail("CPU graph timeout");
  }
  s.service_observations(checks);if(!s.passive.empty())s.fail("unobserved result at application completion");
  if(s.runtime_fault){
   if(!s.fault_injected||s.top.cpu_status==1||s.top.npu_macs!=0||s.top.vector_elements!=0||checks!=0)s.fail("RUNTIME_FAULT_PUBLISHED_COMPUTATION");
   std::cout<<"CPU_GRAPH_EXPECTED_RUNTIME_FAULT status="<<s.top.cpu_status<<" mac="<<s.top.npu_macs<<" vector="<<s.top.vector_elements<<" checks="<<checks<<std::endl;return 0;
  }
  if(s.top.cpu_status!=1)s.fail("CPU software error="+std::to_string(s.top.cpu_status)+" mac="+std::to_string(s.top.npu_macs)+" vector="+std::to_string(s.top.vector_elements));
  std::cout<<"CPU_GRAPH_RTL_PASS commands="<<s.top.command_index+1<<" checks="<<checks<<" cpu_cycles="<<s.top.cpu_cycles<<" npu_cycles="<<(s.npucycles-epoch_start)<<" read_bytes="<<(s.readbytes-epoch_read)<<" bus_write_bytes="<<(s.writebytes-epoch_write)<<" useful_write_bytes="<<(s.usefulbytes-epoch_useful)<<" mac_cycles="<<s.top.npu_macs<<" vector_elements="<<s.top.vector_elements<<std::endl;
  std::ofstream output("actual_uart_result.bin",std::ios::binary);
  std::ofstream epoch_output("epoch_"+std::to_string(epoch)+"_actual_uart_result.bin",std::ios::binary);
  auto metadata=s.result_uart(0,++s.request_sequence);bool has_face=Sim::word(metadata,3)&1;
  if(Sim::word(metadata,0)!=0x31445246u||Sim::word(metadata,1)!=1||Sim::word(metadata,2)!=0x261007a1u||!has_face)s.fail("dynamic result identity/has_face");
  uint32_t expected_count=epoch==0?1u:epoch<=2?2u:3u;
  if(checks!=219||Sim::word(metadata,9)!=expected_count||Sim::word(metadata,11)!=expected_count) s.fail("multi-person graph/gallery contract");
  bool expected_accepted=epoch!=0&&epoch!=2;uint32_t expected_id=epoch==1?8u:epoch==3?9u:7u;
  if(bool(Sim::word(metadata,3)&2)!=expected_accepted||(expected_accepted&&Sim::word(metadata,7)!=expected_id))s.fail("actual CPU unknown/known decision");
  output.write(reinterpret_cast<char*>(metadata.data()),metadata.size());epoch_output.write(reinterpret_cast<char*>(metadata.data()),metadata.size());
  std::vector<uint8_t>embedding;
  bool compact=(epoch==1||epoch==3||epoch==4);
  if(has_face&&!compact)for(unsigned page=1;page<=32;page++){auto data=s.result_uart(page,++s.request_sequence);output.write(reinterpret_cast<const char*>(data.data()),data.size());epoch_output.write(reinterpret_cast<const char*>(data.data()),data.size());embedding.insert(embedding.end(),data.begin(),data.end());}
  if(epoch==0)s.gallery_records.push_back({8,embedding});
  if(epoch==2)s.gallery_records.push_back({9,embedding});
  if(compact){
   s.control_uart(13,epoch,++s.request_sequence);
   auto ack=s.control_uart(7,0,++s.request_sequence);
   if(Sim::word(ack,2)!=epoch||!(Sim::word(ack,3)&8)||Sim::word(ack,4)||Sim::word(ack,5)!=1)s.fail("compact ACK falsified pages or generation");
   std::cout<<"COMPACT_RESULT_ACK_REAL_RELEASE_PASS epoch="<<epoch<<" pages=1 bytes=64"<<std::endl;
  }
  if(s.hdmi_mode){auto st=s.video_control(10,0);if(!(Sim::word(st,2)&(1<<12))||Sim::word(st,10)!=1||Sim::word(st,11)!=epoch||Sim::word(st,12)!=epoch||Sim::word(st,13)!=0x1000u+epoch)s.fail("result video source mismatch");std::cout<<"ACTUAL_HDMI_RESULT_ASSOCIATION_PASS epoch="<<epoch<<std::endl;}
  output.close();epoch_output.close();if(!output||!epoch_output)s.fail("epoch UART output write");
  std::cout<<"ACTUAL_UART_DYNAMIC_RESULT_CRC_PASS epoch="<<epoch<<" pages="<<(has_face&&!compact?33:1)<<" bytes="<<(has_face&&!compact?2112:64)<<std::endl;
  std::cout<<"RESIDENT_EPOCH_PASS epoch="<<epoch<<" interval_cycles="<<(s.npucycles-epoch_start)<<" command="<<(s.top.command_index+1)<<" checks="<<checks<<std::endl;
  if(epoch+1<epochs){
   auto before=s.mem;
   s.control_uart(8,epoch,++s.request_sequence);
   auto session=s.control_uart(7,0,++s.request_sequence);
   if(session.size()!=64)s.fail("session payload");uint32_t generation=0;
   for(unsigned k=0;k<4;k++)generation|=uint32_t(session[8+k])<<(8*k);
   if(generation!=epoch+1||!(session[12]&1)||s.top.finished)s.fail("application did not rearm to next BOOT");
   if(s.mem!=before||s.rleft||s.wleft||!s.pending.empty())s.fail("REARM changed DDR or skipped physical drain");
   std::cout<<"ACTUAL_UART_REARM_RESIDENT_DDR_PASS generation="<<generation<<" reuploaded_model_bytes=0"<<std::endl;
   if(epoch==0||epoch==2)s.install_gallery(epoch+1,uint32_t(s.gallery_records.size()));
   epoch_start=s.npucycles;
  }
  }
  auto final_memory=s.mem;s.control_uart(8,4,++s.request_sequence);
  auto end_session=s.control_uart(7,0,++s.request_sequence);auto end_video=s.video_control(10,0);
  if(Sim::word(end_session,2)!=5||(Sim::word(end_session,3)&5)!=5||Sim::word(end_video,2)&(1<<2)||s.mem!=final_memory||s.rleft||s.wleft||!s.pending.empty())s.fail("final release/drain");
  std::cout<<"MULTI_PERSON_HDMI_APPLICATION_PASS epochs=5 people=3 rejected_unenrolled=2 recognized_enrolled=3 final_generation=5 full15D8R=0 board=0"<<std::endl;

  if(std::getenv("PW_SWITCHBACK")){
   auto expected=Sim::read_file("epoch_4_actual_uart_result.bin",64);
   pw_coremark(s,5,1,1,true);pw_coremark(s,6,2,1,false);pw_coremark(s,7,1,3,false);
   pw_face_return(s,8,expected);
  }
 }catch(const std::exception&e){std::cerr<<"CPU_GRAPH_RTL_FAIL "<<e.what()<<std::endl;return 1;}
}
