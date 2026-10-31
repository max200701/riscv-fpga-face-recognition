// Actual NPU Q16 output -> frozen exact activation/requantization -> NCHW.
// A macro-panel has up to 8x8 tiles; valid spatial/channel tails are masked.
// Settings must remain immutable until all posted tile completions arrive.
module npu_layout_tail(
 input wire param_begin,param_valid,input wire[7:0]param_index,input wire signed[31:0]param_value,
 input wire clk,rst,start,input wire[3:0]mtiles,ntiles,input wire[31:0]logical_base,
 input wire[31:0]cfg_base,cfg_plane,cfg_spatial,cfg_channel,
 input wire[8:0]cfg_m,cfg_n,input wire[1:0]cfg_mode,input wire[2:0]cfg_op,
 input wire[39:0]cfg_den,input wire[31:0]cfg_recip,input wire signed[15:0]cfg_zero,input wire[4:0]cfg_bits,
 input wire in_valid,output wire in_ready,input wire[127:0]in_q16,input wire[31:0]in_addr,
 output wire out_valid,input wire out_ready,output wire[255:0]out_data,output wire[31:0]out_addr,out_strb,out_tag,output wire out_last,
 input wire posted_valid,output wire posted_ready,input wire[31:0]posted_tag,
 output reg done,output reg[3:0]error
);
 wire av,ar,ac;wire[127:0]ad,alphas;wire[31:0]am;
 prelu_parameters4 coefficients(.clk(clk),.rst(rst),.start(start),.ntiles(ntiles),.mtiles(mtiles),.cfg_m(cfg_m),.cfg_n(cfg_n),
  .param_begin(param_begin),.param_valid(param_valid),.param_index(param_index),.param_value(param_value),
  .in_valid(in_valid&&error==0),.in_ready(in_ready),.in_data(in_q16),.in_meta(in_addr>>2),
  .out_valid(av),.out_ready(ar),.out_data(ad),.out_rhs(alphas),.out_meta(am),.coefficients_valid(ac));
 wire qv,qr,qe,math_fault,math_act_error;wire[127:0]math_q16;wire[31:0]qm;wire[63:0]qd;
 credit_math4 math(.clk(clk),.rst(rst),.in_valid(av&&error==0&&(cfg_op!=6||ac)),.in_ready(ar),
  .in_data(ad),.in_rhs(cfg_op==6?alphas:128'b0),.in_op({1'b0,cfg_op}),.bn_bias(32'b0),.in_meta(am),
  .denominator(cfg_den),.reciprocal(cfg_recip),.zero_point(cfg_zero),.activation_bits(cfg_bits),
  .out_valid(qv),.out_ready(qr),.out_q16(math_q16),.out_quant(qd),.out_meta(qm),
  .out_act_error(math_act_error),.out_quant_error(qe),.fault(math_fault));
 reg active,configured;reg[6:0]tile_index,total_tiles,posted_count;
 reg[3:0]mi,ni,nt;reg[7:0]word_count;reg[31:0]meta_base;
 wire cv=active&&!configured&&tile_index<total_tiles&&error==0;
 wire cr,li;wire[3:0]layout_error;
 wire[8:0]left_m=cfg_m-{mi,5'b0},left_n=cfg_n-{ni,5'b0};
 wire[5:0]valid_m=left_m>32?6'd32:left_m[5:0],valid_n=left_n>32?6'd32:left_n[5:0];
 // claude_c02 c7: only valid rows x valid 4-channel groups arrive (padding is skipped upstream).
 // Tile dimensions are stable when cfg_valid/cfg_ready commits them.
 // Do not recompute this multiply on every accepted output beat.
 reg[8:0]tile_beats;
 always @(posedge clk)if(cv&&cr)tile_beats<=valid_m*((valid_n+6'd3)>>2);
 assign qr=li&&configured;
 assign posted_ready=!rst&&active&&error==0;
 tile_writeback4 layout(.clk(clk),.rst(rst),.cfg_valid(cv),.cfg_ready(cr),.cfg_m(valid_m),.cfg_n(valid_n),.cfg_mode(cfg_mode),
  .cfg_base(cfg_base),.cfg_plane(cfg_plane),.cfg_spatial(cfg_spatial+{23'b0,mi,5'b0}),.cfg_channel(cfg_channel+{23'b0,ni,5'b0}),
  .cfg_tag({25'b0,tile_index}),.cfg_meta_base(meta_base+{15'b0,tile_index,10'b0}),
  .in_valid(qv&&configured),.in_ready(li),.in_q16(math_q16),.in_quant(qd),.in_meta(qm),.in_error(qe||math_act_error),
  .out_valid(out_valid),.out_ready(out_ready),.out_addr(out_addr),.out_data(out_data),.out_strb(out_strb),.out_last(out_last),.out_tag(out_tag),.done(),.error(layout_error));
 always @(posedge clk)begin
  if(rst)begin active<=0;configured<=0;tile_index<=0;total_tiles<=0;posted_count<=0;mi<=0;ni<=0;nt<=0;word_count<=0;meta_base<=0;done<=0;error<=0;end
  else begin
   done<=0;
   if(math_fault)error<=9;
   else if(layout_error!=0)error<=layout_error;
   if(av&&cfg_op==6&&!ac)error<=8;
   if(start)begin
    if(active||cfg_m==0||cfg_n==0||((cfg_m+31)>>5)!=mtiles||((cfg_n+31)>>5)!=ntiles||
       {1'b0,cfg_spatial}+cfg_m>{1'b0,cfg_plane})error<=6;
    else begin active<=1;configured<=0;tile_index<=0;posted_count<=0;total_tiles<=mtiles*ntiles;mi<=0;ni<=0;nt<=ntiles;meta_base<=logical_base>>2;end
   end
   if(cv&&cr)begin configured<=1;word_count<=0;end
   if(qv&&qr)begin
    if({1'b0,word_count}+9'd1==tile_beats)begin
     configured<=0;tile_index<=tile_index+1'b1;
     if(ni+1==nt)begin ni<=0;mi<=mi+1'b1;end else ni<=ni+1'b1;
    end else word_count<=word_count+1'b1;
   end
   if(posted_valid&&posted_ready)begin
    if(posted_tag!={25'b0,posted_count}||posted_count>=total_tiles)error<=7;
    else begin
     posted_count<=posted_count+1'b1;
     if(posted_count+1'b1==total_tiles)begin active<=0;done<=1;end
    end
   end
  end
 end
endmodule
