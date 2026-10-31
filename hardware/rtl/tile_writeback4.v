// Two 32x32 tile banks. Input order is [spatial][channel], four channels/beat;
// output is masked NCHW DDR writes. Physical RAM addressing groups four spatial
// samples in each word and four channels across banks; no 1024-way read mux.
// claude_c02 c7: only valid spatial rows x valid 4-channel groups are supplied (all-padding
// beats are skipped upstream); positions keep the same RAM address. Only valid M/N
// values are written. Mode 0=INT8, 1=signed INT12 in 16 bits, 2=Q16 in 32 bits.
module tile_writeback4(
 input wire clk,rst,
 input wire cfg_valid,output wire cfg_ready,
 input wire [5:0] cfg_m,cfg_n,input wire [1:0] cfg_mode,
 input wire [31:0] cfg_base,cfg_plane,cfg_spatial,cfg_channel,cfg_tag,cfg_meta_base,
 input wire in_valid,output wire in_ready,
 input wire [127:0] in_q16,input wire [63:0] in_quant,
 input wire [31:0] in_meta,input wire in_error,
 output wire out_valid,input wire out_ready,
 output wire [31:0] out_addr,output wire [255:0] out_data,output wire [31:0] out_strb,
 output wire out_last,output wire [31:0] out_tag,
 output wire done,output reg [3:0] error
);
 wire [127:0] rd0,rd1,rd2,rd3;
 wire [511:0] read_words;
 assign {rd3,rd2,rd1,rd0}=read_words;
 reg [1:0] full;
 reg fill_bank,read_bank,filling,draining,issuing;
 reg [7:0] fill_count;   // {spatial, channel group}
 reg [5:0] ms[0:1],ns[0:1];reg [1:0] modes[0:1];
 wire [3:0] fill_groups=(ns[fill_bank]+6'd3)>>2;
 reg [31:0] first_addr[0:1],strides[0:1],tags[0:1],metas[0:1];
 // Configuration is a reserved transaction: accept once, validate in a
 // finite pipeline, then expose in_ready. No tile data is accepted early.
 // Every legal input has channel<2^30 and plane<=2^30, so a 32x32
 // product is exact; invalid wider-channel inputs are rejected by basic_bad.
 reg [2:0] cfg_step;
 reg basic_bad;
 reg [5:0] cm,cn;reg[1:0] cmod;
 reg [31:0] cbase,cplane,cchannel,cend_channel,ctag,cmeta,cstride;
 reg [32:0] start_offset,end_offset;
 reg [31:0] s00,s01,s10,s11,e00,e01,e10,e11;
 reg [32:0] scross,ecross;
 reg [63:0] start_product,end_product,start_element,end_element,start_address,end_address;
 wire bad_basic=cfg_m==0 || cfg_m>32 || cfg_n==0 || cfg_n>32 || cfg_mode>2 || cfg_plane==0 ||
   cfg_base>=32'h40000000 || cfg_plane>32'h40000000 || cfg_channel>=32'h40000000 ||
   {1'b0,cfg_spatial}+cfg_m>{1'b0,cfg_plane} ||
   (cfg_base&((1<<cfg_mode)-1))!=0 || cfg_meta_base>32'hfffffc03;
 assign cfg_ready=!rst&&cfg_step==0&&!filling&&!full[fill_bank]&&error==0;
 assign in_ready=!rst&&filling&&error==0;
 wire [6:0] wa={fill_bank,fill_count[2:0],fill_count[7:5]};
 wire [1:0] slot=fill_count[4:3];
 wire [127:0] write_values=modes[fill_bank]==2 ? in_q16 :
  {{16{in_quant[63]}},in_quant[63:48],{16{in_quant[47]}},in_quant[47:32],{16{in_quant[31]}},in_quant[31:16],{16{in_quant[15]}},in_quant[15:0]};
 reg [5:0] pos,chan;
 reg [31:0] current_addr,channel_addr;
 wire [5:0] word_room=4-{4'b0,pos[1:0]};
 wire [5:0] tail_room=ms[read_bank]-pos;
 wire [5:0] line_room=(6'd32-{1'b0,current_addr[4:0]})>>modes[read_bank];
 wire [5:0] take0=word_room<tail_room ? word_room:tail_room;
 wire [5:0] take=take0<line_room ? take0:line_room;
 wire issue_last=pos+take==ms[read_bank] && chan+1==ns[read_bank];
 reg rv,rlast;reg [1:0] rbank,rslot,rmode;reg [5:0] rcount;reg [31:0] raddr,rtag;
 wire frag_ready;wire ce=!rv||frag_ready;
 wire [6:0] ra={read_bank,chan[4:2],pos[4:2]};
 // Explicit word banks keep writes static-width for PDS block-RAM inference.
 // There are 16 independently enabled 32-bit banks, not flip-flop arrays.
 genvar bc,bs;
 generate for(bc=0;bc<4;bc=bc+1)begin: channel_banks
  for(bs=0;bs<4;bs=bs+1)begin: spatial_banks
   reg [31:0] memory[0:127] /* synthesis syn_ramstyle="block_ram" */;
   reg [31:0] read_word;
   always @(posedge clk)begin
    if(in_valid&&in_ready&&slot==bs)memory[wa]<=write_values[bc*32+:32];
    if(ce&&issuing&&error==0)read_word<=memory[ra];
   end
   assign read_words[bc*128+bs*32+:32]=read_word;
  end
 end endgenerate
 reg [127:0] selected,packed_data;integer lane;
 always @*begin
  case(rbank)0:selected=rd0;1:selected=rd1;2:selected=rd2;default:selected=rd3;endcase
  selected=selected>>(rslot*32);packed_data=0;
  for(lane=0;lane<4;lane=lane+1)if(lane<rcount)begin
   case(rmode)
    0:packed_data[lane*8+:8]=selected[lane*32+:8];
    1:packed_data[lane*16+:16]=selected[lane*32+:16];
    2:packed_data[lane*32+:32]=selected[lane*32+:32];
   endcase
  end
 end
 wire pack_fault;wire [4:0] fragment_bytes=rcount<<rmode;
 reg bad_quant;integer qi;
 always @*begin
  bad_quant=0;
  for(qi=0;qi<4;qi=qi+1)begin
   if(modes[fill_bank]==0 && ($signed(in_quant[qi*16+:16]) < -128 || $signed(in_quant[qi*16+:16]) > 127))bad_quant=1;
   if(modes[fill_bank]==1 && ($signed(in_quant[qi*16+:16]) < -2048 || $signed(in_quant[qi*16+:16]) > 2047))bad_quant=1;
  end
 end
 // claude_c02 c20: registered hand-off from the read/lane-select stage to the packer.
 wire pv,pready,plast;wire[31:0]paddr,ptag;wire[127:0]pdata;wire[4:0]pbytes;
 axi_skid #(.W(198)) pack_skid(.clk(clk),.rst(rst),.s_valid(rv&&error==0),.s_ready(frag_ready),
  .s_data({raddr,packed_data,fragment_bytes,rlast,rtag}),.m_valid(pv),.m_ready(pready),.m_data({paddr,pdata,pbytes,plast,ptag}));
 fragment_pack256 packer(.clk(clk),.rst(rst),.in_valid(pv),.in_ready(pready),.in_addr(paddr),.in_data(pdata),
  .in_bytes(pbytes),.in_last(plast),.in_tag(ptag),.out_valid(out_valid),.out_ready(out_ready),
  .out_addr(out_addr),.out_data(out_data),.out_strb(out_strb),.out_last(out_last),.out_tag(out_tag),.fault(pack_fault));
 assign done=out_valid&&out_ready&&out_last;
 always @(posedge clk)begin
  if(rst)begin full<=0;fill_bank<=0;read_bank<=0;filling<=0;draining<=0;issuing<=0;rv<=0;error<=0;fill_count<=0;cfg_step<=0;end
  else begin
   if(pack_fault)error<=4;
   if(cfg_valid&&cfg_ready)begin
    cfg_step<=1;basic_bad<=bad_basic;
    cm<=cfg_m;cn<=cfg_n;cmod<=cfg_mode;cbase<=cfg_base;cplane<=cfg_plane;
    cchannel<=cfg_channel;cend_channel<=cfg_channel+cfg_n-1'b1;
    start_offset<={1'b0,cfg_spatial};end_offset<={1'b0,cfg_spatial}+cfg_m;
    ctag<=cfg_tag;cmeta<=cfg_meta_base;cstride<=cfg_plane<<cfg_mode;
   end
   case(cfg_step)
    1:begin
     s00<=cchannel[15:0]*cplane[15:0];s01<=cchannel[15:0]*cplane[31:16];
     s10<=cchannel[31:16]*cplane[15:0];s11<=cchannel[31:16]*cplane[31:16];
     e00<=cend_channel[15:0]*cplane[15:0];e01<=cend_channel[15:0]*cplane[31:16];
     e10<=cend_channel[31:16]*cplane[15:0];e11<=cend_channel[31:16]*cplane[31:16];
     cfg_step<=2;
    end
    2:begin scross<={1'b0,s01}+{1'b0,s10};ecross<={1'b0,e01}+{1'b0,e10};cfg_step<=3;end
    3:begin start_product<={s11,s00}+{15'b0,scross,16'b0};end_product<={e11,e00}+{15'b0,ecross,16'b0};cfg_step<=4;end
    4:begin start_element<=start_product+start_offset;end_element<=end_product+end_offset;cfg_step<=5;end
    5:begin start_address<={32'b0,cbase}+(start_element<<cmod);end_address<={32'b0,cbase}+(end_element<<cmod);cfg_step<=6;end
    6:begin
     cfg_step<=0;
     if(basic_bad||end_address>64'h40000000)error<=1;
     else begin
      filling<=1;fill_count<=0;ms[fill_bank]<=cm;ns[fill_bank]<=cn;modes[fill_bank]<=cmod;
      first_addr[fill_bank]<=start_address[31:0];strides[fill_bank]<=cstride;
      tags[fill_bank]<=ctag;metas[fill_bank]<=cmeta;
     end
    end
   endcase
   if(in_valid&&in_ready)begin
    if(in_error||bad_quant||in_meta!=metas[fill_bank]+{22'b0,fill_count,2'b00})error<=in_error ? 3:(bad_quant ? 5:2);
    if({1'b0,fill_count[7:3]}+1'b1==ms[fill_bank]&&{1'b0,fill_count[2:0]}+1'b1==fill_groups)begin full[fill_bank]<=1;fill_bank<=!fill_bank;filling<=0;end
    else if({1'b0,fill_count[2:0]}+1'b1==fill_groups)fill_count<={fill_count[7:3]+1'b1,3'b0};
    else fill_count<=fill_count+1'b1;
   end
   if(!draining&&full[read_bank]&&error==0)begin
    draining<=1;issuing<=1;pos<=0;chan<=0;current_addr<=first_addr[read_bank];channel_addr<=first_addr[read_bank];
   end
   if(ce)begin
    rv<=issuing&&error==0;
    if(issuing&&error==0)begin
     rbank<=chan[1:0];rslot<=pos[1:0];rmode<=modes[read_bank];rcount<=take;raddr<=current_addr;rtag<=tags[read_bank];rlast<=issue_last;
     if(issue_last)issuing<=0;
     if(pos+take==ms[read_bank])begin pos<=0;chan<=chan+1'b1;channel_addr<=channel_addr+strides[read_bank];current_addr<=channel_addr+strides[read_bank];end
     else begin pos<=pos+take;current_addr<=current_addr+(take<<modes[read_bank]);end
    end
   end
   if(rv&&frag_ready&&rlast&&error==0)begin full[read_bank]<=0;read_bank<=!read_bank;draining<=0;end
  end
 end
endmodule
