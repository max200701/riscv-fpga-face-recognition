// Two-slot ready/valid buffer. in_ready has no combinational out_ready path.
// It is local buffering only, never physical ACK or final resource release.
module pf_elastic2 #(parameter WIDTH=32)(
 input wire clk,rst,in_valid,output wire in_ready,input wire[WIDTH-1:0]in_data,
 output wire out_valid,input wire out_ready,output wire[WIDTH-1:0]out_data
);
 reg front_valid,spill_valid;
 reg[WIDTH-1:0]front,spill;
 wire push=in_valid&&in_ready,pop=out_valid&&out_ready;
 assign in_ready=!rst&&!spill_valid;
 assign out_valid=!rst&&front_valid;assign out_data=front;
 always @(posedge clk)begin
  if(push&&(!front_valid||pop))front<=in_data;
  else if(pop&&spill_valid)front<=spill;
  if(push&&front_valid&&!pop)spill<=in_data;
  if(rst)begin front_valid<=0;spill_valid<=0;end
  else case({push,pop})
   2'b10:if(front_valid)spill_valid<=1;else front_valid<=1;
   2'b01:if(spill_valid)spill_valid<=0;else front_valid<=0;
   2'b11:front_valid<=1;
   default:;
  endcase
 end
endmodule
