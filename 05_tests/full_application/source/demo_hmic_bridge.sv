// Functional board-demo adapter to Logos2 HMIC_S v1.10 (UG042003 pp31-37).
// 8 requests / 64 reserved beats, x32 DDR / 256-bit UI, a single writer.
// No vendor RREADY/WVALID/B exists. Reserve all read return storage and stage
// ALL write data before AW. The internal B notification means HMIC accepted
// the full burst with correct ID/LAST. It is NOT a vendor B or a bitwise DDR
// verification. Dependent reads use the controller's write/read ordering.
// Optional WRITE_READBACK=1 is diagnostic; verified_* counters remain zero in
// release mode. completed_writes counts correct final HMIC transfers only.
// rst requires coordinated HMIC reset; controller_quiescent must certify that
// no pre-reset return remains. No independent endpoint reset is permitted.
module demo_hmic_bridge #(
 parameter integer TIMEOUT_CYCLES=65535,
 parameter integer VERIFY_ATTEMPTS=4,
 parameter integer WRITE_READBACK=0
)(
 input wire clk,rst,ddr_init_done,controller_quiescent,
 output reg fault,output reg[7:0]fault_code,output wire drained,
 input wire p_rd_valid,output wire p_rd_ready,
 input wire[31:0]p_rd_addr,input wire[6:0]p_rd_beats,
 input wire[63:0]p_rd_token,input wire[2:0]p_rd_owner,
 output wire p_r_valid,input wire p_r_ready,output wire[255:0]p_r_data,
 output wire[63:0]p_r_token,output wire[6:0]p_r_index,
 output wire p_r_last,p_r_error,
 input wire p_wr_valid,output wire p_wr_ready,
 input wire[31:0]p_wr_addr,input wire[6:0]p_wr_beats,
 input wire[63:0]p_wr_token,input wire[2:0]p_wr_owner,
 input wire p_w_valid,output wire p_w_ready,input wire[255:0]p_w_data,
 input wire[31:0]p_w_strb,input wire p_w_last,
 output wire p_b_valid,input wire p_b_ready,output wire[63:0]p_b_token,
 output wire p_b_error,
 output wire axi_arvalid,input wire axi_arready,output wire[27:0]axi_araddr,
 output wire[3:0]axi_arlen,axi_aruser_id,output wire axi_aruser_ap,
 input wire axi_rvalid,input wire[255:0]axi_rdata,
 input wire[3:0]axi_rid,input wire axi_rlast,
 output wire axi_awvalid,input wire axi_awready,output wire[27:0]axi_awaddr,
 output wire[3:0]axi_awlen,axi_awuser_id,output wire axi_awuser_ap,
 output wire[255:0]axi_wdata,output wire[31:0]axi_wstrb,
 input wire axi_wready,input wire[3:0]axi_wusero_id,input wire axi_wusero_last,
 output reg[63:0]physical_read_bytes,physical_write_bytes,verify_read_bytes,
 output reg[31:0]verified_writes,verify_retries,completed_writes,
 output wire[6:0]reserved_beats,output wire[3:0]reserved_requests
);
 localparam WI=0,WFILL=1,WADDR=2,WSEND=3,VADDR=4,VREAD=5,BRESP=6,POISON=7;
 reg[2:0]ws;
 reg armed;reg read_offer;
 reg[7:0]live;
 reg[2:0]head,tail;
 reg[3:0]requests;
 reg[6:0]reserved;
 reg[5:0]allocation;
 reg[4:0]lengths[0:7],received[0:7];
 reg[5:0]base[0:7];
 reg[63:0]tokens[0:7];
 // A read page belongs to its live request slot. Its captured return payload
 // is immutable until consumption; unrelated physical writes need not wait
 // for that consumer. Keep all response RAM and request/beat reservations.
 reg[19:0]read_page[0:7];reg[7:0]write_hazards;
 integer wh;

 reg[255:0]return_store[0:63];
 reg[4:0]delivered;
 reg[31:0]write_addr;
 reg[63:0]write_token;
 reg[4:0]write_length,fill_index,send_index,verify_index;
 wire write_capacity=requests<8&&({1'b0,reserved}+{3'b0,write_length})<=64;
 wire write_qualified=WRITE_READBACK?(requests==0):((write_hazards==0)&&write_capacity);
 reg[255:0]write_store[0:15] /* synthesis syn_ramstyle="lut_ram" */;
 reg[31:0]mask_store[0:15];
 reg mismatch,bad_write;
 reg[7:0]attempt;
 // A fault freezes transaction execution, so values beyond timeout+1 are
 // unreachable in service. Narrow the counters without altering fault timing.
 localparam WATCH_W=TIMEOUT_CYCLES<=0?1:$clog2(TIMEOUT_CYCLES+2);
 reg[WATCH_W-1:0]vendor_watch,write_watch;
 integer i;

 function automatic valid_geometry(input[31:0]addr,input[6:0]beats);
  reg[12:0]lastbyte;
  begin lastbyte={1'b0,addr[11:0]}+{1'b0,beats,5'b0};
   valid_geometry=addr[31:30]==0&&addr[4:0]==0&&beats>0&&beats<=16&&lastbyte<=4096;
  end
 endfunction
 wire running=armed&&!rst&&ddr_init_done&&!fault;
 wire rd_geometry=valid_geometry(p_rd_addr,p_rd_beats);
 wire wr_geometry=valid_geometry(p_wr_addr,p_wr_beats);
 // Physical in-flight budget includes the single active write burst.
 // WFILL is local staging; release AW waits only for captured dependencies and global credits.
 wire write_inflight=ws==WSEND;
 wire[7:0]physical_beats={1'b0,reserved}+{1'b0,p_rd_beats}+(write_inflight?{3'b0,write_length}:8'd0);
 wire read_space=requests<(write_inflight?7:8)&&physical_beats<=64;
 // Every older read is accepted before the write snapshot. Different-page
 // younger reads may use the independent AR/R path while this sole writer
 // drains. No read-after-write on the same page bypasses final completion.
 // Disjoint-page reads may also advance while local write data is staged.
 // AW preserves same-page read-before-write and any held AR acceptance; unrelated returns may overlap.
 wire duplex_read=!WRITE_READBACK&&(ws==WFILL||ws==WSEND||ws==BRESP)&&
   p_rd_addr[31:12]!=write_addr[31:12];
 wire issue_read=running&&(read_offer||(ws==WI&&!p_wr_valid)||duplex_read)&&p_rd_valid&&rd_geometry&&read_space;
 assign axi_arvalid=issue_read||(running&&ws==VADDR);
 assign axi_araddr=ws==VADDR?write_addr[29:2]:p_rd_addr[29:2];
 assign axi_arlen=ws==VADDR?write_length[3:0]-1'b1:p_rd_beats[3:0]-1'b1;
 assign axi_aruser_id=ws==VADDR?4'd8:{1'b0,tail};
 assign axi_aruser_ap=1'b0;
 assign p_rd_ready=issue_read&&axi_arready;
 wire take_rd=p_rd_valid&&p_rd_ready;
 wire[5:0]return_address=base[head]+{1'b0,delivered};
 assign p_r_valid=running&&requests!=0&&received[head]>delivered;
 assign p_r_data=return_store[return_address];
 assign p_r_token=tokens[head];
 assign p_r_index={2'b0,delivered};
 assign p_r_last=delivered+1'b1==lengths[head];
 assign p_r_error=1'b0;
 wire take_r=p_r_valid&&p_r_ready;
 wire retire_read=take_r&&p_r_last;
 assign reserved_beats=reserved;
 assign reserved_requests=requests;
 // PN: filling the existing write staging RAM is independent of read returns.
 // A related older read must have physically returned in full, not merely been queued.
 assign p_wr_ready=running&&ws==WI&&!read_offer&&wr_geometry;
 assign p_w_ready=running&&ws==WFILL;
 assign axi_awvalid=running&&ws==WADDR&&write_qualified&&!read_offer;
 assign axi_awaddr=write_addr[29:2];
 assign axi_awlen=write_length[3:0]-1'b1;
 assign axi_awuser_id=4'd9;
 assign axi_awuser_ap=1'b0;
 // PV: local registered HMIC data boundary. First beat is prepared during
 // WFILL; no new state/wait cycle and no downstream ready-to-RAM output cone.
 reg[255:0]write_beat_data;
 reg[31:0]write_beat_mask;
 assign axi_wdata=write_beat_data;
 assign axi_wstrb=(ws==WSEND||ws==WADDR)?write_beat_mask:32'b0;
 wire take_aw=axi_awvalid&&axi_awready;
 wire take_w=running&&axi_wready&&(ws==WSEND||take_aw);
 wire[3:0]next_send=send_index[3:0]+1'b1;
 // Payload need not reset: the original armed/state/fault contract owns it.
 // During fill/non-send states load word0; one-beat fills bypass the same-edge
 // RAM write. Hold through AW/W stalls; advancing only follows real take_w.
 always @(posedge clk)begin
  if(ws!=WADDR&&ws!=WSEND)begin
   write_beat_data<=write_store[0];write_beat_mask<=mask_store[0];
  end
  if(p_w_valid&&p_w_ready&&fill_index==0)begin
   write_beat_data<=p_w_data;write_beat_mask<=p_w_strb;
  end
  if(take_w&&send_index+1'b1<write_length)begin
   write_beat_data<=write_store[next_send];write_beat_mask<=mask_store[next_send];
  end
 end
 assign p_b_valid=!rst&&ws==BRESP;
 assign p_b_token=write_token;
 assign p_b_error=bad_write||fault;
 assign drained=armed&&!rst&&requests==0&&ws==WI;
 wire known_r=axi_rid<8&&live[axi_rid[2:0]];
 wire normal_r=running&&axi_rvalid&&axi_rid<8;
 wire verify_r=WRITE_READBACK&&running&&axi_rvalid&&ws==VREAD&&axi_rid==8&&verify_index<write_length;
 wire[5:0]store_address=base[axi_rid[2:0]]+{1'b0,received[axi_rid[2:0]]};
 // PG: bounded one-beat verification pipeline. No fictitious vendor RREADY/B.
 reg verify_pending,verify_last,verify_bad_last;
 reg[31:0]verify_bad_byte;integer b;
 wire compare_bad=|verify_bad_byte;
 always @(posedge clk)begin
  if(rst)verify_pending<=0;
  else begin
   verify_pending<=verify_r;
   if(verify_r)begin
    for(b=0;b<32;b=b+1)
     verify_bad_byte[b]<=mask_store[verify_index[3:0]][b]&&(axi_rdata[b*8+:8]!=write_store[verify_index[3:0]][b*8+:8]);
    verify_last<=axi_rlast;
    verify_bad_last<=axi_rlast!=(verify_index+1'b1==write_length);
   end
  end
 end
 wire waiting_vendor=(requests!=0&&!(received[head]==lengths[head]))||(ws==WADDR&&write_qualified&&!read_offer)||ws==WSEND||ws==VADDR||ws==VREAD;

 // Snapshot dependency when the sole write transaction is accepted.
 // While WFILL/WSEND/BRESP, the existing read admission only permits another
 // page. WADDR admits no new AR; held AR must clear before AW. Thus a set of
 // older same-page reads can only shrink after this snapshot.
 always @(posedge clk)begin
  if(take_rd)read_page[tail]<=p_rd_addr[31:12];
  if(rst)write_hazards<=0;
  else if(running)begin
   for(wh=0;wh<8;wh=wh+1)begin
    if(p_wr_valid&&p_wr_ready)
     write_hazards[wh]<=live[wh]&&received[wh]!=lengths[wh]&&
       read_page[wh]==p_wr_addr[31:12]&&
       !(axi_rvalid&&axi_rid==wh&&axi_rlast&&received[wh]+1'b1==lengths[wh]);
    else if(axi_rvalid&&axi_rid==wh&&live[wh]&&axi_rlast&&received[wh]+1'b1==lengths[wh])
     write_hazards[wh]<=0;
   end
  end
 end

 task automatic poison(input[7:0]code);
  begin
   fault<=1;fault_code<=code;bad_write<=1;
   if(ws!=WI&&ws!=POISON)ws<=BRESP;else ws<=POISON;
  end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   fault<=0;fault_code<=0;armed<=0;read_offer<=0;ws<=WI;live<=0;head<=0;tail<=0;requests<=0;reserved<=0;allocation<=0;delivered<=0;
   write_addr<=0;write_token<=0;write_length<=0;fill_index<=0;send_index<=0;verify_index<=0;mismatch<=0;bad_write<=0;attempt<=0;vendor_watch<=0;write_watch<=0;
   physical_read_bytes<=0;physical_write_bytes<=0;verify_read_bytes<=0;verified_writes<=0;verify_retries<=0;completed_writes<=0;
   for(i=0;i<8;i=i+1)begin lengths[i]<=0;received[i]<=0;base[i]<=0;tokens[i]<=0;end
  end else begin
   if(!armed&&ddr_init_done&&controller_quiescent&&!axi_rvalid&&!axi_wready&&!fault)armed<=1;
   if(p_b_valid&&p_b_ready)ws<=fault?POISON:WI;
   if(running)begin
    // Lock the offered AR through backpressure across W completion/response.
    if(issue_read)read_offer<=!axi_arready;
    reserved<=reserved+(take_rd?p_rd_beats:7'd0)-(take_r?7'd1:7'd0);
    case({take_rd,retire_read})2'b10:requests<=requests+1'b1;2'b01:requests<=requests-1'b1;default:begin end endcase
    if(take_rd)begin
     live[tail]<=1;lengths[tail]<=p_rd_beats[4:0];received[tail]<=0;
     tokens[tail]<=p_rd_token;base[tail]<=allocation;allocation<=allocation+p_rd_beats[5:0];tail<=tail+1'b1;
    end
    if(take_r)begin
     if(p_r_last)begin live[head]<=0;head<=head+1'b1;delivered<=0;end
     else delivered<=delivered+1'b1;
    end
    if(normal_r)begin
     if(!known_r||received[axi_rid[2:0]]>=lengths[axi_rid[2:0]]||axi_rlast!=(received[axi_rid[2:0]]+1'b1==lengths[axi_rid[2:0]]))poison(8'h11);
     else begin
      return_store[store_address]<=axi_rdata;received[axi_rid[2:0]]<=received[axi_rid[2:0]]+1'b1;
      physical_read_bytes<=physical_read_bytes+32;
     end
    end
    if(p_wr_valid&&p_wr_ready)begin
     write_addr<=p_wr_addr;write_length<=p_wr_beats[4:0];write_token<=p_wr_token;
     fill_index<=0;send_index<=0;bad_write<=0;attempt<=0;ws<=WFILL;
    end
    if(p_w_valid&&p_w_ready)begin
     write_store[fill_index[3:0]]<=p_w_data;mask_store[fill_index[3:0]]<=p_w_strb;
     if(p_w_last!=(fill_index+1'b1==write_length))poison(8'h21);
     else if(p_w_last)begin ws<=WADDR;send_index<=0;end
     else fill_index<=fill_index+1'b1;
    end
    if(take_aw)ws<=WSEND;
    if(take_w)begin
     physical_write_bytes<=physical_write_bytes+32;
     if(axi_wusero_id!=9||axi_wusero_last!=(send_index+1'b1==write_length))poison(8'h22);
     else if(axi_wusero_last)begin
      completed_writes<=completed_writes+1'b1;
      if(WRITE_READBACK)begin ws<=VADDR;verify_index<=0;mismatch<=0;end
      else ws<=BRESP;
     end
     else send_index<=send_index+1'b1;
    end
    if(ws==VADDR&&axi_arvalid&&axi_arready)begin ws<=VREAD;verify_index<=0;mismatch<=0;end
    if(verify_r)begin
     physical_read_bytes<=physical_read_bytes+32;verify_read_bytes<=verify_read_bytes+32;
     verify_index<=verify_index+1'b1;
    end
    if(verify_pending)begin
     mismatch<=mismatch||compare_bad;
     if(verify_bad_last)poison(8'h31);
     else if(verify_last)begin
      if(mismatch||compare_bad)begin
       if(attempt+1>=VERIFY_ATTEMPTS)poison(8'h32);
       else begin attempt<=attempt+1'b1;verify_retries<=verify_retries+1'b1;ws<=VADDR;end
      end else begin verified_writes<=verified_writes+1'b1;ws<=BRESP;end
     end
    end
    if(!waiting_vendor||axi_rvalid||verify_pending||take_aw||take_w)vendor_watch<=0;
    else vendor_watch<=vendor_watch+1'b1;
    if(TIMEOUT_CYCLES!=0&&vendor_watch>=TIMEOUT_CYCLES)poison(8'h40);
    // Independent AR/R progress must not conceal a stuck active writer.
    if(!((ws==WADDR&&write_qualified&&!read_offer)||ws==WSEND)||take_aw||take_w)write_watch<=0;
    else write_watch<=write_watch+1'b1;
    if(TIMEOUT_CYCLES!=0&&write_watch>=TIMEOUT_CYCLES)poison(8'h40);
    if(ws==WI&&((p_rd_valid&&!rd_geometry)||(p_wr_valid&&!wr_geometry)))poison(8'h01);
    if(axi_rvalid&&!(normal_r||verify_r))poison(8'h12);
    if(axi_wready&&!(ws==WSEND||take_aw))poison(8'h23);
   end
   if(armed&&!ddr_init_done)poison(8'h41);
   // A return before controller flush qualification is not consumed or armed.
   if(!armed&&(axi_rvalid||axi_wready))begin fault<=1;fault_code<=8'h42;ws<=POISON;end
  end
 end
endmodule
