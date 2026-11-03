// One request in flight, FBD1 packets. Host must wait for the complete reply.
// Request header: magic4/version1/op1/status1/flags1/seq4/address4/length4/CRC4.
// CRC32 covers the first 20 header bytes plus WRITE payload. Responses cover
// the first 20 header bytes plus reply payload. All integers little endian.
// Payload <=512 B. WRITE ACK requires memory B after verified read visibility.
module demo_packet_endpoint #(
 parameter integer RECEIVE_TIMEOUT=27000000,
 parameter integer MEMORY_TIMEOUT=27000000
)(
 input wire clk,rst,
 input wire rx_valid,output wire rx_ready,input wire[7:0]rx_data,
 output wire tx_valid,input wire tx_ready,output wire[7:0]tx_data,
 input wire app_running,start_allowed,memory_drained,
 input wire rearm_allowed,rearm_ack,result_has_face,
 input wire video_arm_allowed,video_stop_allowed,video_recover_allowed,memory_read_allowed,memory_write_allowed,
 input wire[31:0]video_next_generation,video_held_generation,
 input wire[511:0]video_status_words,
 output reg video_arm_pulse,video_stop_pulse,video_recover_pulse,
 output reg[31:0]video_frame,video_generation,
 input wire[31:0]session_generation,output reg rearm_pulse,
 input wire[511:0]status_words,result_words,input wire result_ready,output wire[5:0]result_page,output reg start_pulse,
 output reg[1:0] application_mode,output reg[31:0] benchmark_iterations,
 output reg link_fault,output reg[31:0]accepted_writes,rejected_packets,
 output wire p_rd_valid,input wire p_rd_ready,output wire[31:0]p_rd_addr,
 output wire[6:0]p_rd_beats,output wire[63:0]p_rd_token,output wire[2:0]p_rd_owner,
 input wire p_r_valid,output wire p_r_ready,input wire[255:0]p_r_data,
 input wire[63:0]p_r_token,input wire[6:0]p_r_index,input wire p_r_last,p_r_error,
 output wire p_wr_valid,input wire p_wr_ready,output wire[31:0]p_wr_addr,
 output wire[6:0]p_wr_beats,output wire[63:0]p_wr_token,output wire[2:0]p_wr_owner,
 output wire p_w_valid,input wire p_w_ready,output wire[255:0]p_w_data,
 output wire[31:0]p_w_strb,output wire p_w_last,
 input wire p_b_valid,output wire p_b_ready,input wire[63:0]p_b_token,input wire p_b_error
);
 localparam SYNC=0,HEADER=1,PARSE=2,PAYLOAD=3,DISPATCH=4,
  READ_CMD=5,READ_DATA=6,WRITE_CMD=7,WRITE_DATA=8,WRITE_REPLY=9,
  MAKE_REPLY=10,REPLY_CRC=11,TRANSMIT=12,STATUS_LOW=13,STATUS_HIGH=14,REARM_WAIT=15,SNAPSHOT=16,VALIDATE_REQUEST=17;
 localparam OK=0,BAD_CRC=1,BAD_FORMAT=2,BAD_RANGE=3,BUSY=4,MEMORY_ERROR=5,
  NOT_READY=6,SEQUENCE_ERROR=7;
 reg[4:0]state;
 reg[3:0]snapshot_kind;
 reg[9:0]payload_last;
 reg request_bad_crc,request_replay,request_old,request_changed,geometry_q;
 (* syn_preserve=1 *) reg[5:0]result_page_q;
 reg[1:0]sync_index;
 reg[4:0]header_index;
 reg[191:0]header;
 reg[31:0]crc,request_crc,watchdog;
 reg[9:0]byte_index,reply_length,tx_index,crc_index;
 reg[7:0]crc_byte_q;reg crc_q_valid,crc_q_last;
 reg[4:0]beat_index;
 reg[7:0]reply_status;
 reg[32:0]result_pages_seen;
 reg summary_acknowledged;
 wire results_acknowledged=result_pages_seen[0]&&(summary_acknowledged||!result_has_face||&result_pages_seen);
 wire[511:0]session_words={256'b0,32'd32,31'b0,result_has_face,result_pages_seen[31:0],31'b0,result_pages_seen[32],
  {28'b0,results_acknowledged,memory_drained,rearm_allowed,start_allowed},session_generation,32'd1,32'h31534553};
 // One shared read address per byte bank. Do not expand byte writes to FFs.
 reg have_last,cache_response,replay_response;
 wire[9:0]payload_tx_index=tx_index-24;
 wire[7:0]opcode=header[47:40];
 wire[511:0]status_snapshot;
 // The header opcode is stable for several cycles before SNAPSHOT. Register
 // one-hot source choice locally, then capture all words on the SAME edge.
 // This remains one atomic snapshot; the UART reply does not gate COMMIT.
 genvar sw;
 generate for(sw=0;sw<16;sw=sw+1)begin:snapshot_word
  (* syn_preserve=1 *) reg[3:0]select_q;
  reg[31:0]value;
  always @(posedge clk)begin
   select_q<={opcode==10,opcode==7,opcode==6,(opcode==1||opcode==5)};
   if(!rst&&state==SNAPSHOT)
    value<=({32{select_q[0]}}&status_words[sw*32+:32])|
           ({32{select_q[1]}}&result_words[sw*32+:32])|
           ({32{select_q[2]}}&session_words[sw*32+:32])|
           ({32{select_q[3]}}&video_status_words[sw*32+:32]);
  end
  assign status_snapshot[sw*32+:32]=value;
  // synthesis translate_off
  always @(posedge clk)if(!rst&&state==SNAPSHOT&&select_q!==snapshot_kind)
   $fatal(1,"QD_SNAPSHOT_SELECTION_NOT_READY");
  // synthesis translate_on
 end endgenerate
 reg[255:0]cached_payload[0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
 reg[9:0]crc_payload_index;
 reg[255:0]crc_word_q;reg[7:0]crc_header_q;reg[4:0]crc_lane_q;
 reg crc_select_valid,crc_select_last,crc_select_header,crc_fetch_last;
 wire[3:0]payload_read_address=state==DISPATCH?4'b0:state==WRITE_DATA?beat_index[3:0]:
  state==REPLY_CRC?crc_payload_index[8:5]:payload_tx_index[8:5];
 wire payload_rx_write=!rst&&state==PAYLOAD&&rx_valid&&rx_ready;
 wire payload_read_write=!rst&&state==READ_DATA&&p_r_valid&&p_r_ready;
 wire payload_status_write=!rst&&(state==STATUS_LOW||state==STATUS_HIGH);
 wire[3:0]payload_write_address=payload_status_write?{3'b0,state==STATUS_HIGH}:
  payload_read_write?beat_index[3:0]:byte_index[8:5];
 wire[255:0]payload_parallel_data=payload_status_write?
  (state==STATUS_HIGH?status_snapshot[511:256]:status_snapshot[255:0]):p_r_data;
 wire[255:0]payload_word;
 genvar bank;
 generate for(bank=0;bank<32;bank=bank+1)begin: payload_bank
  reg[7:0]mem[0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
  wire we=payload_read_write||payload_status_write||(payload_rx_write&&byte_index[4:0]==bank);
  wire[7:0]din=payload_rx_write?rx_data:payload_parallel_data[8*bank+:8];
  always @(posedge clk)if(we)mem[payload_write_address]<=din;
  assign payload_word[8*bank+:8]=mem[payload_read_address];
 end endgenerate
 // Copy each complete response word while its CRC is already being scanned.
 // Bad-CRC requests may overwrite RX storage but never the cached reply.
 always @(posedge clk)if(!rst&&state==REPLY_CRC&&!crc_fetch_last&&cache_response&&crc_index>=20&&crc_payload_index[4:0]==0)
  cached_payload[crc_payload_index[8:5]]<=payload_word;
 reg[191:0]reply_header,cached_reply;
 reg[191:0]last_request;
 reg[9:0]cached_length;
 wire[31:0]seq=header[95:64],address=header[127:96],length=header[159:128];
 assign result_page=result_page_q;
 wire[63:0]token={32'hb007d001,seq};
 function automatic[31:0]crc_byte(input[31:0]v,input[7:0]b);
  reg[31:0]x;integer k;begin x=v^{24'b0,b};for(k=0;k<8;k=k+1)x=(x>>1)^(x[0]?32'hedb88320:0);crc_byte=x;end
 endfunction
 wire geometry=length>=32&&length<=512&&length[4:0]==0&&address[4:0]==0&&address[31:30]==0&&({1'b0,address[11:0]}+{3'b0,length[9:0]}<=4096);
 wire good_frame=header[31:0]==32'h31444246&&header[39:32]==1&&header[63:48]==0;
 // QI: fields settle at byte 7; PARSE occurs after byte 23. No added wait.
 (* syn_preserve=1 *) reg good_frame_q;
 always @(posedge clk)good_frame_q<=good_frame;
 wire receiving=state==SYNC||state==HEADER||state==PAYLOAD;
 assign rx_ready=!rst&&receiving;
 assign tx_valid=!rst&&state==TRANSMIT;
 assign tx_data=tx_index<24?reply_header[tx_index*8+:8]:replay_response?cached_payload[payload_tx_index[8:5]][payload_tx_index[4:0]*8+:8]:payload_word[payload_tx_index[4:0]*8+:8];
 assign p_rd_valid=!rst&&!link_fault&&state==READ_CMD;
 assign p_rd_addr=address;assign p_rd_beats=length[11:5];assign p_rd_token=token;assign p_rd_owner=0;
 assign p_r_ready=!rst&&state==READ_DATA;
 assign p_wr_valid=!rst&&!link_fault&&state==WRITE_CMD;
 assign p_wr_addr=address;assign p_wr_beats=length[11:5];assign p_wr_token=token;assign p_wr_owner=0;
 assign p_w_valid=!rst&&!link_fault&&state==WRITE_DATA;
 assign p_w_data=payload_word;assign p_w_strb=32'hffffffff;
 assign p_w_last=beat_index+1'b1==length[9:5];
 assign p_b_ready=!rst&&state==WRITE_REPLY;
 wire mem_wait=(state>=READ_CMD&&state<=WRITE_REPLY)||state==REARM_WAIT;
 wire mem_progress=(p_rd_valid&&p_rd_ready)||(p_r_valid&&p_r_ready)||(p_wr_valid&&p_wr_ready)||(p_w_valid&&p_w_ready)||(p_b_valid&&p_b_ready);
 wire[7:0]crc_reply_byte=crc_index<20?reply_header[crc_index*8+:8]:payload_word[crc_payload_index[4:0]*8+:8];

 task automatic respond(input[7:0]status,input[9:0]bytes);
  begin reply_status<=status;reply_length<=bytes;state<=MAKE_REPLY;if(status!=OK)rejected_packets<=rejected_packets+1;end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   application_mode<=0;benchmark_iterations<=0;
   state<=SYNC;sync_index<=0;header_index<=0;header<=0;crc<=32'hffffffff;request_crc<=0;watchdog<=0;
   byte_index<=0;reply_length<=0;tx_index<=0;crc_index<=0;crc_byte_q<=0;crc_q_valid<=0;crc_q_last<=0;crc_payload_index<=0;crc_select_valid<=0;crc_select_last<=0;crc_fetch_last<=0;beat_index<=0;reply_status<=0;reply_header<=0;
   start_pulse<=0;rearm_pulse<=0;video_arm_pulse<=0;video_stop_pulse<=0;video_recover_pulse<=0;result_pages_seen<=0;link_fault<=0;accepted_writes<=0;rejected_packets<=0;
   video_frame<=0;video_generation<=0;cached_reply<=0;last_request<=0;have_last<=0;cache_response<=0;cached_length<=0;replay_response<=0;
   snapshot_kind<=0;payload_last<=0;result_page_q<=0;geometry_q<=0;request_bad_crc<=1;request_replay<=0;request_old<=0;request_changed<=0;
   summary_acknowledged<=0;
  end else begin
   start_pulse<=0;rearm_pulse<=0;video_arm_pulse<=0;video_stop_pulse<=0;video_recover_pulse<=0;
   if((rx_valid&&rx_ready)||mem_progress||(!receiving&&!mem_wait)||state==SYNC)watchdog<=0;
   else watchdog<=watchdog+1'b1;
   if(rx_valid&&rx_ready)begin
    if(state==SYNC)begin
     case(sync_index)
      0:if(rx_data==8'h46)begin sync_index<=1;header[7:0]<=rx_data;crc<=crc_byte(32'hffffffff,rx_data);end
      1:if(rx_data==8'h42)begin sync_index<=2;header[15:8]<=rx_data;crc<=crc_byte(crc,rx_data);end else sync_index<=0;
      2:if(rx_data==8'h44)begin sync_index<=3;header[23:16]<=rx_data;crc<=crc_byte(crc,rx_data);end else sync_index<=0;
      3:if(rx_data==8'h31)begin header[31:24]<=rx_data;crc<=crc_byte(crc,rx_data);header_index<=4;state<=HEADER;sync_index<=0;end else sync_index<=0;
     endcase
    end else if(state==HEADER)begin
     header[header_index*8+:8]<=rx_data;
     if(header_index<20)crc<=crc_byte(crc,rx_data);
     if(header_index==23)state<=PARSE;else header_index<=header_index+1'b1;
    end else if(state==PAYLOAD)begin
     crc<=crc_byte(crc,rx_data);
     if(byte_index==payload_last)state<=VALIDATE_REQUEST;else byte_index<=byte_index+1'b1;
    end
   end
   case(state)
    PARSE:begin
     cache_response<=0;replay_response<=0;payload_last<=length-1;geometry_q<=geometry;result_page_q<=address[5:0];
     if(!good_frame_q||length>512)respond(BAD_FORMAT,0);
     else if((opcode==3||opcode==9||opcode==14)&&length!=0)begin byte_index<=0;state<=PAYLOAD;end
     else state<=VALIDATE_REQUEST;
    end
    VALIDATE_REQUEST:begin
     // Header, CRC and last_request are immutable until this request completes.
     request_bad_crc<=~crc!=header[191:160];
     request_replay<=have_last&&seq==last_request[95:64];
     request_old<=have_last&&seq<last_request[95:64];
     request_changed<=header!=last_request;
     state<=DISPATCH;
    end
    DISPATCH:begin
     if(request_bad_crc)respond(BAD_CRC,0);
     else if(request_replay)begin
      if(request_changed)respond(SEQUENCE_ERROR,0);
      else begin reply_header<=cached_reply;reply_length<=cached_length;tx_index<=0;replay_response<=1;state<=TRANSMIT;end
     end else if(request_old)respond(SEQUENCE_ERROR,0);
     else begin
      cache_response<=1;
      case(opcode)
       1,5:if(length!=0)respond(BAD_FORMAT,0);else begin snapshot_kind<=1;state<=SNAPSHOT;end
       6:if(length!=0||address>32)respond(BAD_FORMAT,0);else if(!result_ready)respond(NOT_READY,0);else begin snapshot_kind<=2;state<=SNAPSHOT;end
       7:if(length!=0||address!=0)respond(BAD_FORMAT,0);else begin snapshot_kind<=4;state<=SNAPSHOT;end
       8:if(length!=0)respond(BAD_FORMAT,0);
         else if(address!=session_generation)respond(SEQUENCE_ERROR,0);
         else if(link_fault||!rearm_allowed||!results_acknowledged||!memory_drained)respond(NOT_READY,0);
         else begin rearm_pulse<=1;state<=REARM_WAIT;end
       9:if(length!=16||payload_word[127:64]!=0)respond(BAD_FORMAT,0);
         else if(address!=session_generation||payload_word[63:32]!=video_next_generation)respond(SEQUENCE_ERROR,0);
         
         else if(link_fault||!video_arm_allowed)respond(NOT_READY,0);
         else begin video_frame<=payload_word[31:0];video_generation<=payload_word[63:32];video_arm_pulse<=1;respond(OK,0);end
       10:if(length!=0||address!=0)respond(BAD_FORMAT,0);else begin snapshot_kind<=8;state<=SNAPSHOT;end
       // Explicit summary-only consumption. Enrollment/diagnostics still read
       // all 33 pages. Do not pretend the skipped embedding pages were read.
       13:if(length!=0)respond(BAD_FORMAT,0);
         else if(address!=session_generation)respond(SEQUENCE_ERROR,0);
         else if(link_fault||!rearm_allowed||!memory_drained||!result_pages_seen[0])respond(NOT_READY,0);
         else begin summary_acknowledged<=1;respond(OK,0);end
       11,12:if(length!=0)respond(BAD_FORMAT,0);
         else if(address!=video_held_generation)respond(SEQUENCE_ERROR,0);
         
         else if(link_fault||(opcode==11?!video_stop_allowed:!video_recover_allowed))respond(NOT_READY,0);
         else begin if(opcode==11)video_stop_pulse<=1;else video_recover_pulse<=1;respond(OK,0);end
       // Idle-only, generation-bound stable configuration. Same UI domain;
       // CPU reads it via the existing MMIO CDC, never an asynchronous bus.
       14:if(length!=16||payload_word[127:64]!=0||payload_word[31:0]>2||
             (payload_word[31:0]==0?payload_word[63:32]!=0:
              (payload_word[63:32]==0||payload_word[63:32]>10000)))respond(BAD_FORMAT,0);
         else if(address!=session_generation)respond(SEQUENCE_ERROR,0);
         else if(app_running)respond(BUSY,0);
         else if(link_fault||!start_allowed||!memory_write_allowed||!memory_drained)respond(NOT_READY,0);
         else begin application_mode<=payload_word[1:0];benchmark_iterations<=payload_word[63:32];respond(OK,0);end
       2,3:begin
        if(app_running)respond(BUSY,0);
        else if(link_fault||!memory_drained||(opcode==2?!memory_read_allowed:!memory_write_allowed))respond(NOT_READY,0);
        else if(!geometry_q)respond(BAD_RANGE,0);
        else begin beat_index<=0;state<=opcode==2?READ_CMD:WRITE_CMD;end
       end
       4:if(length!=0)respond(BAD_FORMAT,0);
         else if(address!=session_generation)respond(SEQUENCE_ERROR,0);
         else if(app_running)respond(BUSY,0);
         else if(link_fault||!start_allowed||!memory_drained)respond(NOT_READY,0);
         else begin start_pulse<=1;respond(OK,0);end
       default:respond(BAD_FORMAT,0);
      endcase
     end
    end
    SNAPSHOT:begin
     // Dispatch validation finishes before this atomic wide capture.
     // Word banks capture here using the same atomic snapshot edge.
     state<=STATUS_LOW;
    end
    STATUS_LOW:state<=STATUS_HIGH;
    STATUS_HIGH:respond(OK,64);
    REARM_WAIT:if(rearm_ack)begin result_pages_seen<=0;summary_acknowledged<=0;respond(OK,0);end
    READ_CMD:if(p_rd_valid&&p_rd_ready)state<=READ_DATA;
    READ_DATA:if(p_r_valid&&p_r_ready)begin
     if(p_r_error||p_r_token!=token||p_r_index!={2'b0,beat_index}||p_r_last!=(beat_index+1'b1==length[9:5]))begin link_fault<=1;respond(MEMORY_ERROR,0);end
     else begin
      if(p_r_last)respond(OK,length[9:0]);else beat_index<=beat_index+1'b1;
     end
    end
    WRITE_CMD:if(p_wr_valid&&p_wr_ready)state<=WRITE_DATA;
    WRITE_DATA:if(p_w_valid&&p_w_ready)begin if(p_w_last)state<=WRITE_REPLY;else beat_index<=beat_index+1'b1;end
    WRITE_REPLY:if(p_b_valid&&p_b_ready)begin
     if(p_b_error||p_b_token!=token)begin link_fault<=1;respond(MEMORY_ERROR,0);end
     else begin accepted_writes<=accepted_writes+1'b1;respond(OK,0);end
    end
    MAKE_REPLY:begin
     reply_header<={32'b0,{22'b0,reply_length},address,seq,8'b0,reply_status,(opcode|8'h80),8'd1,32'h31444246};
     crc<=32'hffffffff;crc_index<=0;crc_payload_index<=0;crc_q_valid<=0;crc_q_last<=0;
     crc_select_valid<=0;crc_select_last<=0;crc_fetch_last<=0;state<=REPLY_CRC;
    end
    REPLY_CRC:begin
     // Address -> bank output capture -> byte select -> CRC. Valid and last
     // follow each byte; no external transaction or writer ownership changes.
     crc_select_valid<=!crc_fetch_last;
     if(!crc_fetch_last)begin
      crc_word_q<=payload_word;crc_header_q<=reply_header[crc_index*8+:8];
      crc_lane_q<=crc_payload_index[4:0];crc_select_header<=crc_index<20;
      crc_select_last<=crc_index+1==20+reply_length;
      if(crc_index+1==20+reply_length)crc_fetch_last<=1;
      else begin
       crc_index<=crc_index+1'b1;
       if(crc_index>=20)crc_payload_index<=crc_payload_index+1'b1;
      end
     end
     crc_q_valid<=crc_select_valid;
     if(crc_select_valid)begin
      crc_byte_q<=crc_select_header?crc_header_q:crc_word_q[crc_lane_q*8+:8];
      crc_q_last<=crc_select_last;
     end
     if(crc_q_valid)begin
      crc<=crc_byte(crc,crc_byte_q);
      if(crc_q_last)begin
       reply_header[191:160]<=~crc_byte(crc,crc_byte_q);tx_index<=0;state<=TRANSMIT;
       if(cache_response)begin
        last_request<=header;have_last<=1;cached_reply<={~crc_byte(crc,crc_byte_q),reply_header[159:0]};cached_length<=reply_length;
       end
      end
     end
    end
    TRANSMIT:if(tx_valid&&tx_ready)begin
     if(tx_index+1==24+reply_length)begin
      if(opcode==6&&reply_header[55:48]==OK&&reply_length==64)result_pages_seen[address[5:0]]<=1;
      state<=SYNC;sync_index<=0;watchdog<=0;
     end
     else tx_index<=tx_index+1'b1;
    end
    default:begin end
   endcase
   if(RECEIVE_TIMEOUT!=0&&receiving&&state!=SYNC&&watchdog>=RECEIVE_TIMEOUT)begin state<=SYNC;sync_index<=0;watchdog<=0;rejected_packets<=rejected_packets+1;end
   if(MEMORY_TIMEOUT!=0&&mem_wait&&watchdog>=MEMORY_TIMEOUT)begin link_fault<=1;respond(MEMORY_ERROR,0);end
  end
 end
endmodule
