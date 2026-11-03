`timescale 1ns/1ps
// Fixed eight-word INCR read burst, one accepted command then eight beats.
// A synchronous memory reads mem_addr on each mem_read edge and its registered
// data accompanies r_valid. Backpressure holds both data and last stable.
module burst_read_sequencer(
 input wire clk,rst_n,cmd_valid,input wire [13:0] cmd_addr,output wire cmd_ready,
 output reg r_valid,r_last,input wire r_ready,
 output wire mem_read,output wire [13:0] mem_addr,output reg active);
 reg [13:0] base;
 reg [3:0] issued;
 assign cmd_ready=rst_n && !active && !r_valid;
 assign mem_read=rst_n && active && issued<8 && (!r_valid || r_ready);
 assign mem_addr=base+issued;
 always @(posedge clk)begin
   if(!rst_n)begin active<=0;issued<=0;base<=0;r_valid<=0;r_last<=0;end
   else begin
     if(cmd_valid && cmd_ready)begin active<=1;base<=cmd_addr;issued<=0;end
     if(r_valid && r_ready)begin r_valid<=0;if(r_last)active<=0;end
     if(mem_read)begin issued<=issued+1'b1;r_valid<=1;r_last<=issued==7;end
   end
 end
endmodule
