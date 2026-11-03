// Exact sat32 -> signed32 x unsigned32 -> original rounding/clamp semantics.
// PI: eight elastic stages, initiation interval one. Two additional registers
// split the former cascaded full multiply into 16x16 products and exact sums.
module quant_stream_lanes #(parameter META_W=32,LANES=16)(
 input wire clk,rst,in_valid,output wire in_ready,
 input wire[LANES*32-1:0]accum,bias,multiplier,
 input wire model_q16,input wire[LANES*32-1:0]post_bias,
 input wire[LANES*6-1:0]shift,input wire signed[7:0]zero_point,clamp_min,clamp_max,
 input wire[META_W-1:0]in_meta,
 output wire out_valid,input wire out_ready,
 output wire[LANES*8-1:0]out_data,output wire[META_W-1:0]out_meta,
 output wire[LANES*32-1:0]out_wide,output wire out_error
);
 reg[7:0]vp;reg[META_W-1:0]meta[0:7];
 wire advance=!vp[7]||out_ready;
 assign in_ready=!rst&&advance;assign out_valid=!rst&&vp[7];assign out_meta=meta[7];
 integer s;
 always @(posedge clk)begin
  if(rst)begin vp<=0;for(s=0;s<8;s=s+1)meta[s]<=0;end
  else if(advance)begin vp<={vp[6:0],in_valid};meta[0]<=in_meta;
   for(s=1;s<8;s=s+1)meta[s]<=meta[s-1];end
 end
 wire[LANES-1:0]lane_errors;assign out_error=out_valid&&(|lane_errors);
 genvar l;
 generate for(l=0;l<LANES;l=l+1)begin:lane
  reg signed[32:0]add0;reg signed[31:0]biased1;
  reg[31:0]mul0,mul1,p00,p01;reg signed[31:0]p10,p11;
  reg[47:0]lo3;reg signed[47:0]hi3;reg signed[63:0]product4;
  reg[63:0]magnitude5,scaled6;
  reg sign5,sign6,round5,round6;
  reg[5:0]sh[0:6];reg[6:0]modep,errorp;reg signed[31:0]pb[0:6];
  reg signed[7:0]zp[0:6],lo[0:6],hi[0:6];
  reg[7:0]result7;reg[31:0]wide7;reg error7;
  wire[63:0]abs_product=product4[63]?(~product4+64'd1):product4;
  wire[8:0]rounded_small={1'b0,scaled6[7:0]}+round6;
  wire large_magnitude=(|scaled6[63:8])||rounded_small[8];
  wire signed[9:0]restored=sign6?-$signed({1'b0,rounded_small}):$signed({1'b0,rounded_small});
  wire signed[9:0]with_zero=restored+$signed(zp[6]);
  wire[64:0]full_rounded={1'b0,scaled6}+round6;
  wire signed[65:0]full_signed=sign6?-$signed({1'b0,full_rounded}):$signed({1'b0,full_rounded});
  wire signed[65:0]model_result=full_signed+$signed(pb[6]);
  assign out_data[l*8+:8]=result7;assign out_wide[l*32+:32]=wide7;assign lane_errors[l]=error7;
  integer j;
  always @(posedge clk)begin
   if(rst)begin
    add0<=0;biased1<=0;mul0<=0;mul1<=0;p00<=0;p01<=0;p10<=0;p11<=0;
    lo3<=0;hi3<=0;product4<=0;magnitude5<=0;scaled6<=0;
    sign5<=0;sign6<=0;round5<=0;round6<=0;result7<=0;wide7<=0;error7<=0;modep<=0;errorp<=0;
    for(j=0;j<7;j=j+1)begin sh[j]<=0;pb[j]<=0;zp[j]<=0;lo[j]<=0;hi[j]<=0;end
   end else if(advance)begin
    if(in_valid)begin
     add0<=$signed({accum[l*32+31],accum[l*32+:32]})+$signed({bias[l*32+31],bias[l*32+:32]});
     mul0<=multiplier[l*32+:32];sh[0]<=model_q16?6'd24:shift[l*6+:6];
     zp[0]<=zero_point;lo[0]<=clamp_min;hi[0]<=clamp_max;modep[0]<=model_q16;
     pb[0]<=post_bias[l*32+:32];errorp[0]<=0;
    end
    for(j=1;j<7;j=j+1)begin
     sh[j]<=sh[j-1];zp[j]<=zp[j-1];lo[j]<=lo[j-1];hi[j]<=hi[j-1];
     pb[j]<=pb[j-1];modep[j]<=modep[j-1];errorp[j]<=errorp[j-1];
    end
    if(vp[0])begin
     if(add0>33'sd2147483647)biased1<=32'h7fffffff;
     else if(add0 < -33'sd2147483648)biased1<=32'h80000000;
     else biased1<=add0[31:0];
     errorp[1]<=modep[0]&&(add0>33'sd2147483647||add0 < -33'sd2147483648);
     mul1<=mul0;
    end
    if(vp[1])begin
     p00<=biased1[15:0]*mul1[15:0];
     p01<=biased1[15:0]*mul1[31:16];
     p10<=$signed(biased1[31:16])*$signed({1'b0,mul1[15:0]});
     p11<=$signed(biased1[31:16])*$signed({1'b0,mul1[31:16]});
    end
    if(vp[2])begin
     lo3<={16'b0,p00}+{p01,16'b0};
     hi3<=$signed({{16{p10[31]}},p10})+$signed({p11,16'b0});
    end
    if(vp[3])product4<={16'b0,lo3}+{hi3,16'b0};
    if(vp[4])begin
     magnitude5<=abs_product;sign5<=product4[63];
     round5<=modep[4]?(abs_product[23:0]>24'h800000||(abs_product[23:0]==24'h800000&&abs_product[24])):
              (sh[4]!=0&&abs_product[sh[4]-1'b1]);
    end
    if(vp[5])begin scaled6<=magnitude5>>sh[5];sign6<=sign5;round6<=round5;end
    if(vp[6])begin
     result7<=large_magnitude?(sign6?lo[6]:hi[6]):with_zero<$signed(lo[6])?lo[6]:with_zero>$signed(hi[6])?hi[6]:with_zero[7:0];
     wide7<=model_result[31:0];error7<=modep[6]&&(errorp[6]||model_result>66'sd2147483647||model_result < -66'sd2147483648);
    end
   end
  end
 end endgenerate
endmodule

// Original 16-lane interface, kept for any remaining users.
module quant_stream16 # (parameter META_W=32)(
 input wire clk,rst,in_valid,output wire in_ready,
 input wire [511:0] accum,bias,input wire [511:0] multiplier,
 input wire model_q16,input wire[511:0]post_bias,
 input wire [95:0] shift,input wire signed[7:0] zero_point,clamp_min,clamp_max,
 input wire [META_W-1:0] in_meta,
 output wire out_valid,input wire out_ready,
 output wire [127:0] out_data,output wire [META_W-1:0] out_meta,
 output wire[511:0]out_wide,output wire out_error
);
 quant_stream_lanes #(.META_W(META_W),.LANES(16)) q(.clk(clk),.rst(rst),.in_valid(in_valid),.in_ready(in_ready),.accum(accum),.bias(bias),
  .multiplier(multiplier),.model_q16(model_q16),.post_bias(post_bias),.shift(shift),.zero_point(zero_point),.clamp_min(clamp_min),.clamp_max(clamp_max),
  .in_meta(in_meta),.out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),.out_meta(out_meta),.out_wide(out_wide),.out_error(out_error));
endmodule
