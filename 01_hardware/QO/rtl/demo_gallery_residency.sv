// Write-invalidated gallery validation and exact-normalization receipt.
// Cache allocation [0x0a010000,0x0a018000); raw GDB1 [0x0a000000,0x0a008220).
// Conservative invalidation covers the whole 128KiB reserved allocation.
module demo_gallery_residency(
 input wire clk,rst,ddr_ready,fault,qualify,
 input wire write_fire,input wire[31:0]write_address,input wire[6:0]write_beats,
 output wire verified
);
 reg valid,dirty_q;
 wire[32:0]last_byte={1'b0,write_address}+({26'b0,write_beats}<<5)-1'b1;
 wire dirty_now=write_fire&&(write_beats==0||last_byte[32]||
   ({1'b0,write_address}<33'h00a020000&&last_byte>=33'h00a000000));
 always @(posedge clk)begin
  if(rst||!ddr_ready||fault)begin valid<=0;dirty_q<=0;end
  else begin
   dirty_q<=dirty_now;
   if(dirty_now||dirty_q)valid<=0;
   else if(qualify&&!write_fire)valid<=1;
  end
 end
 assign verified=valid&&!dirty_q&&!dirty_now&&!rst&&ddr_ready&&!fault;
endmodule
