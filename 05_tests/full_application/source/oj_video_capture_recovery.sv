// Non-backpressurable video capture, one frozen frame lease at a time.
// VS input must already use the configured active polarity. RGB order/edge
// still require board test. Both resets must be coordinated physical resets.
// After any incomplete capture, drain FIFO then pad ONLY the unpublished input
// slot to let the unchanged writer finish its finite ACK contract. Never START
// the application on that slot. Source/DDR error needs explicit release/reset.
module oj_video_capture_recovery #(
 parameter WIDTH=640,HEIGHT=480,SOURCE_WIDTH=640,SOURCE_HEIGHT=480,ROI_X=0,ROI_Y=0,
 parameter FIFO_AW=12,MAX_FRAME_PCLK=8000000,
 parameter PCLK_STALL_UI_CYCLES=1250000,FIRST_VS_UI_CYCLES=12500000,FRAME_UI_CYCLES=25000000
)(input wire pclk,prst,pixel_lock,vs,de,input wire[23:0]rgb,
 input wire uclk,urst,arm,boot_allowed,bridge_drained,
 input wire[31:0]generation,frame_id,base_address,
 output wire arm_ready,
 input wire release_frame,input wire[31:0]release_generation,
 input wire cancel_request,recover_request,
 output wire capture_busy,output reg[7:0]liveness_fault,
 output wire recovery_waiting_source,source_stopped,recovery_ready,
 output reg recovery_done,
 output wire frame_ready,frame_rejected,output wire[7:0]capture_error,
 output wire writer_fault,output wire[7:0]writer_fault_code,
 output wire[31:0]held_generation,held_frame_id,pixels_accepted,writes_acknowledged,
 output wire p_wr_valid,input wire p_wr_ready,output wire[31:0]p_wr_addr,
 output wire[6:0]p_wr_beats,output wire[63:0]p_wr_token,output wire[2:0]p_wr_owner,
 output wire p_w_valid,input wire p_w_ready,output wire[255:0]p_w_data,
 output wire[31:0]p_w_strb,output wire p_w_last,
 input wire p_b_valid,output wire p_b_ready,input wire[63:0]p_b_token,input wire p_b_error);
 (* async_reg="true" *)reg[1:0]prst_sync,urst_sync;
 always @(posedge pclk or posedge prst)if(prst)prst_sync<=2'b11;else prst_sync<={prst_sync[0],1'b0};
 always @(posedge uclk or posedge urst)if(urst)urst_sync<=2'b11;else urst_sync<={urst_sync[0],1'b0};
 wire prst_local=prst_sync[1],urst_local=urst_sync[1];
 localparam PIXELS=WIDTH*HEIGHT;
 reg arm_toggle,lease;
 reg[31:0]mail_generation,mail_frame;
 (* async_reg="true" *)reg[2:0]arm_sync,done_sync;
 reg arm_seen,done_toggle;
 reg abort_request,source_abort_ack,started_toggle;
 (* async_reg="true" *)reg[2:0]abort_sync,ack_sync,started_sync,heartbeat_sync,lock_sync;
 reg[4:0]heartbeat_count;
 reg heartbeat;
 reg heartbeat_last,start_seen;
 (* async_reg="true" *)reg[2:0]source_arm_sync;reg[2:0]source_arm_settle;
 reg[31:0]heartbeat_age,first_vs_age,frame_age;
 reg[31:0]done_generation,done_frame;
 reg[7:0]done_error;
 reg[1:0]ps;
 reg vs_prev,de_prev;
 reg[31:0]px,py,roi_count,timeout_count;
 reg[7:0]errors;
 reg[31:0]capture_generation,capture_frame;
 wire frame_edge=vs&&!vs_prev;
 wire inside_roi=px>=ROI_X&&px<ROI_X+WIDTH&&py>=ROI_Y&&py<ROI_Y+HEIGHT;
 wire push=ps==2&&de&&inside_roi&&errors==0&&lock_sync[2]&&!frame_edge&&!abort_sync[2];
 wire fifo_full,fifo_empty,fifo_valid;
 wire[23:0]fifo_data;
 wire fifo_ready;
 oj_pixel_fifo_recovery #(.AW(FIFO_AW)) pixels(
  .wclk(pclk),.wrst(prst_local),.wen(push),.wdata(rgb),.full(fifo_full),
  .rclk(uclk),.rrst(urst_local),.valid(fifo_valid),.ready(fifo_ready),.rdata(fifo_data),.empty(fifo_empty));
 always @(posedge pclk or posedge prst_local)begin
  if(prst_local)begin
   arm_sync<=0;arm_seen<=0;done_toggle<=0;done_generation<=0;done_frame<=0;done_error<=0;
   ps<=0;vs_prev<=0;de_prev<=0;px<=0;py<=0;roi_count<=0;timeout_count<=0;errors<=0;
   capture_generation<=0;capture_frame<=0;
   abort_sync<=0;source_abort_ack<=0;started_toggle<=0;
   heartbeat_count<=0;heartbeat<=0;lock_sync<=0;
  end else begin
   arm_sync<={arm_sync[1:0],arm_toggle};vs_prev<=vs;de_prev<=de;
   abort_sync<={abort_sync[1:0],abort_request};lock_sync<={lock_sync[1:0],pixel_lock};
   heartbeat_count<=heartbeat_count+1'b1;heartbeat<=heartbeat_count[4];
   if(!abort_sync[2])source_abort_ack<=0;
   else if(ps==3)source_abort_ack<=1;
   if(arm_sync[2]!=arm_seen)begin
    // Bundled mailbox remains stable until completion is consumed + release.
    arm_seen<=arm_sync[2];capture_generation<=mail_generation;capture_frame<=mail_frame;
    ps<=1;started_toggle<=~arm_sync[2];px<=0;py<=0;roi_count<=0;timeout_count<=0;errors<=0;
   end else if((ps==1||ps==2)&&abort_sync[2])begin
    // Source stop ACK is produced by the source clock after writes are gated.
    // If PCLK is stopped this branch cannot run; UI MUST retain the lease.
    done_generation<=capture_generation;done_frame<=capture_frame;
    done_error<=errors|8'h80;done_toggle<=arm_seen;source_abort_ack<=1;ps<=3;
   end else if(ps==1)begin
    if(frame_edge)begin
     ps<=2;started_toggle<=arm_seen;px<=0;py<=0;roi_count<=0;timeout_count<=0;
     if(!lock_sync[2]||de)errors<=8'h02;
    end
   end else if(ps==2)begin
    timeout_count<=timeout_count+1;
    if(!lock_sync[2])errors<=errors|8'h02;
    if(de&&!frame_edge)begin
     px<=px+1;
     if(px>=SOURCE_WIDTH||py>=SOURCE_HEIGHT)errors<=errors|8'h04;
     if(inside_roi)begin roi_count<=roi_count+1;if(fifo_full)errors<=errors|8'h01;end
    end
    if(de_prev&&!de)begin
     if(px!=SOURCE_WIDTH)errors<=errors|8'h04;
     px<=0;py<=py+1;
    end
    if(frame_edge || timeout_count>=MAX_FRAME_PCLK-1)begin
     done_generation<=capture_generation;done_frame<=capture_frame;
     done_error<=errors | ((!lock_sync[2])?8'h02:8'h00) |
      ((py!=SOURCE_HEIGHT||roi_count!=PIXELS||de||de_prev)?8'h04:8'h00) |
      ((!frame_edge)?8'h08:8'h00);
     done_toggle<=arm_seen;ps<=3;
    end
   end
  end
 end
 wire writer_ready,writer_start_ready,writer_pixel_ready;
 reg end_seen;reg[3:0]end_settle;reg[7:0]ui_error;
 wire take_arm=arm&&arm_ready;
 assign arm_ready=!lease&&writer_start_ready&&fifo_empty&&!abort_request&&!ack_sync[2];
 assign capture_busy=lease;
 assign source_stopped=lease&&end_seen&&end_settle==0;
 assign recovery_waiting_source=lease&&liveness_fault!=0&&!source_stopped;
 wire[7:0]effective_error=ui_error|((liveness_fault!=0)?8'h80:8'h00);
 assign capture_error=effective_error;
 // Extra settling cycles ensure the frozen completion mailbox and final
 // Gray write pointer have crossed before an invalid frame may be padded.
 wire can_pad=end_seen&&end_settle==0&&effective_error!=0&&fifo_empty;
 wire writer_pixel_valid=lease&&(fifo_valid||can_pad)&&pixels_accepted<PIXELS;
 wire[23:0]writer_pixel_rgb=fifo_valid?fifo_data:24'd0;
 assign fifo_ready=lease&&((pixels_accepted<PIXELS&&writer_pixel_ready)||
                        (end_seen&&effective_error!=0&&pixels_accepted==PIXELS));
 assign frame_ready=lease&&end_seen&&end_settle==0&&effective_error==0&&writer_ready&&fifo_empty&&bridge_drained;
 assign frame_rejected=lease&&end_seen&&end_settle==0&&effective_error!=0&&writer_ready&&fifo_empty&&bridge_drained;
 assign recovery_ready=frame_rejected&&!writer_fault&&boot_allowed;
 wire normal_release=release_frame&&frame_ready;
 wire recover_fire=recover_request&&recovery_ready&&release_generation==mail_generation;
 wire qualified_release=(normal_release||recover_fire)&&release_generation==mail_generation;
 wire monitor_active=lease&&!end_seen;
 wire[7:0]due_fault={4'b0,
   (cancel_request&&lease&&boot_allowed&&!frame_ready),
   (monitor_active&&frame_age>=FRAME_UI_CYCLES-1),
   (monitor_active&&!start_seen&&first_vs_age>=FIRST_VS_UI_CYCLES-1),
   (monitor_active&&heartbeat_age>=PCLK_STALL_UI_CYCLES-1)};
 always @(posedge uclk or posedge urst_local)begin
  if(urst_local)begin
   arm_toggle<=0;lease<=0;mail_generation<=0;mail_frame<=0;
   done_sync<=0;end_seen<=0;end_settle<=0;ui_error<=0;
   abort_request<=0;ack_sync<=0;started_sync<=0;heartbeat_sync<=0;
   heartbeat_last<=0;start_seen<=0;heartbeat_age<=0;first_vs_age<=0;frame_age<=0;
   liveness_fault<=0;recovery_done<=0;source_arm_sync<=0;source_arm_settle<=0;
  end else begin
   done_sync<={done_sync[1:0],done_toggle};
   ack_sync<={ack_sync[1:0],source_abort_ack};
   started_sync<={started_sync[1:0],started_toggle};
   heartbeat_sync<={heartbeat_sync[1:0],heartbeat};
   source_arm_sync<={source_arm_sync[1:0],arm_seen};
   recovery_done<=0;
   if(heartbeat_sync[2]!=heartbeat_last)begin heartbeat_last<=heartbeat_sync[2];heartbeat_age<=0;end
   else if(heartbeat_age<32'hffffffff)heartbeat_age<=heartbeat_age+1'b1;
   if(take_arm)begin
    arm_toggle<=!arm_toggle;lease<=1;mail_generation<=generation;mail_frame<=frame_id;
    end_seen<=0;end_settle<=0;ui_error<=0;abort_request<=0;
    start_seen<=0;source_arm_settle<=0;first_vs_age<=0;frame_age<=0;heartbeat_age<=0;liveness_fault<=0;
   end else if(lease)begin
    if(first_vs_age<32'hffffffff)first_vs_age<=first_vs_age+1'b1;
    if(frame_age<32'hffffffff)frame_age<=frame_age+1'b1;
    if(source_arm_sync[2]!=arm_toggle)source_arm_settle<=0;
    else if(source_arm_settle<4)source_arm_settle<=source_arm_settle+1'b1;
    else if(started_sync[2]==arm_toggle)start_seen<=1;
    if(due_fault!=0)begin liveness_fault<=liveness_fault|due_fault;abort_request<=1;end
    if(!end_seen&&done_sync[2]==arm_toggle)begin
     end_seen<=1;end_settle<=4;ui_error<=done_error;
     if(done_generation!=mail_generation||done_frame!=mail_frame)ui_error<=done_error|8'h10;
    end else if(end_settle!=0)end_settle<=end_settle-1'b1;
    if(qualified_release&&boot_allowed&&bridge_drained)begin
     lease<=0;abort_request<=0;recovery_done<=recover_fire;
    end
   end
  end
 end
 demo_video_q16_writer #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) writer(
  .clk(uclk),.rst(urst_local),.boot_allowed(boot_allowed),.bridge_drained(bridge_drained),
  .start(take_arm),.generation(generation),.frame_id(frame_id),.base_address(base_address),.start_ready(writer_start_ready),
  .pixel_valid(writer_pixel_valid),.pixel_ready(writer_pixel_ready),.pixel_rgb(writer_pixel_rgb),
  .pixel_last(pixels_accepted==PIXELS-1),.release_frame(qualified_release),.release_generation(release_generation),
  .frame_ready(writer_ready),.fault(writer_fault),.fault_code(writer_fault_code),
  .held_generation(held_generation),.held_frame_id(held_frame_id),.pixels_accepted(pixels_accepted),.writes_acknowledged(writes_acknowledged),
  .p_wr_valid(p_wr_valid),.p_wr_ready(p_wr_ready),.p_wr_addr(p_wr_addr),.p_wr_beats(p_wr_beats),.p_wr_token(p_wr_token),.p_wr_owner(p_wr_owner),
  .p_w_valid(p_w_valid),.p_w_ready(p_w_ready),.p_w_data(p_w_data),.p_w_strb(p_w_strb),.p_w_last(p_w_last),
  .p_b_valid(p_b_valid),.p_b_ready(p_b_ready),.p_b_token(p_b_token),.p_b_error(p_b_error));
endmodule
