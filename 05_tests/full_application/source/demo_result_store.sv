// Atomic single-shot result snapshot. One ordered CPU producer, same UI clock.
// No embedded/golden result: all values arrive from actual CPU diagnostic stores.
module demo_result_store(
 input wire[1:0]application_mode,
 input wire clk,rst,mark_toggle,input wire[31:0]mark_kind,mark_a,mark_b,
 input wire[5:0]page,output wire[511:0]words,output wire ready,
 output reg committed,fault,output wire has_face
);
 // PG: capture the whole marker with its decoded kind, retaining ordered toggle semantics.
 reg event_toggle,event_kind;reg[31:0]event_a,event_b;
 always @(posedge clk)begin
  if(rst)begin event_toggle<=0;event_kind<=0;end
  else begin event_toggle<=mark_toggle;event_kind<=mark_kind==32'h201;end
  event_a<=mark_a;event_b<=mark_b;
 end
 reg seen;reg[9:0]embedding_count;reg[4:0]metadata_count;
 wire event_valid=event_toggle!=seen&&event_kind;
 wire embedding_event=event_valid&&event_a[31:9]==23'h480000;
 wire metadata_event=event_valid&&event_a[31:4]==28'ha000000;
 wire metadata_write=metadata_event&&!committed&&!fault&&metadata_count<16&&event_a[3:0]==metadata_count;
 wire[511:0]metadata;
 // Predecode at the existing marker capture boundary. No added event latency.
 (* syn_preserve=1 *) reg[15:0]metadata_slot;
 genvar mw;
 generate for(mw=0;mw<16;mw=mw+1)begin:metadata_word
  always @(posedge clk)metadata_slot[mw]<=mark_a[3:0]==mw;
  reg[31:0]value;
  (* syn_keep=1 *) wire write_word=metadata_write&&metadata_slot[mw];
  always @(posedge clk)begin
   if(rst)value<=0;
   else if(write_word)value<=event_b;
  end
  assign metadata[32*mw+:32]=value;
 end endgenerate
 wire commit_event=event_valid&&event_a==32'hfffffff7;
 wire embedding_write=embedding_event&&!rst&&!committed&&!fault&&event_a[8:0]==embedding_count&&embedding_count<512;
 wire[511:0]embedding_page;
 // QF: registered address at each existing result bank. PARSE->VALIDATE->
 // DISPATCH already supplies a full setup edge before the packet reads ready.
 // The public ready signal explicitly rejects an unsettled page.
 reg[5:0]read_page_echo;
 always @(posedge clk)read_page_echo<=page;
 wire read_page_settled=(read_page_echo==page);
 genvar bank;
 generate for(bank=0;bank<16;bank=bank+1)begin:result_bank
  (* syn_preserve=1 *) reg[4:0]read_page_q;
  always @(posedge clk)read_page_q<=page-1'b1;
  reg[31:0]mem[0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
  // C26 bank-local write ports; drop a pending write on synchronous reset.
  reg we_q /* synthesis syn_preserve = 1 */;
  reg[4:0]wa_q /* synthesis syn_preserve = 1 */;
  reg[31:0]wd_q;
  always @(posedge clk)begin
   we_q<=!rst&&embedding_write&&event_a[3:0]==bank;
   wa_q<=event_a[8:4];wd_q<=event_b;
  end
  always @(posedge clk)if(!rst&&we_q)mem[wa_q]<=wd_q;
  assign embedding_page[32*bank+:32]=mem[read_page_q];
 end endgenerate
 assign has_face=metadata[3*32];
 assign ready=committed&&!fault&&(page==0||(page<=32&&has_face&&read_page_settled));
 assign words=page==0?metadata:embedding_page;
 always @(posedge clk)begin
  if(rst)begin seen<=0;embedding_count<=0;metadata_count<=0;committed<=0;fault<=0;end
  else begin
   seen<=event_toggle;
   if(embedding_event)begin
    if(!embedding_write)fault<=1;else embedding_count<=embedding_count+1'b1;
   end
   if(metadata_event)begin
    if(committed||fault||metadata_count>=16||event_a[3:0]!=metadata_count)fault<=1;
    else begin metadata_count<=metadata_count+1'b1;end
   end
   if(commit_event)begin
    if(committed||fault||event_b!=1||metadata_count!=16||(application_mode==0?metadata[31:0]!=32'h31445246:(metadata[31:0]!=32'h314b4d43||has_face))||metadata[63:32]!=1||
      (has_face?embedding_count!=512:embedding_count!=0))fault<=1;
    else committed<=1;
   end
  end
 end
endmodule
