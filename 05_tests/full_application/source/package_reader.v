// Load-time DDR line read / bulk CRC. One immutable transaction at a time.
// scan streams a 64-byte-record table and records, in ascending
// order, records whose signed word5-word4 >= SCAN_MIN (Retina logit threshold,
// same predicate as retina_decode_q16). fetch returns 8 recorded indices.
// The read transport must preserve order and report last/error for each burst.
// A transport error latches until global reset; no new command can reuse it.
module package_reader #(parameter signed [32:0] SCAN_MIN=33'sd26573)(
 input wire clk,rst,cmd_valid,output wire cmd_ready,
 input wire cmd_crc,cmd_scan,cmd_fetch,input wire[31:0]cmd_addr,cmd_bytes,cmd_expected,
 output reg rsp_valid,input wire rsp_ready,output reg[3:0]rsp_error,
 output reg[255:0]rsp_data,output reg[31:0]rsp_crc,
 output wire rd_valid,input wire rd_ready,output wire[31:0]rd_addr,output wire[4:0]rd_beats,
 input wire r_valid,output wire r_ready,input wire[255:0]r_data,input wire r_last,r_error
);
 localparam IDLE=0,REQUEST=1,RECEIVE=2,CRC_WAIT=3,REPLY=4;
 reg[2:0]state;reg[1:0]mode;reg poisoned;
 reg[25:0]issue_left; /* Remaining beats; byte tail stays in left/CRC. */
 reg[4:0]request_beats[0:3];reg[1:0]qh,qt;
 reg[2:0]outstanding;reg[4:0]response_beat;
 wire issue=rd_valid&&rd_ready;
 wire finish_burst=r_valid&&r_ready&&(response_beat+1'b1==request_beats[qh]);
 // Scan state: record index of each beat pair, pipelined compare, 8 x 32-row index banks.
 reg[23:0]scan_beat;reg[15:0]scan_count;reg sp_valid;reg[15:0]sp_index;reg signed[32:0]sp_diff;
 reg[15:0]slot0[0:31],slot1[0:31],slot2[0:31],slot3[0:31],slot4[0:31],slot5[0:31],slot6[0:31],slot7[0:31];reg[31:0]address,left,expected;reg[4:0]burst_left;
 wire[25:0]words_left=issue_left;
 wire[7:0]page_words=8'd128-{1'b0,address[11:5]};
 wire[4:0]burst=words_left<16?(words_left<page_words?words_left[4:0]:page_words[4:0]):(page_words<16?page_words[4:0]:5'd16);
 wire cv,cr,cd;wire[3:0]ce;wire[31:0]actual,consumed;wire crc_ready;
 wire accept=cmd_valid&&cmd_ready;
 wire bad=cmd_addr[31:30]!=0||cmd_addr[4:0]!=0||cmd_bytes==0||cmd_bytes>32'h40000000||
          ({1'b0,cmd_addr}+{1'b0,cmd_bytes}>33'h40000000)||(!cmd_crc&&!cmd_scan&&cmd_bytes!=32)||
          (cmd_scan&&(cmd_addr[5:0]!=0||cmd_bytes[5:0]!=0||cmd_bytes>32'h01000000));
 package_crc_stream crc(.clk(clk),.rst(rst),.start(accept&&cmd_crc&&!cmd_fetch&&!bad&&!poisoned),.cfg_bytes(cmd_bytes),.cfg_expected(cmd_expected),.ready(crc_ready),
  .in_valid(cv),.in_ready(cr),.in_data(r_data),.in_last(left<=32),.done(cd),.error(ce),.actual_crc(actual),.consumed_bytes(consumed));
 assign cmd_ready=!rst&&state==IDLE&&crc_ready;
 assign rd_valid=!rst&&(state==REQUEST||state==RECEIVE)&&issue_left!=0&&outstanding<4;
 assign rd_addr=address;assign rd_beats=burst;
 assign r_ready=!rst&&state==RECEIVE&&outstanding!=0&&(mode!=1||cr);
 assign cv=r_valid&&r_ready&&mode==1&&!r_error&&(r_last==(response_beat+1'b1==request_beats[qh]));
 wire[4:0] frow=cmd_addr[4:0];
 always @(posedge clk)begin
  if(rst)begin state<=IDLE;mode<=0;poisoned<=0;address<=0;left<=0;expected<=0;burst_left<=0;rsp_valid<=0;rsp_error<=0;rsp_data<=0;rsp_crc<=0;
   scan_beat<=0;scan_count<=0;sp_valid<=0;sp_index<=0;sp_diff<=0;
   issue_left<=0;qh<=0;qt<=0;outstanding<=0;response_beat<=0;end
  else begin
   // Pipelined scan compare; the 257th and later matches are counted, not stored.
   sp_valid<=0;
   if(sp_valid&&sp_diff>=SCAN_MIN)begin
    if(scan_count<256)case(scan_count[2:0])
     0:slot0[scan_count[7:3]]<=sp_index;1:slot1[scan_count[7:3]]<=sp_index;2:slot2[scan_count[7:3]]<=sp_index;3:slot3[scan_count[7:3]]<=sp_index;
     4:slot4[scan_count[7:3]]<=sp_index;5:slot5[scan_count[7:3]]<=sp_index;6:slot6[scan_count[7:3]]<=sp_index;default:slot7[scan_count[7:3]]<=sp_index;
    endcase
    if(scan_count!=16'hffff)scan_count<=scan_count+1'b1;
   end
   if(accept)begin
    rsp_error<=0;rsp_crc<=0;rsp_data<=0;
    if(cmd_fetch)begin
     // Indices of the last completed scan; no DDR access.
     if(poisoned||cmd_addr>31)rsp_error<=poisoned?4'd5:4'd1;
     else rsp_data<={16'b0,slot7[frow],16'b0,slot6[frow],16'b0,slot5[frow],16'b0,slot4[frow],
                     16'b0,slot3[frow],16'b0,slot2[frow],16'b0,slot1[frow],16'b0,slot0[frow]};
     rsp_valid<=1;state<=REPLY;
    end
    else if(bad||poisoned)begin rsp_error<=poisoned?4'd5:4'd1;rsp_valid<=1;state<=REPLY;end
    else begin
     mode<=cmd_scan?2'd2:{1'b0,cmd_crc};address<=cmd_addr;left<=cmd_bytes;expected<=cmd_expected;state<=REQUEST;
     issue_left<=cmd_bytes[30:5]+{25'b0,(|cmd_bytes[4:0])};qh<=0;qt<=0;outstanding<=0;response_beat<=0;
     if(cmd_scan)begin scan_beat<=0;scan_count<=0;end
    end
   end
   if(issue)begin
    request_beats[qt]<=burst;qt<=qt+1'b1;address<=address+{22'b0,burst,5'b0};
    issue_left<=issue_left-{21'b0,burst}; // burst is bounded by remaining beats.
    state<=RECEIVE;
   end
   if(issue||finish_burst)case({issue,finish_burst})
    2'b10:outstanding<=outstanding+1'b1;2'b01:outstanding<=outstanding-1'b1;default:outstanding<=outstanding;
   endcase
   if(finish_burst)begin qh<=qh+1'b1;response_beat<=0;end
   else if(r_valid&&r_ready)response_beat<=response_beat+1'b1;
   if(r_valid&&r_ready)begin
    if(r_error||r_last!=(response_beat+1'b1==request_beats[qh]))begin poisoned<=1;rsp_error<=4;rsp_valid<=1;state<=REPLY;end
    else begin
     left<=left>32?left-32:0;
     if(mode==2)begin
      scan_beat<=scan_beat+1'b1;
      if(!scan_beat[0])begin sp_valid<=1;sp_index<=scan_beat[16:1];sp_diff<=$signed({r_data[191],r_data[191:160]})-$signed({r_data[159],r_data[159:128]});end
     end
     if(mode==0)begin rsp_data<=r_data;rsp_valid<=1;state<=REPLY;end
     else if(left<=32)state<=CRC_WAIT;
     // Next request is independently issued while this burst returns.
    end
   end
   if(state==CRC_WAIT&&mode==1&&cd)begin rsp_crc<=actual;rsp_error<=ce;rsp_valid<=1;state<=REPLY;end
   // Reply after the last record's compare has been applied (two cycles after its beat).
   if(state==CRC_WAIT&&mode==2&&!sp_valid&&!(r_valid&&r_ready))begin
    rsp_data<={192'b0,9'b0,scan_beat[23:1],16'b0,scan_count};rsp_valid<=1;state<=REPLY;
   end
   if(rsp_valid&&rsp_ready)begin rsp_valid<=0;state<=IDLE;end
  end
 end
endmodule
