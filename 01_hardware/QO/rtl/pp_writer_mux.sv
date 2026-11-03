// Two producers, ONE existing physical writer. Request selection is registered
// before valid; the selected producer owns every beat and the matching real B.
// No added physical credits or optimistic completion. Cold reset is coordinated
// with the existing HMIC bridge and controller quiescence.
module pp_writer_mux(
 input wire clk,rst,enable,
 input wire[1:0]s_req, output wire[1:0]s_ready,
 input wire[63:0]s_addr,input wire[13:0]s_beats,input wire[127:0]s_token,input wire[5:0]s_owner,
 input wire[1:0]s_wvalid,output wire[1:0]s_wready,
 input wire[511:0]s_data,input wire[63:0]s_strb,input wire[1:0]s_last,
 output wire[1:0]s_bvalid,input wire[1:0]s_bready,output wire[63:0]s_btoken,output wire s_berror,
 output wire req,input wire ready,output wire[31:0]addr,output wire[6:0]beats,
 output wire[63:0]token,output wire[2:0]owner,
 output wire wvalid,input wire wready,output wire[255:0]data,output wire[31:0]strb,output wire last,
 input wire bvalid,output wire bready,input wire[63:0]btoken,input wire berror,
 output wire video_idle,output reg fault
);
 localparam IDLE=0,REQUEST=1,DATA=2,RESPONSE=3;
 reg[1:0]state;reg chosen,turn;reg[6:0]count,length;reg[63:0]identity;
 assign req=state==REQUEST&&!rst;
 assign addr=chosen?s_addr[63:32]:s_addr[31:0];
 assign beats=chosen?s_beats[13:7]:s_beats[6:0];
 assign token=chosen?s_token[127:64]:s_token[63:0];
 assign owner=chosen?s_owner[5:3]:s_owner[2:0];
 assign s_ready=(req&&ready)?(chosen?2'b10:2'b01):2'b00;
 assign wvalid=state==DATA&&s_wvalid[chosen]&&!rst;
 assign data=chosen?s_data[511:256]:s_data[255:0];
 assign strb=chosen?s_strb[63:32]:s_strb[31:0];
 assign last=s_last[chosen];
 assign s_wready=(state==DATA&&wready&&!rst)?(chosen?2'b10:2'b01):2'b00;
 assign s_bvalid=(state==RESPONSE&&bvalid&&!rst)?(chosen?2'b10:2'b01):2'b00;
 assign bready=state==RESPONSE&&s_bready[chosen]&&!rst;
 assign s_btoken=btoken;
 assign s_berror=berror||(state==RESPONSE&&btoken!=identity)||fault;
 assign video_idle=(state==IDLE||!chosen)&&!s_req[1]&&!s_wvalid[1];
 always @(posedge clk)begin
  if(rst)begin state<=IDLE;chosen<=0;turn<=0;count<=0;length<=0;identity<=0;fault<=0;end
  else begin
   case(state)
    IDLE:if(enable&&!fault&&|s_req)begin
     chosen<=(&s_req)?turn:s_req[1];state<=REQUEST;
    end
    REQUEST:begin
     if(!s_req[chosen])fault<=1;
     if(req&&ready)begin length<=beats;identity<=token;count<=0;state<=DATA;
      if(beats==0||beats>16)fault<=1;
     end
    end
    DATA:if(wvalid&&wready)begin
     count<=count+1'b1;
     if(last!=(count+1'b1==length))fault<=1;
     if(count+1'b1==length)state<=RESPONSE;
    end
    RESPONSE:if(bvalid&&bready)begin
     if(berror||btoken!=identity)fault<=1;
     state<=IDLE;turn<=!chosen;
    end
   endcase
   if(bvalid&&state!=RESPONSE)fault<=1;
  end
 end
endmodule
