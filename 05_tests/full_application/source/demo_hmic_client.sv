// PL: four bounded read descriptors, existing return buffer and verified single writer.
module demo_hmic_client #(parameter integer READ_SLOTS=4)(
 input wire clk,rst,enabled,output reg fault,output wire drained,
 input wire c_arvalid,output wire c_arready,input wire[27:0]c_araddr,
 input wire[3:0]c_arlen,c_arid,output wire c_rvalid,output wire[255:0]c_rdata,
 output wire[3:0]c_rid,output wire c_rlast,
 input wire c_awvalid,output wire c_awready,input wire[27:0]c_awaddr,
 input wire[3:0]c_awlen,c_awid,input wire[255:0]c_wdata,input wire[31:0]c_wstrb,
 output wire c_wready,output wire[3:0]c_wid,output wire c_wlast,
 output wire app_rd_valid,input wire app_rd_ready,output wire[31:0]app_rd_addr,
 output wire[6:0]app_rd_beats,output wire[63:0]app_rd_token,output wire[2:0]app_rd_owner,
 input wire app_r_valid,output wire app_r_ready,input wire[255:0]app_r_data,
 input wire[63:0]app_r_token,input wire[6:0]app_r_index,input wire app_r_last,app_r_error,
 output wire app_wr_valid,input wire app_wr_ready,output wire[31:0]app_wr_addr,
 output wire[6:0]app_wr_beats,output wire[63:0]app_wr_token,output wire[2:0]app_wr_owner,
 output wire app_w_valid,input wire app_w_ready,output wire[255:0]app_w_data,
 output wire[31:0]app_w_strb,output wire app_w_last,
 input wire app_b_valid,output wire app_b_ready,input wire[63:0]app_b_token,input wire app_b_error
);

 localparam IDLE=0,WRITE=1,VERIFY=2;
 localparam PTR_W=(READ_SLOTS<=1)?1:$clog2(READ_SLOTS);
 reg[1:0]ws;reg[31:0]serial;reg serial_available;
 // Runtime token epoch changes ONLY after all accepted reads and the actual
 // final-write ACK are consumed. Queued responses retain their original epoch.
 // Cold reset still requires coordinated controller reset / late-return flush.
 reg[31:0]serial_epoch;
 reg[19:0]write_page;reg[63:0]write_token;reg[3:0]write_id;reg[4:0]write_count,write_index;
 reg[PTR_W-1:0]rhead,rtail,rissue;
 reg[PTR_W:0]rcount,unissued;
 reg[PTR_W:0]read_ahead;reg write_locked;
 reg[31:0]read_addr[0:READ_SLOTS-1];reg[31:0]read_serial[0:READ_SLOTS-1];
 reg[3:0]read_id[0:READ_SLOTS-1];reg[4:0]read_length[0:READ_SLOTS-1];reg[4:0]read_index;
 wire epoch_drained=ws==IDLE&&rcount==0&&unissued==0;
 wire epoch_exhausted=!serial_available&&epoch_drained&&serial_epoch==32'hffffffff;
 function [PTR_W-1:0]advance(input[PTR_W-1:0]p);
  advance=(p==READ_SLOTS-1)?0:p+1'b1;
 endfunction
 wire[31:0]read_address={2'b0,c_araddr,2'b0},write_address={2'b0,c_awaddr,2'b0};
 wire[12:0]read_end={1'b0,read_address[11:0]}+(({9'b0,c_arlen}+13'd1)<<5);
 wire[12:0]write_end={1'b0,write_address[11:0]}+(({9'b0,c_awlen}+13'd1)<<5);
 wire read_ok=read_address[4:0]==0&&read_end<=4096;
 wire write_ok=write_address[4:0]==0&&write_end<=4096;
 wire accept_new=ws==IDLE&&!rst&&enabled&&!fault&&serial_available;
 // PN: after older reads are issued, stage write data while their returns
 // drain. The bridge still waits for actual older-read retirement before AW.
 // A pending write admits at most four younger reads, then drains. An offered write is locked.
 // This does not retract an offered downstream read under backpressure.
 // Independent reads may overlap an active write only on another 4 KiB page.
 // Same-page reads stay behind the actual final write transfer. This is a
 // conservative ordering test, not an assumption that jobs use disjoint data.
 wire active_write_read=!rst&&enabled&&!fault&&serial_available&&ws!=IDLE&&
   read_address[31:12]!=write_page;
 assign c_arready=((accept_new&&!write_locked&&(!c_awvalid||read_ahead<READ_SLOTS))||active_write_read)&&rcount<READ_SLOTS&&read_ok;
 wire push=c_arvalid&&c_arready;
 assign app_rd_valid=!rst&&!fault&&unissued!=0;
 assign app_rd_addr=read_addr[rissue];assign app_rd_beats={2'b0,read_length[rissue]};
 assign app_rd_token={serial_epoch,read_serial[rissue]};assign app_rd_owner=3'd1;
 wire issue=app_rd_valid&&app_rd_ready;
 wire choose_write=write_locked||!c_arvalid||read_ahead>=READ_SLOTS;
 assign app_wr_valid=accept_new&&unissued==0&&c_awvalid&&write_ok&&choose_write;
 assign c_awready=accept_new&&unissued==0&&write_ok&&app_wr_ready&&choose_write;
 assign app_wr_addr=write_address;assign app_wr_beats={3'b0,c_awlen}+7'd1;
 assign app_wr_token={serial_epoch,serial+32'd1};assign app_wr_owner=3'd1;
 wire take_write=app_wr_valid&&app_wr_ready;
 assign app_r_ready=!rst&&!fault&&rcount!=0;
 wire good_r=rcount!=0&&!app_r_error&&app_r_token=={serial_epoch,read_serial[rhead]}&&app_r_index=={2'b0,read_index}&&app_r_last==(read_index+1==read_length[rhead]);
 assign c_rvalid=app_r_valid&&app_r_ready&&good_r;
 assign c_rdata=app_r_data;assign c_rid=read_id[rhead];assign c_rlast=app_r_last;
 wire pop=c_rvalid&&app_r_last;
 assign app_w_valid=!rst&&!fault&&ws==WRITE;
 // Preserve four read slots and bounded read priority; defer final WREADY
 // until the actual complete burst notification, never just local storage.
 assign c_wready=(app_w_valid&&app_w_ready&&!c_wlast)||
   (!rst&&!fault&&ws==VERIFY&&app_b_valid&&!app_b_error&&app_b_token==write_token);
 assign c_wid=write_id;assign c_wlast=write_index+1==write_count;
 assign app_w_data=c_wdata;assign app_w_strb=c_wstrb;assign app_w_last=c_wlast;
 assign app_b_ready=!rst&&!fault&&ws==VERIFY;
 assign drained=!rst&&ws==IDLE&&rcount==0&&unissued==0&&!fault;
 always @(posedge clk)begin
  if(rst)begin
   ws<=IDLE;serial<=0;serial_available<=1;serial_epoch<=1;write_page<=0;write_token<=0;write_id<=0;write_count<=0;write_index<=0;fault<=0;
   rhead<=0;rtail<=0;rissue<=0;rcount<=0;unissued<=0;read_index<=0;read_ahead<=0;write_locked<=0;
  end else begin
   if(enabled&&((c_arvalid&&!read_ok)||(ws==IDLE&&c_awvalid&&!write_ok)||epoch_exhausted))fault<=1;
   if(app_r_valid&&(!good_r||rcount==unissued))fault<=1;
   if(app_b_valid&&ws!=VERIFY)fault<=1;
   if(!c_awvalid||take_write)read_ahead<=0;else if(push)read_ahead<=read_ahead+1'b1;
   if(take_write)write_locked<=0;else if(app_wr_valid)write_locked<=1;
   if(push||take_write)begin serial<=serial+1;serial_available<=serial!=32'hfffffffe;end
   // A full serial space stops NEW requests, not outstanding completions.
   // Finite queues drain normally before reusing the low counter in a new epoch.
   // No extra cycles or reset in the normal per-frame path.
   if(!fault&&!serial_available&&epoch_drained&&!epoch_exhausted)begin
    serial_epoch<=serial_epoch+1'b1;serial<=0;serial_available<=1;
   end
   if(push)begin
    read_addr[rtail]<=read_address;read_serial[rtail]<=serial+1;read_id[rtail]<=c_arid;
    read_length[rtail]<={1'b0,c_arlen}+1'b1;rtail<=advance(rtail);
   end
   if(issue)rissue<=advance(rissue);
   case({push,issue})2'b10:unissued<=unissued+1'b1;2'b01:unissued<=unissued-1'b1;default:begin end endcase
   case({push,pop})2'b10:rcount<=rcount+1'b1;2'b01:rcount<=rcount-1'b1;default:begin end endcase
   if(c_rvalid)begin
    if(app_r_last)begin rhead<=advance(rhead);read_index<=0;end
    else read_index<=read_index+1'b1;
   end
   if(take_write)begin write_page<=write_address[31:12];ws<=WRITE;write_token<=app_wr_token;write_id<=c_awid;write_count<={1'b0,c_awlen}+1'b1;write_index<=0;end
   if(app_w_valid&&app_w_ready)begin if(c_wlast)ws<=VERIFY;else write_index<=write_index+1'b1;end
   if(app_b_valid&&app_b_ready)begin
    if(app_b_error||app_b_token!=write_token)fault<=1;
    ws<=IDLE;
   end
  end
 end
endmodule
