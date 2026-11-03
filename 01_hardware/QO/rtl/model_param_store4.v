// PA: four consumed lanes, depth 64; same 256 parameter records and async timing.
// Move phase selection before the RAM read; do not read sixteen unused lanes.
module model_param_store4(
 input wire clk,rst,write_valid,input wire[7:0]write_index,
 input wire[31:0]write_bias,write_mul,write_post_bias,input wire[5:0]write_shift,
 input wire[5:0]read_group,
 output wire[127:0]bias,mul,post_bias,output wire[23:0]shift
);
 // One accepted record is retained; write addresses/enables are bank-local.
 // RAM commits one edge later. Read forwarding preserves the original async
 // read value on every edge, including consecutive same-address writes/reset.
 reg[101:0]record_q;
 always @(posedge clk)record_q<={write_shift,write_post_bias,write_mul,write_bias};
 genvar lane,pair,half;
 generate for(lane=0;lane<4;lane=lane+1)begin:bank
  wire[101:0]q[0:1];
  wire[101:0]wd=record_q;
  for(half=0;half<2;half=half+1)begin:page
   (* syn_preserve=1 *) reg we_q;
   (* syn_preserve=1 *) reg[4:0]wa_q;
   always @(posedge clk)begin
    we_q<=write_valid&&!rst&&(write_index[1:0]==lane)&&(write_index[7]==half);
    wa_q<=write_index[6:2];
   end
   wire[101:0]raw;
   // A preceding accepted write must commit even if reset is now asserted.
   // Reset only cancels the new input, exactly as in the original memory.
   assign q[half]=(we_q&&wa_q==read_group[4:0])?record_q:raw;
   for(pair=0;pair<51;pair=pair+1)begin:bits2
    GTP_RAM32X2DP ram(.WCLK(clk),.WE(we_q),.WADDR(wa_q),
     .DI(wd[pair*2+:2]),.RADDR(read_group[4:0]),.DO(raw[pair*2+:2]));
   end
  end
  wire[101:0]selected=read_group[5]?q[1]:q[0];
  assign bias[lane*32+:32]=selected[31:0];
  assign mul[lane*32+:32]=selected[63:32];
  assign post_bias[lane*32+:32]=selected[95:64];
  assign shift[lane*6+:6]=selected[101:96];
 end endgenerate
endmodule
