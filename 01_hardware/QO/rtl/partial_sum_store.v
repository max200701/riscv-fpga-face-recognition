// Preserve an entire macro-panel across K segments, so A and B can continue
// to be reused across M/N tiles even when the dot exceeds operand-bank capacity.
// Every segment visits each entry once; caller must wait for all commits before
// starting the next segment. First segment bypasses uninitialized RAM contents.
// Three elastic stages: synchronous page read, page select, INT32 additions.
// an entry still in flight (stage 0/1/2, not yet written) blocks a new
// access to the same index, so K chunks of one RUN may revisit entries back to back.
// one entry = one 4-lane phase {vector,phase}; 1024-entry pages.
module partial_sum_store #(parameter DEPTH=16384,IW=15,LANES=4,META_W=38)(
 input wire clk,rst,in_valid,output wire in_ready,
 input wire in_first,in_last,input wire[IW-1:0]in_index,
 input wire[LANES*32-1:0]in_data,input wire[META_W-1:0]in_meta,
 output wire out_valid,input wire out_ready,output wire[LANES*32-1:0]out_data,
 output wire[META_W-1:0]out_meta,output wire commit
);
 localparam PAGES=(DEPTH+1023)/1024,W=LANES*32;
 reg v0,v1,v2,first0,first1,last0,last1,last2;
 reg[IW-1:0]index0,index1,index2;
 reg[W-1:0]previous1,current0,current1,sum2;reg[META_W-1:0]meta0,meta1,meta2;
 wire advance=!v2||!last2||out_ready;
 wire hazard=(v0&&index0==in_index)||(v1&&index1==in_index)||(v2&&index2==in_index);
 assign in_ready=!rst&&advance&&!hazard;
 wire take=in_valid&&!hazard;
 assign out_valid=!rst&&v2&&last2;
 assign out_data=sum2;assign out_meta=meta2;
 assign commit=!rst&&v2&&advance;
 wire[W-1:0]read_page[0:PAGES-1];
 genvar page;
 generate for(page=0;page<PAGES;page=page+1)begin:pages
  reg[W-1:0]memory[0:1023] /* synthesis syn_ramstyle="block_ram" */;
  reg[W-1:0]read_word;
  always @(posedge clk)begin
   if(!rst&&advance&&take&&in_index[IW-1:10]==page)read_word<=memory[in_index[9:0]];
   if(commit&&index2[IW-1:10]==page)memory[index2[9:0]]<=sum2;
  end
  assign read_page[page]=read_word;
 end endgenerate
 integer lane;
 always @(posedge clk)begin
  if(rst)begin
   v0<=0;v1<=0;v2<=0;first0<=0;first1<=0;last0<=0;last1<=0;last2<=0;index0<=0;index1<=0;index2<=0;
   current0<=0;current1<=0;previous1<=0;sum2<=0;meta0<=0;meta1<=0;meta2<=0;
  end else if(advance)begin
   v0<=take;v1<=v0;v2<=v1;
   if(take)begin first0<=in_first;last0<=in_last;index0<=in_index;current0<=in_data;meta0<=in_meta;end
   if(v0)begin
    last1<=last0;first1<=first0;index1<=index0;meta1<=meta0;current1<=current0;
    previous1<=read_page[index0[IW-1:10]];
   end
   if(v1)begin
    last2<=last1;index2<=index1;meta2<=meta1;
    for(lane=0;lane<LANES;lane=lane+1)
     sum2[lane*32+:32]<=first1?current1[lane*32+:32]:$signed(current1[lane*32+:32])+$signed(previous1[lane*32+:32]);
   end
  end
 end
endmodule
