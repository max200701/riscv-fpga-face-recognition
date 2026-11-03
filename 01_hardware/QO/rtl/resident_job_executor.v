// Hardware consumer of scheduler jobs. External parameter service acknowledges
// each new channel block; external sink_done means that block's results reached
// its chosen sink (use actual posted completion when wired to a DMA writer).
// None of these acknowledgements manufacture physical DDR visibility.
module resident_job_executor(
 input wire clk,rst,job_valid,job_new_weights,job_last,
 output wire job_ready,output reg job_done,output reg job_error,
 output wire parameters_request,input wire parameters_done,
 output wire load_start,input wire load_ready,load_done,
 output wire compute_start,input wire compute_ready,compute_done,outputs_idle,
 output wire release_valid,input wire release_ready,
 input wire sink_done,fault,output wire[3:0]state_debug
);
 localparam IDLE=0,PARAMS=1,LOAD=2,LOAD_WAIT=3,RUN=4,RUN_WAIT=5,RELEASE=6,ACK=7,FAILED=8;
 reg[3:0]state;reg arithmetic_done,sink_seen;
 assign state_debug=state;
 assign job_ready=!rst&&state==IDLE;
 assign parameters_request=!rst&&state==PARAMS;
 assign load_start=!rst&&state==LOAD;
 assign compute_start=!rst&&state==RUN;
 assign release_valid=!rst&&state==RELEASE;
 always @(posedge clk)begin
  if(rst)begin state<=IDLE;job_done<=0;job_error<=0;arithmetic_done<=0;sink_seen<=0;end
  else begin
   job_done<=0;job_error<=0;
   if(fault&&state!=FAILED)begin job_error<=1;state<=FAILED;end
   else case(state)
    IDLE:if(job_valid)begin state<=job_new_weights?PARAMS:LOAD;arithmetic_done<=0;sink_seen<=0;end
    PARAMS:if(parameters_done)state<=LOAD;
    LOAD:if(load_ready)state<=LOAD_WAIT;
    LOAD_WAIT:if(load_done)state<=RUN;
    RUN:if(compute_ready)begin state<=RUN_WAIT;arithmetic_done<=0;sink_seen<=sink_done;end
    RUN_WAIT:begin
     if(compute_done)arithmetic_done<=1;if(sink_done)sink_seen<=1;
     if((arithmetic_done||compute_done)&&outputs_idle&&(!job_last||sink_seen||sink_done))state<=RELEASE;
    end
    RELEASE:if(release_ready)state<=ACK;
    ACK:begin job_done<=1;state<=IDLE;end
   endcase
  end
 end
endmodule
