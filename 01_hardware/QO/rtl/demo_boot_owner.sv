// One physical writer. BOOT regains ownership only through explicit host
// REARM after application COMMIT, result acknowledgement and physical drain.
// The physical controller/client sequence counters retain their identities.
// Faults block new
// commands while preserving the selected return/data drain path.
// All inputs are UI-domain signals. CPU/NPU done/fault/drain require proper
// mailbox CDC in the physical integration. This is not the complete board top.
module demo_boot_owner(
input wire clk,cold_rst,start_request,memory_drained,safety_ready,
input wire rearm_request,
output wire rearm_allowed,output reg rearm_ack,output reg[31:0]session_generation,
input wire application_done,application_drained,application_fault,
output reg application_hold /* synthesis syn_preserve = 1 */,
 output wire application_hold_next,
output wire app_selected,boot_allowed,
output reg done,fault,output wire[2:0]phase,
input wire boot_rd_valid,
input wire app_rd_valid,
output wire p_rd_valid,
output wire boot_rd_ready,
output wire app_rd_ready,
input wire p_rd_ready,
input wire[31:0] boot_rd_addr,
input wire[31:0] app_rd_addr,
output wire[31:0] p_rd_addr,
input wire[6:0] boot_rd_beats,
input wire[6:0] app_rd_beats,
output wire[6:0] p_rd_beats,
input wire[63:0] boot_rd_token,
input wire[63:0] app_rd_token,
output wire[63:0] p_rd_token,
input wire[2:0] boot_rd_owner,
input wire[2:0] app_rd_owner,
output wire[2:0] p_rd_owner,
output wire boot_r_valid,
output wire app_r_valid,
input wire p_r_valid,
input wire boot_r_ready,
input wire app_r_ready,
output wire p_r_ready,
output wire[255:0] boot_r_data,
output wire[255:0] app_r_data,
input wire[255:0] p_r_data,
output wire[63:0] boot_r_token,
output wire[63:0] app_r_token,
input wire[63:0] p_r_token,
output wire[6:0] boot_r_index,
output wire[6:0] app_r_index,
input wire[6:0] p_r_index,
output wire boot_r_last,
output wire app_r_last,
input wire p_r_last,
output wire boot_r_error,
output wire app_r_error,
input wire p_r_error,
input wire boot_wr_valid,
input wire app_wr_valid,
output wire p_wr_valid,
output wire boot_wr_ready,
output wire app_wr_ready,
input wire p_wr_ready,
input wire[31:0] boot_wr_addr,
input wire[31:0] app_wr_addr,
output wire[31:0] p_wr_addr,
input wire[6:0] boot_wr_beats,
input wire[6:0] app_wr_beats,
output wire[6:0] p_wr_beats,
input wire[63:0] boot_wr_token,
input wire[63:0] app_wr_token,
output wire[63:0] p_wr_token,
input wire[2:0] boot_wr_owner,
input wire[2:0] app_wr_owner,
output wire[2:0] p_wr_owner,
input wire boot_w_valid,
input wire app_w_valid,
output wire p_w_valid,
output wire boot_w_ready,
output wire app_w_ready,
input wire p_w_ready,
input wire[255:0] boot_w_data,
input wire[255:0] app_w_data,
output wire[255:0] p_w_data,
input wire[31:0] boot_w_strb,
input wire[31:0] app_w_strb,
output wire[31:0] p_w_strb,
input wire boot_w_last,
input wire app_w_last,
output wire p_w_last,
output wire boot_b_valid,
output wire app_b_valid,
input wire p_b_valid,
input wire boot_b_ready,
input wire app_b_ready,
output wire p_b_ready,
output wire[63:0] boot_b_token,
output wire[63:0] app_b_token,
input wire[63:0] p_b_token,
output wire boot_b_error,
output wire app_b_error,
input wire p_b_error
);
 localparam BOOT=0,ARM=1,RUN=2,DRAIN=3,COMPLETE=4,FAULT=5,REARM=6;
 reg[2:0]state,arm_count;
 reg selected,quiet,epoch_reset;
 reg[5:0]reset_count;
 assign phase=state;
 assign app_selected=selected;
 // Same-cycle hold, computed from next state instead of the shared DDR mux select.
 reg[2:0]next_state;
 reg next_selected,next_epoch_reset;
 assign application_hold_next=!next_selected||next_state==ARM||next_epoch_reset;
 assign rearm_allowed=state==COMPLETE&&done&&!fault&&safety_ready&&
  application_drained&&memory_drained&&!p_r_valid&&!p_b_valid&&session_generation!=32'hffffffff;
 assign boot_allowed=state==BOOT&&!fault&&safety_ready;
 wire allow_command=!fault&&safety_ready&&((!selected&&state==BOOT)||(selected&&(state==RUN||state==DRAIN)));
 always @*begin
  next_state=state;next_selected=selected;next_epoch_reset=epoch_reset;
  if(cold_rst)begin next_state=BOOT;next_selected=0;next_epoch_reset=0;end
  else begin
   if(state==BOOT&&start_request)begin
    if(memory_drained&&safety_ready&&!fault)begin next_selected=1;next_state=ARM;end
    else next_state=FAULT;
   end
   if(state==ARM&&arm_count==3)next_state=RUN;
   if(state==RUN&&application_done)next_state=DRAIN;
   if(state==DRAIN&&quiet&&application_drained&&memory_drained)next_state=COMPLETE;
   if(rearm_request)begin
    if(rearm_allowed)begin next_state=REARM;next_epoch_reset=1;end
    else next_state=FAULT;
   end
   if(state==REARM)begin
    if(!application_drained||!memory_drained||p_r_valid||p_b_valid)next_state=FAULT;
    else if(reset_count==31)begin next_state=BOOT;next_selected=0;next_epoch_reset=0;end
   end
   if(selected&&(application_fault||!safety_ready))next_state=FAULT;
  end
 end
 always @(posedge clk)begin
  state<=next_state;selected<=next_selected;epoch_reset<=next_epoch_reset;
  application_hold<=application_hold_next;
  if(cold_rst)begin arm_count<=0;fault<=0;done<=0;quiet<=0;
   reset_count<=0;rearm_ack<=0;session_generation<=0;end
  else begin
   rearm_ack<=0;
   if(state==BOOT&&start_request)begin
    if(memory_drained&&safety_ready&&!fault)begin arm_count<=0;end
    else begin fault<=1;end
   end
   if(state==ARM)begin
    if(arm_count!=3)arm_count<=arm_count+1'b1;
   end
   if(state==RUN&&application_done)begin quiet<=0;end
   if(state==DRAIN)begin
    quiet<=application_drained&&memory_drained;
    if(quiet&&application_drained&&memory_drained)begin done<=1;end
   end
   if(rearm_request)begin
    if(rearm_allowed)begin reset_count<=0;end
    else begin fault<=1;done<=0;end
   end
   if(state==REARM)begin
    // All application clocks have time to observe reset before source reuse.
    // An unexpected late return poisons the epoch instead of reaching BOOT.
    if(!application_drained||!memory_drained||p_r_valid||p_b_valid)begin fault<=1;done<=0;end
    else if(reset_count==31)begin
     done<=0;
     session_generation<=session_generation+1'b1;rearm_ack<=1;
    end else reset_count<=reset_count+1'b1;
   end
   if(selected&&(application_fault||!safety_ready))begin fault<=1;done<=0;end
  end
 end
 assign p_rd_valid=(selected?app_rd_valid:boot_rd_valid)&&!cold_rst&&allow_command;
 assign boot_rd_ready=!cold_rst&&!selected&&allow_command&&p_rd_ready;
 assign app_rd_ready=!cold_rst&&selected&&allow_command&&p_rd_ready;
 assign p_rd_addr=(selected?app_rd_addr:boot_rd_addr);
 assign p_rd_beats=(selected?app_rd_beats:boot_rd_beats);
 assign p_rd_token=(selected?app_rd_token:boot_rd_token);
 assign p_rd_owner=(selected?app_rd_owner:boot_rd_owner);
 assign boot_r_valid=!cold_rst&&!selected&&p_r_valid;
 assign app_r_valid=!cold_rst&&selected&&p_r_valid;
 assign p_r_ready=(selected?app_r_ready:boot_r_ready)&&!cold_rst;
 assign boot_r_data=p_r_data;
 assign app_r_data=p_r_data;
 assign boot_r_token=p_r_token;
 assign app_r_token=p_r_token;
 assign boot_r_index=p_r_index;
 assign app_r_index=p_r_index;
 assign boot_r_last=p_r_last;
 assign app_r_last=p_r_last;
 assign boot_r_error=p_r_error;
 assign app_r_error=p_r_error;
 assign p_wr_valid=(selected?app_wr_valid:boot_wr_valid)&&!cold_rst&&allow_command;
 assign boot_wr_ready=!cold_rst&&!selected&&allow_command&&p_wr_ready;
 assign app_wr_ready=!cold_rst&&selected&&allow_command&&p_wr_ready;
 assign p_wr_addr=(selected?app_wr_addr:boot_wr_addr);
 assign p_wr_beats=(selected?app_wr_beats:boot_wr_beats);
 assign p_wr_token=(selected?app_wr_token:boot_wr_token);
 assign p_wr_owner=(selected?app_wr_owner:boot_wr_owner);
 assign p_w_valid=(selected?app_w_valid:boot_w_valid)&&!cold_rst;
 assign boot_w_ready=!cold_rst&&!selected&&p_w_ready;
 assign app_w_ready=!cold_rst&&selected&&p_w_ready;
 assign p_w_data=(selected?app_w_data:boot_w_data);
 assign p_w_strb=(selected?app_w_strb:boot_w_strb);
 assign p_w_last=(selected?app_w_last:boot_w_last);
 assign boot_b_valid=!cold_rst&&!selected&&p_b_valid;
 assign app_b_valid=!cold_rst&&selected&&p_b_valid;
 assign p_b_ready=(selected?app_b_ready:boot_b_ready)&&!cold_rst;
 assign boot_b_token=p_b_token;
 assign app_b_token=p_b_token;
 assign boot_b_error=p_b_error;
 assign app_b_error=p_b_error;
endmodule
