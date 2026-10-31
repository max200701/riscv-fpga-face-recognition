// Descriptor-driven per-group/channel-block/spatial-block/precision-pass loops.
// All operands and parameters of a channel block remain immutable until its
// jobs finish. Completion is explicitly split into posted and external visibility.
module resident_layer_scheduler(
 input wire clk,rst,start,
 input wire[31:0] cfg_plane,input wire[15:0]cfg_groups,cfg_n,cfg_k,
 input wire[3:0]cfg_mt,cfg_nt,input wire cfg_wide,
 output wire ready,output reg posted_done,output reg done,output reg[3:0]error,
 output wire job_valid,input wire job_ready,job_done,job_error,input wire visibility_ack,
 output wire[15:0]job_group,job_channel,job_k,output wire[31:0]job_spatial,job_id,
 output wire[8:0]job_m,job_n,output wire[3:0]job_mt,job_nt,
 output wire job_high,job_first,job_last,job_new_weights,
 output reg[63:0]jobs,weight_words,saved_weight_words
);
 localparam IDLE=0,CHECK=1,ISSUE=2,WAIT_JOB=3,VISIBLE=4;
 reg[2:0]state;reg[31:0]plane,spatial,id;reg[15:0]groups,n,k,g,ch;
 reg[3:0]mt,nt;reg wide,high;
 wire[31:0]remain_m=plane-spatial;wire[15:0]remain_n=n-ch;
 wire[8:0]take_m=remain_m<mt*32?remain_m:mt*32;
 wire[8:0]take_n=remain_n<nt*32?remain_n:nt*32;
 assign ready=!rst&&state==IDLE&&error==0;assign job_valid=!rst&&state==ISSUE&&error==0;
 assign job_group=g;assign job_channel=ch;assign job_k=k;assign job_spatial=spatial;assign job_id=id;
 assign job_m=take_m;assign job_n=take_n;assign job_mt=({1'b0,take_m}+31)>>5;assign job_nt=({1'b0,take_n}+31)>>5;
 assign job_high=high;assign job_first=!high;assign job_last=!wide||high;assign job_new_weights=spatial==0&&!high;
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;posted_done<=0;done<=0;error<=0;plane<=0;spatial<=0;id<=0;groups<=0;n<=0;k<=0;g<=0;ch<=0;
   mt<=0;nt<=0;wide<=0;high<=0;jobs<=0;weight_words<=0;saved_weight_words<=0;
  end else begin
   posted_done<=0;done<=0;
   if((job_done||job_error)&&state!=WAIT_JOB)error<=3;
   if(error==0)case(state)
    IDLE:if(start)begin
     plane<=cfg_plane;groups<=cfg_groups;n<=cfg_n;k<=cfg_k;mt<=cfg_mt;nt<=cfg_nt;wide<=cfg_wide;
     spatial<=0;id<=0;g<=0;ch<=0;high<=0;state<=CHECK;
    end
    CHECK:if(plane==0||plane>1048576||groups==0||groups>4096||n==0||n>4096||k==0||k>4096||
      mt==0||mt>8||nt==0||nt>8||mt*k>4096||nt*k>4096)begin error<=1;state<=IDLE;end
      else state<=ISSUE;
    ISSUE:if(job_ready)begin
     jobs<=jobs+1;state<=WAIT_JOB;
     if(job_new_weights)weight_words<=weight_words+job_nt*k;else saved_weight_words<=saved_weight_words+job_nt*k;
    end
    WAIT_JOB:if(job_error)begin error<=2;state<=IDLE;end
    else if(job_done)begin
     id<=id+1;
     if(wide&&!high)begin high<=1;state<=ISSUE;end
     else begin
      high<=0;
      if(spatial+take_m<plane)begin spatial<=spatial+take_m;state<=ISSUE;end
      else begin
       spatial<=0;
       if(ch+take_n<n)begin ch<=ch+take_n;state<=ISSUE;end
       else begin
        ch<=0;
        if(g+1<groups)begin g<=g+1;state<=ISSUE;end
        else begin posted_done<=1;state<=VISIBLE;end
       end
      end
     end
    end
    VISIBLE:if(visibility_ack)begin done<=1;state<=IDLE;end
   endcase
  end
 end
endmodule
