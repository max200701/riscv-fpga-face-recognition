// BOOT sub-owner. All writes still traverse OL owner and the single real bridge.
// Cold reset only: neither application REARM nor video recovery resets DDR/FIFO.
module om_video_session(
 input wire clk,rst,boot_allowed,memory_drained,app_running,start_pulse,
 input wire arm_pulse,stop_pulse,recover_pulse,
 input wire[31:0] requested_frame,requested_generation,session_generation,
 input wire owner_rearm_ack,capture_arm_ready,capture_busy,capture_frame_ready,
 input wire capture_rejected,recovery_ready,recovery_done,recovery_waiting_source,source_stopped,
 input wire[31:0] held_generation,held_frame,pixels_accepted,writes_acknowledged,
 input wire[7:0] capture_error,liveness_fault,writer_fault_code,
 input wire writer_fault,result_ready,rx_configured,rx_candidate,rx_fault,
 input wire[7:0]rx_fault_code,input wire[31:0]rx_raw_status,
 output reg video_reserved,output wire arm_allowed,stop_allowed,recover_allowed,
 output wire start_allowed,read_allowed,write_allowed,
 output reg release_frame,output wire[31:0]release_generation,
 output reg endpoint_rearm_ack,output wire[31:0]next_generation,
 output wire[511:0]status_words
);
 reg[31:0]next_gen,lease_generation,lease_frame,lease_session;
 reg[31:0]result_source,result_session,result_generation,result_frame;
 reg release_pending,recover_pending;
 assign next_generation=next_gen;
 assign release_generation=lease_generation;
 assign arm_allowed=boot_allowed&&memory_drained&&!app_running&&!video_reserved&&capture_arm_ready&&rx_configured&&rx_candidate&&!rx_fault&&next_gen!=32'hffffffff;
 assign stop_allowed=boot_allowed&&video_reserved&&capture_busy&&!capture_frame_ready&&!capture_rejected;
 assign recover_allowed=boot_allowed&&video_reserved&&capture_rejected&&recovery_ready&&memory_drained;
 // PF: the capture producer holds both identity words throughout frame_ready.
 // Qualify the wide identity comparison locally; retain live reset, ready,
 // ownership and session checks. First readiness is conservatively one edge later.
 reg capture_identity;
 always @(posedge clk)begin
  if(rst||!video_reserved||!capture_frame_ready)capture_identity<=0;
  else capture_identity<=held_generation==lease_generation&&held_frame==lease_frame;
 end
 wire good_frame=video_reserved&&capture_frame_ready&&capture_identity&&session_generation==lease_session;
`ifndef SYNTHESIS
 reg identity_was_held;reg[63:0]identity_previous;
 always @(posedge clk)begin
  if(rst)identity_was_held<=0;
  else begin
   if(identity_was_held&&capture_frame_ready&&{held_generation,held_frame}!==identity_previous)
    $fatal(1,"PF_CAPTURE_PRODUCER_CHANGED_HELD_IDENTITY");
   identity_was_held<=capture_frame_ready;identity_previous<={held_generation,held_frame};
  end
 end
`endif
 assign start_allowed=boot_allowed&&memory_drained&&(!video_reserved||good_frame)&&!release_pending&&!recover_pending;
 assign read_allowed=start_allowed;
 assign write_allowed=start_allowed&&!video_reserved;
 wire[31:0]flags={16'b0,rx_fault,rx_candidate,rx_configured,result_ready,recover_allowed,stop_allowed,arm_allowed,source_stopped,
   recovery_waiting_source,recovery_ready,capture_rejected,capture_frame_ready,capture_busy,video_reserved,app_running,start_allowed};
 assign status_words={rx_raw_status,{rx_fault_code,writer_fault_code,liveness_fault,capture_error},result_frame,result_generation,result_session,result_source,
   writes_acknowledged,pixels_accepted,lease_session,lease_frame,lease_generation,next_gen,session_generation,flags,32'd1,32'h31444956};
 always @(posedge clk)begin
  if(rst)begin
   video_reserved<=0;next_gen<=0;lease_generation<=0;lease_frame<=0;lease_session<=0;
   result_source<=0;result_session<=0;result_generation<=0;result_frame<=0;
   release_frame<=0;endpoint_rearm_ack<=0;release_pending<=0;recover_pending<=0;
  end else begin
   release_frame<=0;endpoint_rearm_ack<=0;
   if(arm_pulse&&arm_allowed&&requested_generation==next_gen)begin
    video_reserved<=1;lease_generation<=requested_generation;lease_frame<=requested_frame;
    lease_session<=session_generation;next_gen<=next_gen+1'b1;
   end
   if(start_pulse&&start_allowed)begin
    result_source<=video_reserved?1:0;result_session<=session_generation;
    result_generation<=video_reserved?lease_generation:0;result_frame<=video_reserved?lease_frame:0;
   end
   if(owner_rearm_ack)begin
    if(video_reserved)begin release_frame<=1;release_pending<=1;end
    else endpoint_rearm_ack<=1;
   end
   if(release_pending&&!capture_busy&&capture_arm_ready&&boot_allowed&&memory_drained)begin
    video_reserved<=0;release_pending<=0;endpoint_rearm_ack<=1;
   end
   if(recover_pulse&&recover_allowed)recover_pending<=1;
   if(recover_pending&&!capture_busy&&capture_arm_ready&&boot_allowed&&memory_drained)begin
    video_reserved<=0;recover_pending<=0;
   end
  end
 end
endmodule
