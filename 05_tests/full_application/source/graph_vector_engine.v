// Fixed-model affine Q16 vector / view / consumer-quantization engine.
// Descriptor: 32 little-endian words, 128-byte aligned range in shared DDR.
// 0 magic GVE1; 1 op(0..9); 2..4 X,Y,Z; 5..7 A,B,D bases;
// 8..10 A strides; 11..13 B strides; 14..16 D strides (signed bytes).
// 17..21 denominator low/high, reciprocal, zero, bits;
// 22 BN Q16 bias, 23 immediate RHS, 24 flags(quantized output, immediate RHS).
// One descriptor is immutable until posted completion. Reset includes transport.
module graph_vector_engine(
 input wire clk,rst,cmd_valid,output wire cmd_ready,input wire[31:0]cmd_addr,
 output reg rsp_valid,input wire rsp_ready,output reg[7:0]rsp_error,
 output wire rd_valid,input wire rd_ready,output wire[31:0]rd_addr,output wire[4:0]rd_beats,
 input wire r_valid,output wire r_ready,input wire[255:0]r_data,input wire r_last,r_error,
 output wire out_valid,input wire out_ready,output wire[31:0]out_addr,out_strb,out_tag,
 output wire[255:0]out_data,output wire out_last,
 input wire posted_valid,output wire posted_ready,input wire[31:0]posted_tag,
 output wire[63:0]elements,output reg[63:0]cycles
);
 reg[31:0]row_a_next,row_b_next,row_d_next,plane_a_next,plane_b_next,plane_d_next;
 reg more_row_q,more_plane_q;
 localparam IDLE=0,DREQ=1,DREAD=2,CHECK=3,PREP=4,ADDR=5,LOOK=6,HIT=7,
  MREQ=8,MREAD=9,EMIT=10,PIPE=11,WRITE=12,NEXT=13,POST=14,ERROR=15,FAST=16,TCHECK=17,TPOSE=18,DECODE=19,QUALIFY=20,TARM=21,FARM=22;
 reg[4:0]state;reg[31:0]d[0:31];reg[1:0]di;
 reg[63:0]slow_elements;wire[63:0]fast_elements,tp_elements;assign elements=slow_elements+fast_elements+tp_elements;
 reg[31:0]descriptor,x,y,z,ap,bp,dp,arow,brow,drow,aplane,bplane,dplane;
 reg[2:0]valid_lanes,lane,writelan;
 reg operand;reg[31:0]address;reg[127:0]av,bv,result_q16;reg[63:0]result_quant;
 reg[255:0]cache[0:15];reg[22:0]tag[0:15];reg[15:0]cache_valid;
 reg[255:0]cache_read;reg[22:0]tag_read;reg hit_read;
 wire need_b_decode=(d[1]==1||d[1]==2||d[1]==3||d[1]==6||d[1]==8||d[1]==9)&&!d[24][1];
 wire[31:0]bpe_decode=d[24][0]?(d[21]==8?1:2):4;
 reg need_b;reg[31:0]bpe;reg eligible_q,repeat_rhs_q,tpose_candidate_q;reg[4:0]descriptor_bad;
 wire signed[63:0]next_a=$signed({1'b0,ap})+$signed(d[8]);
 wire signed[63:0]next_b=$signed({1'b0,bp})+$signed(d[11]);
 assign cmd_ready=state==IDLE&&!rsp_valid&&!rst;
 wire frdv,frr,fav,far,frready,fov,fore,fol,fpready,fdone;wire[31:0]fra,fmeta,foaddr;wire[4:0]frn,fbytes;wire[127:0]faa,fbb;wire[7:0]ferror;
 wire aligned_a=(d[8]==4||d[8]==8)&&d[5][1:0]==0;
 wire aligned_b=(d[11]==4||d[11]==8)&&d[6][1:0]==0;
 wire ordinary_eligible=d[2]>=16&&aligned_a&&d[14]==bpe&&d[9][1:0]==0&&d[10][1:0]==0&&
  (d[7]&(bpe-1))==0&&(d[15]&(bpe-1))==0&&(d[16]&(bpe-1))==0&&
  (!need_b||d[11]==0||(aligned_b&&d[12][1:0]==0&&d[13][1:0]==0));
 // Exact flattening of two adjacent A/D values with one shared B per row.
 // Z>1 allowed (one plane per z, non-negative aligned z strides): merged FPN add runs.
 wire repeat_rhs=d[2]==2&&d[3]>=8&&d[3]<=65536&&need_b&&
  (d[4]==1||(d[10][1:0]==0&&d[13][1:0]==0&&(d[16]&(bpe-1))==0&&!d[10][31]&&!d[13][31]&&!d[16][31]))&&
  d[8]==4&&d[9]==8&&d[11]==0&&d[12]==4&&d[14]==bpe&&d[15]==(bpe<<1)&&
  d[5][1:0]==0&&d[6][1:0]==0&&(d[7]&(bpe-1))==0;
 wire eligible=ordinary_eligible||repeat_rhs;
 // pure-copy transpose (op 0, Q16 output, contiguous source X and destination Y).
 // Candidate test is cheap; the record/aliasing proof is registered and used one cycle later.
 wire tpose_candidate=d[1]==0&&d[24]==0&&d[8]==4&&d[15]==4&&d[3]<=16&&d[4]<=4;
 reg tpose_ok;
 wire[35:0]tp_rz=d[4]==1?36'd0:d[4]==2?{4'd0,d[16]}:d[4]==3?{3'd0,d[16],1'b0}+{4'd0,d[16]}:{3'd0,d[16],1'b0}+{4'd0,d[16]}+{4'd0,d[16]};
 wire[35:0]tp_qz=d[4]==1?{4'd0,d[10]}:d[4]==2?{3'd0,d[10],1'b0}:d[4]==3?{3'd0,d[10],1'b0}+{4'd0,d[10]}:{2'd0,d[10],2'b0};
 wire[35:0]tp_pf=(d[3][0]?{4'd0,d[9]}:36'd0)+(d[3][1]?{3'd0,d[9],1'b0}:36'd0)+(d[3][2]?{2'd0,d[9],2'b0}:36'd0)+(d[3][3]?{1'd0,d[9],3'b0}:36'd0)+(d[3][4]?{d[9],4'b0}:36'd0);
 always @(posedge clk)tpose_ok<=d[5][1:0]==0&&d[7][1:0]==0&&d[9][1:0]==0&&d[10][1:0]==0&&d[14][1:0]==0&&d[16][1:0]==0&&
  !d[9][31]&&!d[10][31]&&!d[14][31]&&!d[16][31]&&d[14]<=1024&&d[2]<32'h01000000&&
  tp_rz+{30'd0,d[3][3:0]==0&&d[3]!=0?5'd16:{1'b0,d[3][3:0]},2'b0}<={4'd0,d[14]}&&(d[3]==1||tp_pf<={4'd0,d[10]})&&
  {4'd0,d[7]}>={4'd0,d[5]}+tp_qz;
 wire[31:0]linear_nx=repeat_rhs_q?(d[3]<<1):d[2];
 wire[31:0]linear_ny=repeat_rhs_q?32'd1:d[3];
 wire[31:0]linear_bx=repeat_rhs_q?32'd4:d[11];
 wire tprdv,tpr,tpfv,tpfl,tppready,tpdone;wire[31:0]tpra,tpfa;wire[4:0]tprn,tpfb;wire[127:0]tpfd;wire[7:0]tperror;
 assign rd_valid=state==FAST?frdv:state==TPOSE?tprdv:(state==DREQ||state==MREQ);
 assign rd_addr=state==FAST?fra:state==TPOSE?tpra:state==DREQ?descriptor:{address[31:5],5'b0};
 assign rd_beats=state==FAST?frn:state==TPOSE?tprn:state==DREQ?5'd4:5'd1;
 assign r_ready=state==FAST?frr:state==TPOSE?tpr:(state==DREAD||state==MREAD);
 assign posted_ready=state==FAST?fpready:state==TPOSE?tppready:state==POST;
 integer i;
 wire act_r,quant_v,quant_e,rqready,math_fault,math_act_error;
 wire[63:0]quant_data;wire[31:0]quant_meta;wire[127:0]math_q16;
 credit_math4 math(.clk(clk),.rst(rst),.in_valid(state==FAST?fav:state==EMIT),.in_ready(act_r),
  .in_data(state==FAST?faa:av),.in_rhs(state==FAST?fbb:bv),.in_op(d[1][3:0]),.bn_bias(d[22]),
  .in_meta(state==FAST?fmeta:32'b0),.denominator({d[18][7:0],d[17]}),.reciprocal(d[19]),
  .zero_point(d[20][15:0]),.activation_bits(d[21][4:0]),.out_valid(quant_v),.out_ready(rqready),
  .out_q16(math_q16),.out_quant(quant_data),.out_meta(quant_meta),
  .out_act_error(math_act_error),.out_quant_error(quant_e),.fault(math_fault));
 assign rqready=state==FAST?frready:state==PIPE;
 wire[31:0]write_addr=dp;
 wire[31:0]write_value=d[24][0]?{16'b0,result_quant[writelan*16+:16]}:result_q16[writelan*32+:32];
 wire final_element=x+writelan+1==d[2]&&y+1==d[3]&&z+1==d[4];
 wire pack_ready,pack_fault;
 wire pipeline_v,pipeline_r,pipeline_last;wire[31:0]pipeline_addr,pipeline_tag;wire[127:0]pipeline_data;wire[4:0]pipeline_bytes;
 wire fast_bad=math_act_error||(d[24][0]&&quant_e);
 wire[127:0]fast_data=!d[24][0]?math_q16:d[21]==12?{64'b0,quant_data}:{96'b0,quant_data[55:48],quant_data[39:32],quant_data[23:16],quant_data[7:0]};
 reg split_pending;
 // Fragment source for the line-split stage: the linear FAST path or the transpose path.
 wire tpsel=state==TPOSE;
 wire[31:0]sfa=tpsel?tpfa:foaddr;wire[4:0]sfb=tpsel?tpfb:fbytes;wire[127:0]sfd=tpsel?tpfd:fast_data;
 wire sfv=tpsel?tpfv:(fov&&!fast_bad);wire sfl=tpsel?tpfl:fol;
 wire[5:0]line_space=6'd32-{1'b0,sfa[4:0]};
 wire needs_split={1'b0,sfb}>line_space;
 wire[31:0]fast_pack_addr=split_pending?sfa+line_space:sfa;
 wire[4:0]fast_pack_bytes=split_pending?sfb-line_space:needs_split?line_space[4:0]:sfb;
 wire[127:0]fast_pack_data=split_pending?(sfd>>(line_space*8)):sfd;
 always @(posedge clk)begin
  if(rst)split_pending<=0;
  else if((state==FAST||state==TPOSE)&&sfv&&pack_ready)begin
   if(needs_split&&!split_pending)split_pending<=1;else split_pending<=0;
  end
 end
 graph_linear_stream linear(.clk(clk),.rst(rst),.start(state==FARM),.nx_p(linear_nx),.ny_p(linear_ny),.nz_p(d[4]),.abase_p(d[5]),.bbase_p(d[6]),.dbase_p(d[7]),
  .ax_p(d[8]),.ay_p(d[9]),.az_p(d[10]),.bx_p(linear_bx),.by_p(d[12]),.bz_p(d[13]),.dy_p(d[15]),.dz_p(d[16]),.need_b_p(need_b),.immediate_p(d[24][1]?d[23]:32'b0),.bpe_p(bpe[2:0]),.repeat_rhs_p(repeat_rhs_q),
  .rd_valid(frdv),.rd_ready(rd_ready&&state==FAST),.rd_addr(fra),.rd_beats(frn),.r_valid(r_valid&&state==FAST),.r_ready(frr),.r_data(r_data),.r_last(r_last),.r_error(r_error),
  .feed_valid(fav),.feed_ready(act_r&&state==FAST),.feed_a(faa),.feed_b(fbb),.feed_meta(fmeta),
  .result_valid(quant_v&&state==FAST),.result_ready(frready),.result_meta(quant_meta),.fragment_valid(fov),.fragment_ready(pack_ready&&!fast_bad&&state==FAST&&(!needs_split||split_pending)),
  .fragment_addr(foaddr),.fragment_bytes(fbytes),.fragment_last(fol),.posted_valid(posted_valid&&posted_tag==0&&state==FAST),.posted_ready(fpready),.done(fdone),.error(ferror),.elements(fast_elements));
 graph_transpose_stream transpose(.clk(clk),.rst(rst),.start(state==TARM),.n(d[2]),.f(d[3]),.nz(d[4]),.abase(d[5]),.dbase(d[7]),
  .p(d[9]),.q(d[10]),.sd(d[14]),.r(d[16]),
  .rd_valid(tprdv),.rd_ready(rd_ready&&tpsel),.rd_addr(tpra),.rd_beats(tprn),.r_valid(r_valid&&tpsel),.r_ready(tpr),.r_data(r_data),.r_last(r_last),.r_error(r_error),
  .fragment_valid(tpfv),.fragment_ready(pack_ready&&tpsel&&(!needs_split||split_pending)),.fragment_addr(tpfa),.fragment_data(tpfd),.fragment_bytes(tpfb),.fragment_last(tpfl),
  .posted_valid(posted_valid&&posted_tag==0&&tpsel),.posted_ready(tppready),.done(tpdone),.error(tperror),.elements(tp_elements));
 wire fastlike=state==FAST||state==TPOSE;
 graph_fragment_fifo output_stage(.clk(clk),.rst(rst),.in_valid(fastlike?sfv:(state==WRITE&&dp<32'h40000000&&(dp&(bpe-1))==0)),.in_ready(pack_ready),.in_addr(fastlike?fast_pack_addr:write_addr),
  .in_data(fastlike?fast_pack_data:{96'b0,write_value}),.in_bytes(fastlike?fast_pack_bytes:bpe[4:0]),.in_last(fastlike?(sfl&&(!needs_split||split_pending)):final_element),.in_tag(32'b0),
  .out_valid(pipeline_v),.out_ready(pipeline_r),.out_addr(pipeline_addr),.out_data(pipeline_data),.out_bytes(pipeline_bytes),.out_last(pipeline_last),.out_tag(pipeline_tag));
 fragment_pack256 pack(.clk(clk),.rst(rst),.in_valid(pipeline_v),.in_ready(pipeline_r),.in_addr(pipeline_addr),.in_data(pipeline_data),
  .in_bytes(pipeline_bytes),.in_last(pipeline_last),.in_tag(pipeline_tag),
  .out_valid(out_valid),.out_ready(out_ready),.out_addr(out_addr),.out_data(out_data),.out_strb(out_strb),.out_last(out_last),.out_tag(out_tag),.fault(pack_fault));
 task fail(input[7:0]code);begin rsp_error<=code;rsp_valid<=1;state<=ERROR;end endtask
 task captured(input[31:0]value);
  begin
   if(!operand)av[lane*32+:32]<=value;else bv[lane*32+:32]<=value;
   if(!operand&&need_b)begin operand<=1;state<=ADDR;end
   else begin
    if(!need_b)bv[lane*32+:32]<=d[24][1]?d[23]:0;
    operand<=0;
    if(lane+1==valid_lanes)state<=EMIT;
    else begin
     ap<=next_a[31:0];bp<=next_b[31:0];lane<=lane+1'b1;state<=ADDR;
     if(next_a<0||next_a>=64'h40000000||(need_b&&(next_b<0||next_b>=64'h40000000)))fail(8'h24);
    end
   end
  end
 endtask
 always @(posedge clk)begin
  cache_read<=cache[address[8:5]];tag_read<=tag[address[8:5]];hit_read<=cache_valid[address[8:5]];
  if(rst)begin
   state<=IDLE;rsp_valid<=0;rsp_error<=0;di<=0;descriptor<=0;cache_valid<=0;slow_elements<=0;cycles<=0;
   x<=0;y<=0;z<=0;ap<=0;bp<=0;dp<=0;arow<=0;brow<=0;drow<=0;aplane<=0;bplane<=0;dplane<=0;
   lane<=0;writelan<=0;operand<=0;address<=0;valid_lanes<=0;av<=0;bv<=0;
   for(i=0;i<32;i=i+1)d[i]<=0;
  end else begin
   if(state!=IDLE)cycles<=cycles+1;
   if(rsp_valid&&rsp_ready)rsp_valid<=0;
   if(math_fault)fail(8'h2c);
   else if(pack_fault)fail(8'h29);
   else case(state)
    IDLE:if(cmd_valid&&cmd_ready)begin
     if(cmd_addr[6:0]!=0||cmd_addr[31:30]!=0)fail(8'h20);
     else begin descriptor<=cmd_addr;di<=0;state<=DREQ;cache_valid<=0;rsp_error<=0;end
    end
    DREQ:if(rd_ready)state<=DREAD;
    DREAD:if(r_valid)begin
     if(r_error||r_last!=(di==3))fail(8'h21);
     else begin
      for(i=0;i<8;i=i+1)d[{di,3'b0}+i]<=r_data[i*32+:32];
      if(di==3)state<=DECODE;else di<=di+1'b1;
     end
    end
    DECODE:begin need_b<=need_b_decode;bpe<=bpe_decode;state<=QUALIFY;end
    QUALIFY:begin
     descriptor_bad[0]<=(d[0]!=32'h31455647||d[1]>9||d[24]>3);
     descriptor_bad[1]<=(d[2]==0||d[3]==0||d[4]==0||d[2]>32'h10000000||d[3]>65536||d[4]>65536);
     descriptor_bad[2]<=(d[5][1:0]!=0||(need_b&&d[6][1:0]!=0)||(d[7]&(bpe-1))!=0);
     descriptor_bad[3]<=({d[18][7:0],d[17]}<=40'h1000000||d[18]>255||d[19]==0||(d[21]!=8&&d[21]!=12));
     descriptor_bad[4]<=(d[25]!=0||d[26]!=0||d[27]!=0||d[28]!=0||d[29]!=0||d[30]!=0||d[31]!=0);
     eligible_q<=eligible;repeat_rhs_q<=repeat_rhs;tpose_candidate_q<=tpose_candidate;state<=CHECK;
    end
    CHECK:begin
     if(|descriptor_bad)fail(8'h22);
     else begin
      x<=0;y<=0;z<=0;aplane<=d[5];bplane<=d[6];dplane<=d[7];arow<=d[5];brow<=d[6];drow<=d[7];
      ap<=d[5];bp<=d[6];dp<=d[7];state<=eligible_q?FARM:tpose_candidate_q?TCHECK:PREP;
     end
    end
    PREP:begin
     // Prepare immutable row/plane alternatives while this group is evaluated.
     row_a_next<=arow+d[9];row_b_next<=brow+d[12];row_d_next<=drow+d[15];
     plane_a_next<=aplane+d[10];plane_b_next<=bplane+d[13];plane_d_next<=dplane+d[16];
     more_row_q<=(y+1<d[3]);more_plane_q<=(z+1<d[4]);
     valid_lanes<=d[2]-x>=4?4:d[2]-x;lane<=0;writelan<=0;operand<=0;av<=0;bv<=0;state<=ADDR;
    end
    ADDR:begin
     address<=operand?bp:ap;state<=LOOK;
     if((operand?bp:ap)>=32'h40000000||((operand?bp:ap)&3)!=0)fail(8'h23);
    end
    LOOK:state<=HIT;
    HIT:if(hit_read&&tag_read==address[31:9])captured(cache_read[address[4:2]*32+:32]);else state<=MREQ;
    MREQ:if(rd_ready)state<=MREAD;
    MREAD:if(r_valid)begin
     if(r_error||!r_last)fail(8'h25);
     else begin
      cache[address[8:5]]<=r_data;tag[address[8:5]]<=address[31:9];cache_valid[address[8:5]]<=1;
      captured(r_data[address[4:2]*32+:32]);
     end
    end
    EMIT:if(act_r)state<=PIPE;
    PIPE:if(quant_v)begin
     if(math_act_error||(d[24][0]&&quant_e))fail(8'h26);
     else begin result_q16<=math_q16;result_quant<=quant_data;state<=WRITE;end
    end
    WRITE:begin
     if(dp>=32'h40000000||(dp&(bpe-1))!=0)fail(8'h27);
     else if(pack_ready)begin
      slow_elements<=slow_elements+1;
      if(writelan+1==valid_lanes)state<=NEXT;
      else begin writelan<=writelan+1'b1;dp<=dp+d[14];end
     end
    end
    NEXT:begin
     if(x+valid_lanes<d[2])begin x<=x+valid_lanes;ap<=ap+d[8];bp<=bp+d[11];dp<=dp+d[14];state<=PREP;end
     else if(more_row_q)begin
      x<=0;y<=y+1;arow<=row_a_next;brow<=row_b_next;drow<=row_d_next;
      ap<=row_a_next;bp<=row_b_next;dp<=row_d_next;state<=PREP;
     end else if(more_plane_q)begin
      x<=0;y<=0;z<=z+1;aplane<=plane_a_next;bplane<=plane_b_next;dplane<=plane_d_next;
      arow<=plane_a_next;brow<=plane_b_next;drow<=plane_d_next;ap<=plane_a_next;bp<=plane_b_next;dp<=plane_d_next;state<=PREP;
     end else state<=POST;
    end
    POST:if(posted_valid)begin
     if(posted_tag!=0)fail(8'h28);else begin rsp_valid<=1;state<=IDLE;end
    end
    TCHECK:state<=tpose_ok?TARM:PREP;   // registered proof; otherwise the per-element path
    FARM:state<=FAST;
    TARM:state<=TPOSE;
    TPOSE:begin
     if(tperror!=0)fail(tperror);
     else if(posted_valid&&posted_tag!=0)fail(8'h28);
     else if(tpdone)begin rsp_valid<=1;state<=IDLE;end
    end
    FAST:begin
     if(ferror!=0)fail(ferror);
     else if(quant_v&&fast_bad)fail(8'h26);
     else if(posted_valid&&posted_tag!=0)fail(8'h28);
     else if(fdone)begin rsp_valid<=1;state<=IDLE;end
    end
    ERROR:begin end
    default:fail(8'h2f);
   endcase
  end
 end
endmodule
