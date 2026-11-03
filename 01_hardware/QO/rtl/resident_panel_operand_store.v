// Isolated extension: B-count zero reuses a successfully filled B bank.
// Caller must match weight base/count/generation; reset invalidates residency.
// Two independently owned panels. ROW_BYTES=32 or 40; DDR loader beats are
// always 32B. A vectors are tightly packed, with the last beat zero-padded;
// B vectors are 32B. A residual padding is discarded before starting B.
// Counts/base indices are VECTORS, not 32B bus beats. One A+B per compute cycle.
module resident_panel_operand_store #(parameter AW=12,ROW_BYTES=32)(
 input wire clk,rst,
 input wire load_start,load_bank,input wire load_scatter,input wire[AW-1:0]load_index,input wire[AW:0]load_a_words,load_b_words,
 output wire load_start_ready,input wire load_valid,input wire[255:0]load_data,
 output wire load_ready,output reg load_done,
 input wire cmd_valid,cmd_bank,input wire[AW-1:0]cmd_a_base,cmd_b_base,
 input wire[AW:0]cmd_steps,output wire cmd_ready,output reg run_done,
 input wire release_valid,release_bank,output wire release_ready,output wire[1:0]bank_ready,
 output reg out_valid,input wire out_ready,
 output reg[ROW_BYTES*8-1:0]out_a,output reg[255:0]out_b,
 output reg out_first,out_last,output reg[1:0]error
);
 localparam ABITS=ROW_BYTES*8,RESBITS=ABITS+256;
 localparam FREE=0,FILL=1,READY=2;
 reg[1:0]state0,state1;reg loading,fill_bank,fill_b;
 reg reuse_b,scatter;reg[AW-1:0]scatter_index;reg[1:0]b_valid;
 reg[AW:0]na0,na1,nb0,nb1,need_a,need_b,fill_count;
 reg[AW+1:0]a_beats_left;
 reg[RESBITS-1:0]reservoir;
 reg[9:0]bit_count;
 reg[ABITS-1:0]mem_a[0:(1<<(AW+1))-1] /* synthesis syn_ramstyle="block_ram" */;
 reg[255:0]mem_b[0:(1<<(AW+1))-1] /* synthesis syn_ramstyle="block_ram" */;
 reg running,active_bank;reg[AW-1:0]abase,bbase;reg[AW:0]steps,issued;
 wire[1:0]ls=load_bank?state1:state0,cs=cmd_bank?state1:state0,rs=release_bank?state1:state0;
 wire[AW:0]ava=cmd_bank?na1:na0,avb=cmd_bank?nb1:nb0;
 wire[AW+1:0]enda={2'b0,cmd_a_base}+{1'b0,cmd_steps},endb={2'b0,cmd_b_base}+{1'b0,cmd_steps};
 assign load_start_ready=!rst&&!loading&&(ls==FREE);
 assign cmd_ready=!rst&&!running;
 assign bank_ready={state1==READY,state0==READY};
 assign release_ready=!rst&&(rs==READY)&&!(running&&active_bank==release_bank)&&!(cmd_valid&&cmd_ready&&cmd_bank==release_bank);
 wire pop_a=loading&&!fill_b&&(bit_count>=ABITS)&&(fill_count<need_a);
 wire[9:0]count_after_pop=bit_count-(pop_a?ABITS:0);
 assign load_ready=!rst&&loading&&(fill_b||((a_beats_left!=0)&&(count_after_pop<=RESBITS-256)));
 wire push=load_valid&&load_ready;
 wire push_a=push&&!fill_b;
 wire[RESBITS-1:0]shifted=pop_a?(reservoir>>ABITS):reservoir;
 wire[RESBITS-1:0]incoming={{ABITS{1'b0}},load_data}<<count_after_pop;
 wire advance=!out_valid||out_ready;
 wire issue=!rst&&running&&advance&&(issued<steps);
 wire[AW-1:0]ra=abase+issued[AW-1:0],rb=bbase+issued[AW-1:0];
 always @(posedge clk)begin
  if(!rst&&pop_a&&(!scatter||({1'b0,scatter_index}<need_a)))mem_a[{fill_bank,(scatter?scatter_index:fill_count[AW-1:0])}]<=reservoir[ABITS-1:0];
  if(push&&fill_b)mem_b[{fill_bank,fill_count[AW-1:0]}]<=load_data;
  if(issue)begin out_a<=mem_a[{active_bank,ra}];out_b<=mem_b[{active_bank,rb}];end
 end
 always @(posedge clk)begin
  if(rst)begin
   state0<=0;state1<=0;reuse_b<=0;b_valid<=0;scatter<=0;scatter_index<=0;loading<=0;fill_bank<=0;fill_b<=0;na0<=0;na1<=0;nb0<=0;nb1<=0;
   need_a<=0;need_b<=0;fill_count<=0;a_beats_left<=0;reservoir<=0;bit_count<=0;
   running<=0;active_bank<=0;abase<=0;bbase<=0;steps<=0;issued<=0;
   load_done<=0;run_done<=0;out_valid<=0;out_first<=0;out_last<=0;error<=0;
  end else begin
   load_done<=0;run_done<=0;error<=0;
   if(release_valid&&release_ready)begin if(release_bank)state1<=FREE;else state0<=FREE;end
   if(load_start&&load_start_ready)begin
    if(load_a_words==0||load_a_words>(1<<AW)||load_b_words>(1<<AW)||(load_b_words==0&&!b_valid[load_bank])||(load_scatter&&ROW_BYTES!=32))error<=1;
    else begin
     loading<=1;fill_bank<=load_bank;fill_b<=0;need_a<=load_a_words;need_b<=load_b_words==0?(load_bank?nb1:nb0):load_b_words;fill_count<=0;
     reuse_b<=load_b_words==0;scatter<=load_scatter;if(load_b_words!=0)b_valid[load_bank]<=0;
     a_beats_left<=((load_a_words*ROW_BYTES)+31)>>5;reservoir<=0;bit_count<=0;
     if(load_bank)state1<=FILL;else state0<=FILL;
    end
   end
   if(loading&&!fill_b)begin
    if(pop_a||push_a)begin
     reservoir<=push_a?(shifted|incoming):shifted;
     bit_count<=count_after_pop+(push_a?256:0);
    end
    if(push_a)begin a_beats_left<=a_beats_left-1;scatter_index<=load_index;if(scatter&&({1'b0,load_index}>=need_a))error<=3;end
    if(pop_a)begin
     fill_count<=fill_count+1;
     if(fill_count+1'b1==need_a)begin
      fill_count<=0;reservoir<=0;bit_count<=0;
      if(reuse_b)begin loading<=0;load_done<=1;
       if(fill_bank)begin state1<=READY;na1<=need_a;end else begin state0<=READY;na0<=need_a;end
      end else fill_b<=1;
     end
    end
   end
   if(push&&fill_b)begin
    if(fill_count+1'b1==need_b)begin
     loading<=0;load_done<=1;b_valid[fill_bank]<=1;
     if(fill_bank)begin state1<=READY;na1<=need_a;nb1<=need_b;end
     else begin state0<=READY;na0<=need_a;nb0<=need_b;end
    end else fill_count<=fill_count+1;
   end
   if(push_a&&scatter&&({1'b0,load_index}>=need_a))begin loading<=0;error<=3;if(fill_bank)state1<=FREE;else state0<=FREE;end
   if(cmd_valid&&cmd_ready)begin
    if(cs!=READY||cmd_steps==0||enda>{1'b0,ava}||endb>{1'b0,avb})error<=2;
    else begin running<=1;active_bank<=cmd_bank;abase<=cmd_a_base;bbase<=cmd_b_base;steps<=cmd_steps;issued<=0;end
   end
   if(advance)begin
    out_valid<=issue;
    if(issue)begin out_first<=issued==0;out_last<=issued+1'b1==steps;issued<=issued+1;end
   end
   if(out_valid&&out_ready&&out_last)begin running<=0;run_done<=1;end
  end
 end
endmodule
