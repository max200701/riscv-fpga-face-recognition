`timescale 1ns/1ps
// 64KiB data + coherent banked instruction copy. Full rising-edge RAM reads.
// No benchmark-PC recognition and no precomputed algorithm results.
module sprint_tcm(input clk,rst_n,input [31:0] fetch_addr,
 output reg[31:0] fetch_tag,output reg[31:0] insn0,insn1,
 input valid,write,input[13:0]word_addr,read_word_addr,input[31:0]wdata,input[3:0]wstrb,
 output ready,output wire[31:0]rdata,
 input format_prepare,format_local,input[2:0]format_size,input[1:0]format_offset,
 output wire[31:0]formatted_data);
 reg[7:0]lane0[0:16383] /* synthesis syn_ramstyle="block_ram" */;
 reg[7:0]lane1[0:16383] /* synthesis syn_ramstyle="block_ram" */;
 reg[7:0]lane2[0:16383] /* synthesis syn_ramstyle="block_ram" */;
 reg[7:0]lane3[0:16383] /* synthesis syn_ramstyle="block_ram" */;
 reg[7:0]even0[0:8191] /* synthesis syn_ramstyle="block_ram" */;
 reg[7:0]even1[0:8191] /* synthesis syn_ramstyle="block_ram" */;
 reg[7:0]even2[0:8191] /* synthesis syn_ramstyle="block_ram" */;
 reg[7:0]even3[0:8191] /* synthesis syn_ramstyle="block_ram" */;
 reg[7:0]odd0[0:8191] /* synthesis syn_ramstyle="block_ram" */;
 reg[7:0]odd1[0:8191] /* synthesis syn_ramstyle="block_ram" */;
 reg[7:0]odd2[0:8191] /* synthesis syn_ramstyle="block_ram" */;
 reg[7:0]odd3[0:8191] /* synthesis syn_ramstyle="block_ram" */;
 reg[31:0]boot[0:16383] /* synthesis syn_romstyle="block_rom" */;
 initial $readmemh("application_rom.hex",boot);
 reg[31:0]even_q,odd_q,boot0_q,boot1_q;reg bank_q,rom_q;
 wire[12:0]even_addr=fetch_addr[15:3]+fetch_addr[2];
 wire[12:0]odd_addr=fetch_addr[15:3];
 reg[13:0] read_tag;reg[31:0]raw_data,collision_data;reg[3:0]collision_mask;
 // Ready is capacity/tag eligibility, independent of request-valid.
 // Every store side effect below remains qualified by valid && write && ready.
 // BA: X/M owner payload and synchronous read address are sampled
 // together. The private TCM always has a read port; same-edge stores retain
 // explicit byte collision forwarding. External buses still use real ready.
 assign ready=rst_n;
`ifndef SYNTHESIS
 always @(posedge clk)if(rst_n && valid && !write && read_tag!==word_addr)
   $fatal(1,"BA fixed-latency data TCM address identity");
`endif
 // CB: capture byte routing, sign extension and same-edge store collision
 // masks alongside the actual synchronous read. Raw RAM output crosses local
 // masks/OR only; it does not pass through the SoC peripheral mux first.
 reg[31:0]fmt_collision_data_q;
 reg[15:0]fmt_raw_q,fmt_collision_q,fmt_signraw_q,fmt_signcollision_q;
 reg[15:0]fmt_data_mask,fmt_sign_mask;
 reg fmt_local_q;reg[2:0]fmt_size_q;reg[1:0]fmt_offset_q;
 wire[3:0]next_collision=rst_n && valid && write && word_addr==read_word_addr ? wstrb : 4'b0;
 always @*begin
   fmt_data_mask=0;fmt_sign_mask=0;
   if(format_local)case(format_size)
     0,4:begin
       fmt_data_mask[format_offset]=1;
       if(format_size==0)begin
         fmt_sign_mask[4+format_offset]=1;fmt_sign_mask[8+format_offset]=1;fmt_sign_mask[12+format_offset]=1;
       end
     end
     1,5:begin
       fmt_data_mask[{format_offset[1],1'b0}]=1;
       fmt_data_mask[4+{format_offset[1],1'b1}]=1;
       if(format_size==1)begin
         fmt_sign_mask[8+{format_offset[1],1'b1}]=1;fmt_sign_mask[12+{format_offset[1],1'b1}]=1;
       end
     end
     2:fmt_data_mask=16'h8421;
     default:begin end
   endcase
 end
 always @(posedge clk)begin
   if(!rst_n)begin
     fmt_raw_q<=0;fmt_collision_q<=0;fmt_signraw_q<=0;fmt_signcollision_q<=0;fmt_local_q<=0;fmt_size_q<=0;fmt_offset_q<=0;fmt_collision_data_q<=0;
   end else if(format_prepare)begin
     fmt_collision_data_q<=wdata;
     fmt_raw_q<=fmt_data_mask & ~{4{next_collision}};
     fmt_collision_q<=fmt_data_mask & {4{next_collision}};
     fmt_signraw_q<=fmt_sign_mask & ~{4{next_collision}};
     fmt_signcollision_q<=fmt_sign_mask & {4{next_collision}};
     fmt_local_q<=format_local;fmt_size_q<=format_size;fmt_offset_q<=format_offset;
   end
 end
 genvar fb;generate for(fb=0;fb<4;fb=fb+1)begin:local_format
   wire signbit=|(fmt_signraw_q[fb*4+:4]&{raw_data[31],raw_data[23],raw_data[15],raw_data[7]})|
                |(fmt_signcollision_q[fb*4+:4]&{fmt_collision_data_q[31],fmt_collision_data_q[23],fmt_collision_data_q[15],fmt_collision_data_q[7]});
   assign formatted_data[fb*8+:8]=
     ({8{fmt_raw_q[fb*4]}}&raw_data[7:0])|({8{fmt_raw_q[fb*4+1]}}&raw_data[15:8])|
     ({8{fmt_raw_q[fb*4+2]}}&raw_data[23:16])|({8{fmt_raw_q[fb*4+3]}}&raw_data[31:24])|
     ({8{fmt_collision_q[fb*4]}}&fmt_collision_data_q[7:0])|({8{fmt_collision_q[fb*4+1]}}&fmt_collision_data_q[15:8])|
     ({8{fmt_collision_q[fb*4+2]}}&fmt_collision_data_q[23:16])|({8{fmt_collision_q[fb*4+3]}}&fmt_collision_data_q[31:24])|{8{signbit}};
 end endgenerate
 genvar b;generate for(b=0;b<4;b=b+1)begin
   assign rdata[b*8+:8]=collision_mask[b] ? collision_data[b*8+:8] : raw_data[b*8+:8];
 end endgenerate
 always @*begin
   insn0=rom_q ? boot0_q : bank_q ? odd_q : even_q;
   insn1=rom_q ? boot1_q : bank_q ? even_q : odd_q;
 end
 always @(posedge clk)begin
   fetch_tag<=fetch_addr;bank_q<=fetch_addr[2];rom_q<=fetch_addr[31:16]==0;
   even_q<={even3[even_addr],even2[even_addr],even1[even_addr],even0[even_addr]};
   odd_q<={odd3[odd_addr],odd2[odd_addr],odd1[odd_addr],odd0[odd_addr]};
   boot0_q<=boot[fetch_addr[15:2]];boot1_q<=boot[fetch_addr[15:2]+14'd1];
   read_tag<=read_word_addr;
   raw_data<={lane3[read_word_addr],lane2[read_word_addr],lane1[read_word_addr],lane0[read_word_addr]};
   collision_mask<=rst_n && valid && write && word_addr==read_word_addr ? wstrb : 0;
   collision_data<=wdata;
   if(rst_n)begin
     if(valid && write && ready)begin
       if(wstrb[0])lane0[word_addr]<=wdata[7:0];if(wstrb[1])lane1[word_addr]<=wdata[15:8];
       if(wstrb[2])lane2[word_addr]<=wdata[23:16];if(wstrb[3])lane3[word_addr]<=wdata[31:24];
       if(word_addr[0])begin
         if(wstrb[0])odd0[word_addr[13:1]]<=wdata[7:0];if(wstrb[1])odd1[word_addr[13:1]]<=wdata[15:8];
         if(wstrb[2])odd2[word_addr[13:1]]<=wdata[23:16];if(wstrb[3])odd3[word_addr[13:1]]<=wdata[31:24];
       end else begin
         if(wstrb[0])even0[word_addr[13:1]]<=wdata[7:0];if(wstrb[1])even1[word_addr[13:1]]<=wdata[15:8];
         if(wstrb[2])even2[word_addr[13:1]]<=wdata[23:16];if(wstrb[3])even3[word_addr[13:1]]<=wdata[31:24];
       end
     end
   end
 end
endmodule
