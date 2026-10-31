// Exact original per-channel parameter tables, one read port per interleaved bank.
// q_base low four bits are zero; lane l always consumes parameter[group*16+l].
// Asynchronous read and no added register; reset blocks writes but does not erase RAM.
module model_param_store16(
 input wire clk,rst,write_valid,input wire[7:0]write_index,
 input wire[31:0]write_bias,write_mul,write_post_bias,input wire[5:0]write_shift,
 input wire[3:0]read_group,
 output wire[511:0]bias,mul,post_bias,output wire[95:0]shift
);
 genvar lane,pair;
 generate for(lane=0;lane<16;lane=lane+1)begin:bank
  wire we=write_valid&&!rst&&(write_index[3:0]==lane);
  for(pair=0;pair<16;pair=pair+1)begin:bits
   GTP_RAM32X2DP b(.WCLK(clk),.WE(we),.WADDR({1'b0,write_index[7:4]}),.DI(write_bias[2*pair+:2]),.RADDR({1'b0,read_group}),.DO(bias[lane*32+pair*2+:2]));
   GTP_RAM32X2DP m(.WCLK(clk),.WE(we),.WADDR({1'b0,write_index[7:4]}),.DI(write_mul[2*pair+:2]),.RADDR({1'b0,read_group}),.DO(mul[lane*32+pair*2+:2]));
   GTP_RAM32X2DP p(.WCLK(clk),.WE(we),.WADDR({1'b0,write_index[7:4]}),.DI(write_post_bias[2*pair+:2]),.RADDR({1'b0,read_group}),.DO(post_bias[lane*32+pair*2+:2]));
  end
  for(pair=0;pair<3;pair=pair+1)begin:shift_bits
   GTP_RAM32X2DP s(.WCLK(clk),.WE(we),.WADDR({1'b0,write_index[7:4]}),.DI(write_shift[2*pair+:2]),.RADDR({1'b0,read_group}),.DO(shift[lane*6+pair*2+:2]));
  end
 end endgenerate
endmodule
