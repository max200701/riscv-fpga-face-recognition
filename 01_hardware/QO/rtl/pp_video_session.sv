// Two DDR frame slots, one capture engine. A completed capture is transferred
// into a READY slot before releasing the engine lease. START freezes one slot
// for the actual CPU/NPU job; REARM frees only that active slot. The other slot
// may be CAPTURING or READY. Result association always refers to the active job.
module pp_video_session(
 input wire clk,rst,boot_allowed,memory_drained,app_running,application_done,start_pulse,
 input wire arm_pulse,stop_pulse,recover_pulse,
 input wire[31:0]requested_frame,requested_generation,session_generation,
 input wire owner_rearm_ack,capture_arm_ready,capture_busy,capture_frame_ready,
 input wire capture_rejected,recovery_ready,recovery_done,recovery_waiting_source,source_stopped,
 input wire[31:0]held_generation,held_frame,pixels_accepted,writes_acknowledged,
 input wire[7:0]capture_error,liveness_fault,writer_fault_code,
 input wire writer_fault,result_ready,rx_configured,rx_candidate,rx_fault,
 input wire[7:0]rx_fault_code,input wire[31:0]rx_raw_status,
 output wire video_reserved,arm_allowed,stop_allowed,recover_allowed,start_allowed,read_allowed,write_allowed,
 output reg release_frame,output wire[31:0]release_generation,
 output reg endpoint_rearm_ack,output wire[31:0]next_generation,
 output wire[511:0]status_words,
 output wire[31:0]capture_base,application_base,inspect_base,
 output wire capture_quiet,output reg fault
);
 localparam[31:0]BASE0=32'h01800000,BASE1=32'h0e000000;
 reg active_valid,active_slot,ready_valid,ready_slot,cap_valid,cap_slot,transfer_pending,recover_pending;
 reg[31:0]next_gen,cap_generation,cap_frame,cap_session;
 reg[31:0]ready_generation,ready_frame,ready_session,ready_pixels,ready_writes;
 reg[31:0]active_generation,active_frame,active_session;
 reg[31:0]result_source,result_session,result_generation,result_frame;
 wire service=(boot_allowed||(app_running&&!application_done))&&!fault;
 assign video_reserved=active_valid||ready_valid||cap_valid||capture_busy;
 assign capture_quiet=!cap_valid&&!capture_busy&&!transfer_pending&&!recover_pending;
 assign next_generation=next_gen;
 assign capture_base=(cap_valid?cap_slot:(active_valid&&!active_slot))?BASE1:BASE0;
 assign application_base=active_slot?BASE1:BASE0;
 assign inspect_base=ready_valid?(ready_slot?BASE1:BASE0):application_base;
 assign release_generation=cap_generation;
 assign arm_allowed=service&&!ready_valid&&!cap_valid&&!capture_busy&&!transfer_pending&&!recover_pending&&
  capture_arm_ready&&rx_configured&&rx_candidate&&!rx_fault&&next_gen!=32'hffffffff;
 assign stop_allowed=(boot_allowed||app_running)&&cap_valid&&capture_busy&&!capture_frame_ready&&!capture_rejected&&!transfer_pending;
 assign recover_allowed=(boot_allowed||app_running)&&cap_valid&&capture_rejected&&recovery_ready&&!transfer_pending;
 assign start_allowed=boot_allowed&&memory_drained&&!fault&&capture_quiet&&!active_valid&&
  (!video_reserved||(ready_valid&&ready_session==session_generation));
 assign read_allowed=start_allowed;
 assign write_allowed=start_allowed&&!video_reserved;
 wire[31:0]lease_gen=cap_valid?cap_generation:ready_valid?ready_generation:active_generation;
 wire[31:0]lease_frame=cap_valid?cap_frame:ready_valid?ready_frame:active_frame;
 wire[31:0]lease_session=cap_valid?cap_session:ready_valid?ready_session:active_session;
 wire[31:0]shown_pixels=cap_valid?pixels_accepted:ready_valid?ready_pixels:32'd307200;
 wire[31:0]shown_writes=cap_valid?writes_acknowledged:ready_valid?ready_writes:32'd7200;
 wire shown_ready=ready_valid||(!cap_valid&&active_valid);
 wire shown_slot=cap_valid?cap_slot:ready_valid?ready_slot:active_slot;
 wire[31:0]flags={13'b0,1'b1,active_slot,shown_slot,rx_fault,rx_candidate,rx_configured,result_ready,
  recover_allowed,stop_allowed,arm_allowed,source_stopped,recovery_waiting_source,recovery_ready,
  capture_rejected,shown_ready,capture_busy,video_reserved,app_running,start_allowed};
 assign status_words={rx_raw_status,{rx_fault_code,writer_fault_code,liveness_fault,capture_error},
  result_frame,result_generation,result_session,result_source,shown_writes,shown_pixels,
  lease_session,lease_frame,lease_gen,next_gen,session_generation,flags,32'd1,32'h31444956};
 always @(posedge clk)begin
  if(rst)begin
   active_valid<=0;active_slot<=0;ready_valid<=0;ready_slot<=0;cap_valid<=0;cap_slot<=0;
   transfer_pending<=0;recover_pending<=0;release_frame<=0;endpoint_rearm_ack<=0;fault<=0;next_gen<=0;
   cap_generation<=0;cap_frame<=0;cap_session<=0;ready_generation<=0;ready_frame<=0;ready_session<=0;ready_pixels<=0;ready_writes<=0;
   active_generation<=0;active_frame<=0;active_session<=0;result_source<=0;result_session<=0;result_generation<=0;result_frame<=0;
  end else begin
   release_frame<=0;endpoint_rearm_ack<=0;
   if(arm_pulse)begin
    if(!arm_allowed||requested_generation!=next_gen)fault<=1;
    else begin
     cap_valid<=1;cap_slot<=active_valid&&!active_slot;cap_generation<=requested_generation;
     cap_frame<=requested_frame;cap_session<=session_generation+(app_running?1:0);next_gen<=next_gen+1'b1;
    end
   end
   if(cap_valid&&capture_frame_ready&&!transfer_pending)begin
    if(held_generation!=cap_generation||held_frame!=cap_frame||ready_valid||
       (active_valid&&active_slot==cap_slot))fault<=1;
    else begin
     ready_valid<=1;ready_slot<=cap_slot;ready_generation<=cap_generation;ready_frame<=cap_frame;ready_session<=cap_session;
     ready_pixels<=pixels_accepted;ready_writes<=writes_acknowledged;
     transfer_pending<=1;release_frame<=1;
    end
   end
   if(transfer_pending&&!capture_busy&&capture_arm_ready)begin cap_valid<=0;transfer_pending<=0;end
   if(start_pulse)begin
    if(!start_allowed)fault<=1;
    else begin
     active_valid<=ready_valid;active_slot<=ready_valid&&ready_slot;
     active_generation<=ready_valid?ready_generation:0;active_frame<=ready_valid?ready_frame:0;active_session<=session_generation;
     result_source<=ready_valid?1:0;result_session<=session_generation;
     result_generation<=ready_valid?ready_generation:0;result_frame<=ready_valid?ready_frame:0;ready_valid<=0;
    end
   end
   if(owner_rearm_ack)begin
    if(!capture_quiet)fault<=1;
    active_valid<=0;endpoint_rearm_ack<=1;
   end
   if(recover_pulse&&recover_allowed)recover_pending<=1;
   if(recover_pending&&recovery_done)begin cap_valid<=0;recover_pending<=0;end
   if(writer_fault)fault<=1;
  end
 end
endmodule
