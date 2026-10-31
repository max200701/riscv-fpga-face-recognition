// Private extension of the frozen package ABI: 0=line, 1=CRC, 2=write32, 3=fixed Q16 hardware warp,
// 4=anchor-table scan, 5=fetch 8 scanned indices (claude_c02).
// Write data is captured atomically with the command. Release completion uses
// a matching posted tag AFTER the final upstream W handshake. The board client
// withholds that final handshake until HMIC accepts the complete burst.
// WRITE_READBACK=1 is diagnostic only; reply_data remains the original payload
// on successful writes, preserving the CPU ABI without an extra DDR read.
module package_cpu_bridge # (parameter WATCHDOG=4000000,VERIFY_LIMIT=4096,WRITE_READBACK=0)(
 input wire arst,cpu_clk,npu_clk,bus_valid,bus_write,input wire[11:0]bus_addr,
 input wire[31:0]bus_wdata,input wire[3:0]bus_wstrb,
 output wire bus_ready,bus_error,output reg[31:0]bus_rdata,
 output wire rd_valid,input wire rd_ready,output wire[31:0]rd_addr,output wire[4:0]rd_beats,
 input wire r_valid,output wire r_ready,input wire[255:0]r_data,input wire r_last,r_error,
 output wire out_valid,input wire out_ready,output wire[31:0]out_addr,out_strb,out_tag,
 output wire[255:0]out_data,output wire out_last,
 input wire posted_valid,output wire posted_ready,input wire[31:0]posted_tag,
 input wire transport_fault,output reg fault
);
 reg[31:0]address,length,expected;reg[255:0]payload;
 wire[5:0]offset=bus_addr[5:0];wire select=bus_addr[11:6]==6'h20;
 wire door=offset==0,pop=offset==20,args=offset==8||offset==12||offset==16;
 wire readable=offset==4||offset==20||offset==24||offset>=32;
 wire qwready,qvalid,qready,sv,sready,sout;wire[354:0]qdata;wire[291:0]sdata;
 wire raw_error=!select||offset[1:0]!=0||(bus_write?(!door&&!pop&&!args&&offset<32||bus_wstrb!=15||(door&&bus_wdata>5)):!readable);
 // Decode before local commit. The upstream slice holds its request until READY.
 reg checked,checked_error,checked_door,checked_pop;
 reg[2:0]arg_write;
 reg[7:0]payload_write;
 reg[31:0]checked_data;
 assign bus_error=checked&&checked_error;
 assign bus_ready=!arst&&checked&&(checked_error||!checked_door||qwready);
 wire accept=bus_valid&&bus_ready&&!checked_error;
 wire push=accept&&checked_door;
 wire take=accept&&checked_pop;
 always @(posedge cpu_clk or posedge arst)begin
  if(arst)begin checked<=0;checked_error<=0;checked_door<=0;checked_pop<=0;
   arg_write<=0;payload_write<=0;checked_data<=0;end
  else if(checked)begin
   if(!bus_valid||bus_ready)checked<=0;
  end else if(bus_valid)begin
   checked<=1;checked_error<=raw_error;checked_data<=bus_wdata;
   checked_door<=bus_write&&door;checked_pop<=bus_write&&pop;
   arg_write<={bus_write&&offset==16,bus_write&&offset==12,bus_write&&offset==8};
   payload_write<=(bus_write&&offset>=32)?(8'b1<<offset[4:2]):8'b0;
  end
 end
 always @*begin
  bus_rdata=0;
  if(offset==4)bus_rdata={30'b0,sout,qwready};
  else if(offset==20)bus_rdata={28'b0,sdata[291:288]};
  else if(offset==24)bus_rdata=sdata[287:256];
  else if(offset>=32)bus_rdata=sdata[{offset[4:2],5'b0}+:32];
 end
 always @(posedge cpu_clk or posedge arst)begin
  if(arst)begin address<=0;length<=0;expected<=0;end
  else if(accept)begin
   if(arg_write[0])address<=checked_data;
   if(arg_write[1])length<=checked_data;
   if(arg_write[2])expected<=checked_data;
  end
 end
 genvar word_lane;
 generate for(word_lane=0;word_lane<8;word_lane=word_lane+1)begin:argument_words
  always @(posedge cpu_clk or posedge arst)
   if(arst)payload[32*word_lane+:32]<=0;
   else if(accept&&payload_write[word_lane])payload[32*word_lane+:32]<=checked_data;
 end endgenerate
 package_mailbox #(.WIDTH(355)) requests(arst,cpu_clk,push,qwready,{checked_data[2:0],payload,expected,length,address},npu_clk,qvalid,qready,qdata);
 localparam IDLE=0,READ_LAUNCH=1,READ_WAIT=2,WRITE=3,POST=4,VERIFY_LAUNCH=5,VERIFY_WAIT=6,REPLY=7,WARP_LAUNCH=8,WARP_WAIT=9,VERIFY_CHECK=10;
 reg[3:0]state;reg warp_owned;reg[1:0]warp_step;reg[31:0]warp_desc;reg[2:0]mode;reg[31:0]addr,bytes,crc_expected,serial,active_tag,timer,tries;
 reg[7:0]verify_equal;reg[3:0]verify_error;reg[255:0]verify_data;integer verify_word;
 reg[255:0]write_data,reply_data;reg[31:0]reply_crc;reg[3:0]error;
 wire cv,cr,rv,rr;
 assign cv=state==READ_LAUNCH||state==VERIFY_LAUNCH;
 wire[255:0]data;wire[31:0]crc;wire[3:0]read_error;
 wire reader_rdv,reader_rr;wire[31:0]reader_ra;wire[4:0]reader_rn;
 wire warp_rdv,warp_rr,warp_ov,warp_ol,warp_pr,warp_ready,warp_done;
 wire[31:0]warp_ra,warp_oa,warp_os,warp_ot;wire[4:0]warp_rn;wire[255:0]warp_od;wire[3:0]warp_error;
 assign rd_valid=warp_owned?warp_rdv:reader_rdv;
 assign rd_addr=warp_owned?warp_ra:reader_ra;assign rd_beats=warp_owned?warp_rn:reader_rn;
 assign r_ready=warp_owned?warp_rr:reader_rr;
 retina_warp_q16 #(.TIMEOUT_CYCLES(WATCHDOG),.CHECK_AUTHORITY(1)) warp(
  .authority_source(32'h01800000),.authority_bytes(32'd3686400),.authority_dest(32'h01c00000),
  .authority_terms(32'h0b100000),.authority_desc(32'h0b100800),.cmd_tag(active_tag),
  .clk(npu_clk),.rst(arst),.dma_fault(transport_fault||fault),.cmd_valid(state==WARP_LAUNCH&&!fault),
  .cmd_desc_addr(warp_desc),.cmd_ready(warp_ready),.cmd_done(warp_done),.error(warp_error),
  .rd_valid(warp_rdv),.rd_ready(rd_ready&&warp_owned),.rd_addr(warp_ra),.rd_beats(warp_rn),
  .r_valid(r_valid&&warp_owned),.r_ready(warp_rr),.r_data(r_data),.r_last(r_last),.r_error(r_error),
  .out_valid(warp_ov),.out_ready(out_ready&&warp_owned),.out_data(warp_od),.out_addr(warp_oa),
  .out_strb(warp_os),.out_tag(warp_ot),.out_last(warp_ol),
  .posted_valid(posted_valid&&warp_owned),.posted_ready(warp_pr),.posted_tag(posted_tag),
  .cycles(),.read_requests(),.cache_misses(),.read_bytes(),.write_bytes(),.peak_requests());
 assign qready=!arst&&state==IDLE;
 assign rr=state==READ_WAIT||state==VERIFY_WAIT;
 package_reader reader(.clk(npu_clk),.rst(arst),.cmd_valid(cv&&!fault),.cmd_ready(cr),
  .cmd_crc(state==READ_LAUNCH&&mode==1),.cmd_scan(state==READ_LAUNCH&&mode==4),.cmd_fetch(state==READ_LAUNCH&&mode==5),.cmd_addr(addr),.cmd_bytes((mode==2||mode==3)?32'd32:bytes),.cmd_expected(crc_expected),
  .rsp_valid(rv),.rsp_ready(rr),.rsp_error(read_error),.rsp_data(data),.rsp_crc(crc),
  .rd_valid(reader_rdv),.rd_ready(rd_ready&&!warp_owned),.rd_addr(reader_ra),.rd_beats(reader_rn),
  .r_valid(r_valid&&!warp_owned),.r_ready(reader_rr),.r_data(r_data),.r_last(r_last),.r_error(r_error));
 assign out_valid=!arst&&!fault&&(warp_owned?warp_ov:state==WRITE);
 assign out_addr=warp_owned?warp_oa:addr;assign out_strb=warp_owned?warp_os:32'hffffffff;assign out_tag=warp_owned?warp_ot:active_tag;assign out_data=warp_owned?warp_od:write_data;assign out_last=warp_owned?warp_ol:1;
 assign posted_ready=!arst&&(warp_owned?warp_pr:(state==POST||fault));
 assign sv=!arst&&state==REPLY;
 package_mailbox #(.WIDTH(292)) responses(arst,npu_clk,sv,sready,{error,reply_crc,reply_data},cpu_clk,sout,take,sdata);
 wire progress=(warp_owned&&((rd_valid&&rd_ready)||(r_valid&&r_ready)))||(cv&&cr)||(rv&&rr)||(out_valid&&out_ready)||(posted_valid&&posted_ready);
 // Register activity before the 32-bit watchdog reset tree. This moves only
 // inactivity observation by one edge; physical transfers and ACKs stay immediate.
 reg timer_clear;
 always @(posedge npu_clk)begin
  if(arst)timer_clear<=1;
  else timer_clear<=state==IDLE||state==REPLY||progress;
 end
 task fail(input[3:0]code);begin error<=code;fault<=1;state<=REPLY;end endtask
 always @(posedge npu_clk)begin
  if(arst)begin state<=IDLE;warp_owned<=0;warp_step<=0;warp_desc<=0;mode<=0;addr<=0;bytes<=0;crc_expected<=0;serial<=0;active_tag<=0;timer<=0;tries<=0;write_data<=0;reply_data<=0;reply_crc<=0;error<=0;fault<=0;end
  else begin
   if(timer_clear)timer<=0;else timer<=timer+1'b1;
   case(state)
    IDLE:if(qvalid)begin
     mode<=qdata[354:352];addr<=qdata[31:0];bytes<=qdata[63:32];crc_expected<=qdata[95:64];write_data<=qdata[351:96];
     reply_data<=0;reply_crc<=0;error<=0;tries<=0;
     if(fault)begin error<=5;state<=REPLY;end
     else if(qdata[354:352]==2)begin
      if(qdata[31:30]!=0||qdata[4:0]!=0||qdata[63:32]!=32||serial==32'hffffffff)begin error<=1;state<=REPLY;end
      else begin active_tag<=serial+1'b1;serial<=serial+1'b1;state<=WRITE;end
     end else if(qdata[354:352]==3)begin
      if(qdata[31:0]!=32'h0b100800||qdata[63:32]!=128||serial>=32'hfffffffd)begin error<=1;state<=REPLY;end
      else begin
       // Force a known old fence value even after a cold reset with retained DDR.
       warp_desc<=qdata[31:0];warp_step<=0;warp_owned<=0;
       addr<=32'h0b100900;write_data<=0;
       active_tag<=serial+1'b1;serial<=serial+1'b1;state<=WRITE;
      end
     end else state<=READ_LAUNCH;
    end
    READ_LAUNCH:if(cr)state<=READ_WAIT;
    READ_WAIT:if(rv)begin reply_data<=data;reply_crc<=crc;error<=read_error;state<=REPLY;if(read_error==4||read_error==5)fault<=1;end
    WRITE:if(out_ready)state<=POST;
    POST:if(posted_valid)begin
     if(posted_tag!=active_tag)fail(6);
     else if(WRITE_READBACK)state<=VERIFY_LAUNCH;
     else if(mode==3&&warp_step==0)begin
      warp_step<=1;warp_owned<=1;addr<=warp_desc;
      active_tag<=serial+1'b1;serial<=serial+1'b1;state<=WARP_LAUNCH;
     end else begin reply_data<=write_data;state<=REPLY;end
    end
    VERIFY_LAUNCH:if(cr)state<=VERIFY_WAIT;
    VERIFY_WAIT:if(rv)begin
     for(verify_word=0;verify_word<8;verify_word=verify_word+1)
      verify_equal[verify_word]<=data[32*verify_word+:32]==write_data[32*verify_word+:32];
     verify_error<=read_error;verify_data<=data;state<=VERIFY_CHECK;
    end
    VERIFY_CHECK:begin
     if(verify_error)fail(verify_error);
     else if(&verify_equal)begin
      if(mode==3&&warp_step==0)begin
       warp_step<=1;warp_owned<=1;addr<=warp_desc;
       active_tag<=serial+1'b1;serial<=serial+1'b1;state<=WARP_LAUNCH;
      end else begin reply_data<=verify_data;state<=REPLY;end
     end
     else if(tries==VERIFY_LIMIT-1)fail(7);
     else begin tries<=tries+1'b1;state<=VERIFY_LAUNCH;end
    end
    WARP_LAUNCH:if(warp_ready)state<=WARP_WAIT;
    WARP_WAIT:begin
     // A matching old crop line cannot certify completion of a repeated write.
     // Emit a changing commit marker AFTER every crop write through the SAME writer.
     if(warp_done)begin
      if(warp_error)fail(warp_error);
      else begin
       warp_owned<=0;warp_step<=2;tries<=0;addr<=32'h0b100900;
       active_tag<=serial+1'b1;serial<=serial+1'b1;
       write_data<={32'h57525033,32'd150528,32'h01800000,32'h01c00000,64'b0,32'b0,serial+32'd1};
       state<=WRITE;
      end
     end
    end
    REPLY:if(sready)state<=IDLE;
   endcase
   if(!fault&&((state!=IDLE&&state!=REPLY&&timer==WATCHDOG-1&&!timer_clear)||transport_fault||(posted_valid&&!warp_owned&&state!=POST)))fail(8);
  end
 end
endmodule
