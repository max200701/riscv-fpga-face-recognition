// Two owned fragment copies. Buffer acceptance is not a posted-write ACK.
// Registered occupancy cuts downstream READY out of the upstream ready path.
module graph_fragment_fifo(
 input wire clk,rst,in_valid,output wire in_ready,
 input wire[31:0]in_addr,input wire[127:0]in_data,
 input wire[4:0]in_bytes,input wire in_last,input wire[31:0]in_tag,
 output wire out_valid,input wire out_ready,
 output wire[31:0]out_addr,output wire[127:0]out_data,
 output wire[4:0]out_bytes,output wire out_last,output wire[31:0]out_tag
);
 reg[197:0]payload[0:1];reg head,tail;reg[1:0]count;
 wire push=in_valid&&in_ready,pop=out_valid&&out_ready;
 assign in_ready=!rst&&count<2;
 assign out_valid=!rst&&count!=0;
 assign {out_addr,out_data,out_bytes,out_last,out_tag}=payload[head];
 always @(posedge clk)begin
  if(rst)begin head<=0;tail<=0;count<=0;end
  else begin
   if(push)begin payload[tail]<={in_addr,in_data,in_bytes,in_last,in_tag};tail<=~tail;end
   if(pop)head<=~head;
   case({push,pop})
    2'b10:count<=count+1'b1;
    2'b01:count<=count-1'b1;
   endcase
  end
 end
endmodule
