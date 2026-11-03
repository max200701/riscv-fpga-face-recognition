`timescale 1ns/1ps
// Generated from ELF physical load image; do not edit.
module boot_rom(input wire clk,rst_n,valid,input wire [13:0] addr,
 input wire b_cmd_valid,input wire [13:0] b_addr,output wire b_cmd_ready,
 output wire b_valid,b_last,input wire b_ready,output reg [31:0] b_data,
 output reg ready,output reg [31:0] rdata);
 reg [31:0] image[0:16383] /* synthesis syn_ramstyle = "block_ram" */;
 initial $readmemh("application_rom.hex",image);
 wire b_active,b_read;wire [13:0] b_mem_addr;
 burst_read_sequencer sequencer(.clk(clk),.rst_n(rst_n),.cmd_valid(b_cmd_valid),.cmd_addr(b_addr),
 .cmd_ready(b_cmd_ready),.r_valid(b_valid),.r_last(b_last),.r_ready(b_ready),
 .mem_read(b_read),.mem_addr(b_mem_addr),.active(b_active));
 wire [13:0] read_addr=b_read ? b_mem_addr : addr;
 reg [31:0] rom_q;
 always @(posedge clk)begin
  if(!rst_n)ready<=0;else ready<=valid && !ready && !b_active;
  if(b_read || (rst_n && valid && !ready && !b_active))begin
   rom_q<=image[read_addr];
  end
 end
 always @* begin rdata=rom_q;b_data=rom_q;end
endmodule
