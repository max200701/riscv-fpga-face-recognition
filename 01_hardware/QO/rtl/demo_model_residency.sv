// Cold validation is retained; a clean warm epoch reuses its result. This bit
// survives application REARM, but never cold reset, DDR loss or a system fault.
// Observe accepted writes at the common physical-writer request boundary.
module demo_model_residency(
 input wire clk,rst,ddr_ready,fault,qualify,
 input wire write_fire,input wire[31:0]write_address,input wire[6:0]write_beats,
 output wire verified
);
 reg valid,dirty_q;
 wire[32:0]last_byte={1'b0,write_address}+({26'b0,write_beats}<<5)-1'b1;
 // Conservative complete allocation regions. They contain all six immutable
 // package/assets/program extents, but exclude image/crop/arena/gallery/terms.
 function automatic protected_region(input[32:0]a);
  begin protected_region=a[32]||a[31:24]==8'h00||a[31:22]==10'h004||
    (a[31:24]>=8'h06&&a[31:24]<=8'h09);end
 endfunction
 always @(posedge clk)begin
  if(rst||!ddr_ready||fault)begin valid<=0;dirty_q<=0;end
  else begin
   dirty_q<=write_fire&&(write_beats==0||protected_region({1'b0,write_address})||protected_region(last_byte));
   if(dirty_q)valid<=0;
   else if(qualify)valid<=1;
  end
 end
 assign verified=valid&&!dirty_q;
endmodule
