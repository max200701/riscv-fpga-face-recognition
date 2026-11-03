`timescale 1ns/1ps
// One 64 KiB ROM image with two independent synchronous read ports (instruction
// and data). Each port keeps the exact boot_rom handshake: a single read is
// ready one edge after valid, an 8-beat burst owns the port while active, and
// the registered word is held under backpressure. Replaces two boot_rom copies
// (16 DRM36K saved); a ROM has no write port, so there is no port collision.
module boot_rom_dp(input wire clk,rst_n,
 input wire i_valid,input wire [13:0] i_addr,output reg i_ready,output wire [31:0] i_rdata,
 input wire ib_cmd_valid,input wire [13:0] ib_addr,output wire ib_cmd_ready,
 output wire ib_valid,ib_last,input wire ib_ready,output wire [31:0] ib_data,
 input wire d_valid,input wire [13:0] d_addr,output reg d_ready,output wire [31:0] d_rdata,
 input wire db_cmd_valid,input wire [13:0] db_addr,output wire db_cmd_ready,
 output wire db_valid,db_last,input wire db_ready,output wire [31:0] db_data);
 reg [31:0] image[0:16383] /* synthesis syn_ramstyle = "block_ram" */;
 initial $readmemh("application_rom.hex",image);
 wire ib_active,ib_read,db_active,db_read;wire [13:0] ib_mem_addr,db_mem_addr;
 burst_read_sequencer i_sequencer(.clk(clk),.rst_n(rst_n),.cmd_valid(ib_cmd_valid),.cmd_addr(ib_addr),
 .cmd_ready(ib_cmd_ready),.r_valid(ib_valid),.r_last(ib_last),.r_ready(ib_ready),
 .mem_read(ib_read),.mem_addr(ib_mem_addr),.active(ib_active));
 burst_read_sequencer d_sequencer(.clk(clk),.rst_n(rst_n),.cmd_valid(db_cmd_valid),.cmd_addr(db_addr),
 .cmd_ready(db_cmd_ready),.r_valid(db_valid),.r_last(db_last),.r_ready(db_ready),
 .mem_read(db_read),.mem_addr(db_mem_addr),.active(db_active));
 wire [13:0] i_read_addr=ib_read ? ib_mem_addr : i_addr;
 wire [13:0] d_read_addr=db_read ? db_mem_addr : d_addr;
 reg [31:0] i_q,d_q;
 always @(posedge clk)begin
  if(!rst_n)i_ready<=0;else i_ready<=i_valid && !i_ready && !ib_active;
  if(ib_read || (rst_n && i_valid && !i_ready && !ib_active))i_q<=image[i_read_addr];
 end
 always @(posedge clk)begin
  if(!rst_n)d_ready<=0;else d_ready<=d_valid && !d_ready && !db_active;
  if(db_read || (rst_n && d_valid && !d_ready && !db_active))d_q<=image[d_read_addr];
 end
 assign i_rdata=i_q;assign ib_data=i_q;assign d_rdata=d_q;assign db_data=d_q;
endmodule
