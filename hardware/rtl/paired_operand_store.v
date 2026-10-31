// PA03: expose state dependencies at continuous function call sites.
// Fixed 32-lane operand store. Optional paired load fills the already existing
// A0/A1 banks with INT12 low/high bytes and mirrors a single B read into B0/B1.
// No extra panel RAM capacity. Both banks must be free for a paired load.
// claude_c02 c9: each physical bank is also addressable as two half banks
// (rows [h*2^(AW-1), (h+1)*2^(AW-1))). Virtual bank v={half,bank}. A full-mode
// load/run/release (hmode=0, the original behaviour) owns both halves of its
// bank; a half-mode one owns only {half,bank} and is limited to 2^(AW-1) rows,
// so a paired INT12 step can be loaded into one half while the other computes.
module paired_operand_store #(parameter AW=12,ROW_BYTES=32)(
 input wire clk,rst,load_start,load_bank,load_pair,load_scatter,load_hmode,load_half,
 input wire[AW-1:0]load_index,input wire[AW:0]load_a_words,load_b_words,
 output wire load_start_ready,input wire load_valid,input wire[255:0]load_data,load_high_data,
 output wire load_ready,output reg load_done,
 input wire cmd_valid,cmd_bank,cmd_hmode,cmd_half,input wire[AW-1:0]cmd_a_base,cmd_b_base,
 input wire[AW:0]cmd_steps,output wire cmd_ready,output reg run_done,
 input wire release_valid,release_bank,release_hmode,release_half,output wire release_ready,
 output wire[1:0]bank_ready,output wire[3:0]vbank_ready,
 output reg out_valid,input wire out_ready,output wire[255:0]out_a,out_b,
 output reg out_first,out_last,output reg[1:0]error
);
 localparam FREE=0,FILL=1,READY=2;
 localparam[AW:0]HALF_ROWS=1<<(AW-1);
 reg[1:0]st[0:3];reg[3:0]b_valid;reg[AW:0]na[0:3],nb[0:3];
 reg loading,draining,fill_bank,fill_b,paired,scatter,reuse_b,fill_hmode,fill_half;
 reg[AW:0]need_a,need_b,fill_count;
 reg running,active_bank,active_hmode,active_half,qbank;reg[AW-1:0]abase,bbase;
 reg[AW:0]steps,issued;
 // Virtual banks touched by a (bank, hmode, half) request: full mode = both halves.
 function[3:0]vmask(input b,input hm,input h);
  vmask=hm?(4'b0001<<{h,b}):(b?4'b1010:4'b0101);
 endfunction
 function free4(input[3:0]m,input[7:0]states);
  free4=(!m[0]||states[1:0]==FREE)&&(!m[1]||states[3:2]==FREE)&&(!m[2]||states[5:4]==FREE)&&(!m[3]||states[7:6]==FREE);
 endfunction
 function ready4(input[3:0]m,input[7:0]states);
  ready4=(!m[0]||states[1:0]==READY)&&(!m[1]||states[3:2]==READY)&&(!m[2]||states[5:4]==READY)&&(!m[3]||states[7:6]==READY);
 endfunction
 wire[3:0]lmask=load_pair?(vmask(1'b0,load_hmode,load_half)|vmask(1'b1,load_hmode,load_half)):vmask(load_bank,load_hmode,load_half);
 wire[3:0]cmask=vmask(cmd_bank,cmd_hmode,cmd_half),rmask=vmask(release_bank,release_hmode,release_half);
 wire[3:0]amask=vmask(active_bank,active_hmode,active_half);
 wire[1:0]cv={cmd_hmode&cmd_half,cmd_bank};   // virtual bank holding the counts for this run
 wire[AW:0]ava=na[cv],avb=nb[cv];
 wire[AW+1:0]enda={2'b0,cmd_a_base}+{1'b0,cmd_steps},endb={2'b0,cmd_b_base}+{1'b0,cmd_steps};
 wire[1:0]lv={load_hmode&load_half,load_bank};
 assign load_start_ready=!rst&&!loading&&free4(lmask,{st[3],st[2],st[1],st[0]});
 assign load_ready=!rst&&loading&&!draining;
 assign cmd_ready=!rst&&!running;
 assign vbank_ready={st[3]==READY,st[2]==READY,st[1]==READY,st[0]==READY};
 assign bank_ready={st[1]==READY&&st[3]==READY,st[0]==READY&&st[2]==READY};
 assign release_ready=!rst&&ready4(rmask,{st[3],st[2],st[1],st[0]})&&!(running&&(amask&rmask)!=0)&&!(cmd_valid&&cmd_ready&&(cmask&rmask)!=0);
 wire push=load_valid&&load_ready;
 wire bad_index=scatter&&({1'b0,load_index}>=need_a);
 wire[AW-1:0]write_raw=fill_b||!scatter?fill_count[AW-1:0]:load_index;
 wire[AW-1:0]write_index=fill_hmode?{fill_half,write_raw[AW-2:0]}:write_raw;
 wire advance=!out_valid||out_ready;
 wire issue=!rst&&running&&advance&&issued<steps;
 wire[AW-1:0]ra0=abase+issued[AW-1:0],rb0=bbase+issued[AW-1:0];
 wire[AW-1:0]ra=active_hmode?{active_half,ra0[AW-2:0]}:ra0,rb=active_hmode?{active_half,rb0[AW-2:0]}:rb0;
 wire[255:0]qa[0:1],qb[0:1];
 genvar g;
 generate for(g=0;g<2;g=g+1)begin:BANK
  wire own=paired||fill_bank==g;
  paired_operand_ram #(.AW(AW)) a(.clk(clk),.we(push&&!fill_b&&!bad_index&&own),.wa(write_index),
   .data(paired&&g==1?load_high_data:load_data),.re(issue&&active_bank==g),.ra(ra),.q(qa[g]));
  paired_operand_ram #(.AW(AW)) b(.clk(clk),.we(push&&fill_b&&own),.wa(write_index),
   .data(load_data),.re(issue&&active_bank==g),.ra(rb),.q(qb[g]));
 end endgenerate
 assign out_a=qa[qbank];assign out_b=qb[qbank];
 integer v;
 reg[3:0]fill_mask;
 task finish_load;
  begin
   loading<=0;draining<=0;load_done<=1;
   for(v=0;v<4;v=v+1)if(fill_mask[v])begin st[v]<=READY;na[v]<=need_a;nb[v]<=need_b;b_valid[v]<=1;end
  end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   for(v=0;v<4;v=v+1)begin st[v]<=FREE;na[v]<=0;nb[v]<=0;end
   b_valid<=0;loading<=0;draining<=0;fill_bank<=0;fill_b<=0;paired<=0;scatter<=0;reuse_b<=0;fill_hmode<=0;fill_half<=0;fill_mask<=0;
   need_a<=0;need_b<=0;fill_count<=0;
   running<=0;active_bank<=0;active_hmode<=0;active_half<=0;qbank<=0;abase<=0;bbase<=0;steps<=0;issued<=0;
   load_done<=0;run_done<=0;out_valid<=0;out_first<=0;out_last<=0;error<=0;
  end else begin
   load_done<=0;run_done<=0;error<=0;
   // The bank-local register accepts first; READY/done follow the actual RAM
   // write edge one cycle later. A consumer cannot see a half-written bank.
   if(draining)finish_load();
   if(release_valid&&release_ready)for(v=0;v<4;v=v+1)if(rmask[v])st[v]<=FREE;
   if(load_start&&load_start_ready)begin
    if(ROW_BYTES!=32||load_a_words==0||load_a_words>(1<<AW)||load_b_words>(1<<AW)||
       (load_hmode&&(load_a_words>HALF_ROWS||load_b_words>HALF_ROWS))||
       (load_pair&&load_bank)||(load_b_words==0&&(!b_valid[lv]||(load_pair&&(!b_valid[{lv[1],1'b0}]||!b_valid[{lv[1],1'b1}]||nb[{lv[1],1'b0}]!=nb[{lv[1],1'b1}])))))error<=1;
    else begin
     loading<=1;paired<=load_pair;fill_bank<=load_bank;fill_b<=0;scatter<=load_scatter;reuse_b<=load_b_words==0;
     fill_hmode<=load_hmode;fill_half<=load_half;fill_mask<=lmask;
     need_a<=load_a_words;need_b<=load_b_words==0?nb[lv]:load_b_words;fill_count<=0;
     for(v=0;v<4;v=v+1)if(lmask[v])begin st[v]<=FILL;if(load_b_words!=0)b_valid[v]<=0;end
     // A full-mode load rewrites both halves; a half load invalidates the full view of its bank(s).
    end
   end
   if(push)begin
    if(!fill_b&&bad_index)begin
     loading<=0;error<=3;
     for(v=0;v<4;v=v+1)if(fill_mask[v])begin st[v]<=FREE;b_valid[v]<=0;end
    end else if(fill_count+1==(fill_b?need_b:need_a))begin
     fill_count<=0;
     if(fill_b||reuse_b)draining<=1;else fill_b<=1;
    end else fill_count<=fill_count+1;
   end
   if(cmd_valid&&cmd_ready)begin
    if(!ready4(cmask,{st[3],st[2],st[1],st[0]})||cmd_steps==0||enda>{1'b0,ava}||endb>{1'b0,avb})error<=2;
    else begin running<=1;active_bank<=cmd_bank;active_hmode<=cmd_hmode;active_half<=cmd_half;abase<=cmd_a_base;bbase<=cmd_b_base;steps<=cmd_steps;issued<=0;end
   end
   if(advance)begin
    out_valid<=issue;
    if(issue)begin qbank<=active_bank;out_first<=issued==0;out_last<=issued+1==steps;issued<=issued+1;end
   end
   if(out_valid&&out_ready&&out_last)begin running<=0;run_done<=1;end
  end
 end
endmodule
module paired_operand_ram #(parameter AW=12)(
 input wire clk,we,re,input wire[AW-1:0]wa,ra,input wire[255:0]data,output reg[255:0]q
);
 reg[255:0]mem[0:(1<<AW)-1] /* synthesis syn_ramstyle="block_ram" */;
 // PK: the write-address/data/enable boundary is local to each physical bank.
 // The owner invalidates READY on reset; payload storage needs no broadcast reset.
 reg bank_we /* synthesis syn_preserve=1 */;
 reg[AW-1:0]bank_wa;
 reg[255:0]bank_data;
 always @(posedge clk)begin
  bank_we<=we;bank_wa<=wa;bank_data<=data;
  if(bank_we)mem[bank_wa]<=bank_data;
  if(re)q<=mem[ra];
 end
endmodule
