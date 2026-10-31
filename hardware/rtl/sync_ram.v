`timescale 1ns/1ps
// 64 KiB, four independent byte lanes. No reset/initialization of storage.
// Reads remain synchronous; stores acknowledge on their first available edge.
// All byte writes commit only on valid && ready.
// The core must keep valid/address/data stable until that completion edge.
// Actual block-RAM inference must be checked in PDS Device Map.
// claude_c02 c4: one physical port per lane (16 DRM36K instead of a 32-DRM
// mirrored instruction copy). The data side (single access and D-cache burst)
// keeps the port with unchanged timing; instruction reads (single and I-cache
// burst) use it only in cycles the data side leaves free. Each side holds its
// own last sample, so backpressure behaviour is unchanged on both sides.
module sync_ram(input wire clk,rst_n,valid,write,
 input wire [13:0] word_addr,input wire [31:0] wdata,input wire [3:0] wstrb,
 input wire b_cmd_valid,input wire [13:0] b_addr,output wire b_cmd_ready,
 output wire b_valid,b_last,input wire b_ready,output wire [31:0] b_data,
 output wire ready,output wire [31:0] rdata,
 input wire i_valid,input wire [13:0] i_addr,output reg i_ready,output wire [31:0] i_rdata,
 input wire ib_cmd_valid,input wire [13:0] ib_addr,output wire ib_cmd_ready,
 output wire ib_valid,ib_last,input wire ib_ready,output wire [31:0] ib_data);
 // ADS Synthesis User Guide section 5.16: explicitly select block RAM.
 reg [7:0] lane0[0:16383] /* synthesis syn_ramstyle = "block_ram" */;
 reg [7:0] lane1[0:16383] /* synthesis syn_ramstyle = "block_ram" */;
 reg [7:0] lane2[0:16383] /* synthesis syn_ramstyle = "block_ram" */;
 reg [7:0] lane3[0:16383] /* synthesis syn_ramstyle = "block_ram" */;
 wire b_active,b_read;wire[13:0] b_mem_addr;
 // The SoC arbitrates normal and burst transactions; share one synchronous
 // read/write address port for the data side, as in the v0.7 baseline.
 reg read_ready;
 assign ready=rst_n && valid && (write ? !b_active : read_ready);
 wire normal_read=rst_n && valid && !read_ready && !write && !b_active;
 wire [13:0] read_addr=b_read ? b_mem_addr : word_addr;
 burst_read_sequencer sequencer(.clk(clk),.rst_n(rst_n),.cmd_valid(b_cmd_valid),.cmd_addr(b_addr),
  .cmd_ready(b_cmd_ready),.r_valid(b_valid),.r_last(b_last),.r_ready(b_ready),
  .mem_read(b_read),.mem_addr(b_mem_addr),.active(b_active));
 wire d_rd=b_read || normal_read;
 wire d_wr=rst_n && valid && ready && write;
 wire grant=!(d_rd || d_wr);
 // Instruction side, granted only in data-idle cycles.
 wire ib_active,ib_read;wire [13:0] ib_mem_addr;
 wire [13:0] i_read_addr=ib_read ? ib_mem_addr : i_addr;
 wire i_single=rst_n && i_valid && !i_ready && !ib_active && grant;
 wire i_rd=ib_read || i_single;
 burst_read_sequencer_gated instruction_sequencer(.clk(clk),.rst_n(rst_n),.grant(grant),
  .cmd_valid(ib_cmd_valid),.cmd_addr(ib_addr),.cmd_ready(ib_cmd_ready),
  .r_valid(ib_valid),.r_last(ib_last),.r_ready(ib_ready),
  .mem_read(ib_read),.mem_addr(ib_mem_addr),.active(ib_active));
 wire [13:0] addr=grant ? i_read_addr : read_addr;
 reg [31:0] ram_q,d_hold,i_hold;
 reg d_sample,i_sample;
 always @(posedge clk) begin
   if(d_rd || i_rd)
     ram_q<={lane3[addr],lane2[addr],lane1[addr],lane0[addr]};
   if(d_wr) begin
     if(wstrb[0]) lane0[addr]<=wdata[7:0];
     if(wstrb[1]) lane1[addr]<=wdata[15:8];
     if(wstrb[2]) lane2[addr]<=wdata[23:16];
     if(wstrb[3]) lane3[addr]<=wdata[31:24];
   end
   if(!rst_n) read_ready<=0;
   else read_ready<=valid && !write && !read_ready && !b_active;
   if(!rst_n)i_ready<=0;else i_ready<=i_single;
   d_sample<=d_rd;i_sample<=i_rd;
   if(d_sample)d_hold<=ram_q;
   if(i_sample)i_hold<=ram_q;
 end
 assign rdata=d_sample ? ram_q : d_hold;assign b_data=rdata;
 // FENCE.I orders completed stores before later fetches and invalidates the I cache.
 assign i_rdata=i_sample ? ram_q : i_hold;assign ib_data=i_rdata;
endmodule

// burst_read_sequencer with a port grant: a beat is read only in a granted cycle.
module burst_read_sequencer_gated(
 input wire clk,rst_n,grant,cmd_valid,input wire [13:0] cmd_addr,output wire cmd_ready,
 output reg r_valid,r_last,input wire r_ready,
 output wire mem_read,output wire [13:0] mem_addr,output reg active);
 reg [13:0] base;
 reg [3:0] issued;
 assign cmd_ready=rst_n && !active && !r_valid;
 assign mem_read=rst_n && grant && active && issued<8 && (!r_valid || r_ready);
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
