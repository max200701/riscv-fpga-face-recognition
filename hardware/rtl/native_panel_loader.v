// Native window supplier plus existing-B-bank residency. No duplicate weight RAM.
// Success commits a (base, words, generation) key only after store completion.
module native_panel_loader #(parameter LG=9,PREFETCH=4)(
 input wire clk,rst,start,input wire cfg_bank,cfg_pair,cfg_hmode,cfg_half,
 input wire[31:0]cfg_base,cfg_epoch,cfg_weight_base,cfg_weight_epoch,
 input wire[12:0]cfg_weight_words,
 input wire[15:0]cfg_h,cfg_w,cfg_c,cfg_oh,cfg_ow,cfg_y,cfg_x,
 input wire[8:0]cfg_m,input wire[3:0]cfg_kh,cfg_kw,
 input wire[1:0]cfg_sy,cfg_sx,input wire[3:0]cfg_py,cfg_px,
 input wire cfg_wide,cfg_high,cfg_cache,input wire signed[15:0]cfg_zero,
 output wire ready,output reg done,output reg[3:0]error,
 output wire store_start,store_bank,store_pair,output wire[12:0]store_a_words,store_b_words,input wire store_start_ready,
 output wire store_valid,output wire[255:0]store_data,store_high_data,output wire[11:0]store_index,input wire store_ready,store_done,
 output wire rd_valid,input wire rd_ready,output wire[31:0]rd_addr,output wire[4:0]rd_beats,
 input wire r_valid,output wire r_ready,input wire[255:0]r_data,input wire r_last,r_error,
 output wire[63:0]input_bytes,output reg[63:0]weight_bytes,saved_weight_bytes,loads,
 output wire[63:0]window_cycles,window_hits,window_misses
);
 localparam IDLE=0,CHECK=1,BEGIN_LOAD=2,BEGIN_A=3,A=4,B_REQUEST=5,B_READ=6,WAIT_STORE=7,
  SIZE_WAIT1=8,SIZE_WAIT2=9,SIZE_CHECK=10;
 reg[3:0]state;reg bank,hit,store_seen,pair;reg[31:0]weight_base,weight_epoch,cursor;reg[12:0]awords,bwords,remain;
 // B residency keys: entries 0/1 = full banks, 2+{half,bank} = half banks (claude_c02 c9).
 // A full load overwrites both halves of its bank; a half load overwrites part of the full view.
 reg[4:0]left;reg[5:0]resident;reg[31:0]rb[0:5],repoch[0:5];reg[12:0]rn[0:5];reg hmode;reg lhalf;integer i;
 wire[2:0]ce=cfg_hmode?{1'b0,cfg_half,cfg_bank}+3'd2:{2'b0,cfg_bank};
 wire[2:0]ce0=cfg_hmode?{1'b0,cfg_half,1'b0}+3'd2:3'd0,ce1=cfg_hmode?{1'b0,cfg_half,1'b1}+3'd2:3'd1;
 wire[2:0]se=hmode?{1'b0,lhalf,bank}+3'd2:{2'b0,bank};
 function[5:0]overlap(input hm,input h,input b,input pr);
  overlap=pr?(hm?(6'b000011|(h?6'b110000:6'b001100)):6'b111111)
            :(hm?((6'b000001<<b)|(6'b000100<<{h,b})):((6'b000001<<b)|(6'b000100<<b)|(6'b010000<<b)));
 endfunction
 // Window descriptor is captured by the source at start while caller holds it
 // through done. The integrated sequencer owns this contract.
 wire wr,wd,wv,wo;wire[255:0]wdata,whigh;wire[12:0]wi;wire wl;wire[3:0]we;
 wire war;wire[31:0]waa;wire[4:0]wan;wire wrr;wire[63:0]unused_vec,unused_stall;
 assign ready=!rst&&state==IDLE&&error==0;
 assign store_start=!rst&&state==BEGIN_LOAD&&error==0;assign store_bank=bank;
 assign store_a_words=awords;assign store_b_words=hit?13'd0:bwords;
 assign store_valid=error==0&&((state==A&&wv)||(state==B_READ&&r_valid&&!r_error));
 assign store_data=state==A?wdata:r_data;assign store_high_data=whigh;assign store_pair=pair;
 assign store_index=wi[11:0];
 wire[12:0]page_left=128-{6'b0,cursor[11:5]};
 wire[12:0]bounded=remain<page_left?remain:page_left;
 wire[4:0]bs=bounded>16?16:bounded[4:0];
 assign rd_valid=error==0&&((state==A&&war)||(state==B_REQUEST));
 assign rd_addr=state==A?waa:cursor;assign rd_beats=state==A?wan:bs;
 assign r_ready=error==0&&((state==A&&wrr)||(state==B_READ&&store_ready));
 conv_window_source #(.LG(LG),.PREFETCH(PREFETCH)) window(
 .clk(clk),.rst(rst),.start(state==BEGIN_A),.cfg_base(cfg_base),.cfg_epoch(cfg_epoch),
 .cfg_h(cfg_h),.cfg_w(cfg_w),.cfg_c(cfg_c),.cfg_oh(cfg_oh),.cfg_ow(cfg_ow),.cfg_y(cfg_y),.cfg_x(cfg_x),.cfg_m(cfg_m),
 .cfg_kh(cfg_kh),.cfg_kw(cfg_kw),.cfg_sy(cfg_sy),.cfg_sx(cfg_sx),.cfg_py(cfg_py),.cfg_px(cfg_px),.cfg_wide(cfg_wide),.cfg_high(cfg_high),.cfg_cache(cfg_cache),.cfg_scatter(1'b1),.cfg_zero(cfg_zero),
 .ready(wr),.done(wd),.error(we),.rd_valid(war),.rd_ready(rd_ready&&state==A),.rd_addr(waa),.rd_beats(wan),
 .r_valid(r_valid&&state==A),.r_ready(wrr),.r_data(r_data),.r_last(r_last),.r_error(r_error),
 .out_high_data(whigh),.out_valid(wv),.out_ready(store_ready&&state==A),.out_data(wdata),.out_index(wi),.out_last(wl),
 .cycles(window_cycles),.read_bytes(input_bytes),.hits(window_hits),.misses(window_misses),.vectors(unused_vec),.stall_cycles(unused_stall));
 // PK: register ceil(M/32) separately from each exact bounded product.
 // 16x4 -> 20x4 -> 24x5 uses at most 28 bits, including all invalid descriptors.
 // Start waits for the actual pipeline, no reliance on pre-start idle cycles.
 // Caller still owns the immutable window descriptor through completion.
 reg[19:0]check_ch;
 reg[23:0]check_c;
 reg[27:0]check_a;
 reg[3:0]check_kw;
 reg[4:0]groups0,groups1;
 reg bad_pair;
 always @(posedge clk)begin
  check_ch<=cfg_c*cfg_kh;check_kw<=cfg_kw;
  groups0<=({1'b0,cfg_m}+10'd31)>>5;
  check_c<=check_ch*check_kw;groups1<=groups0;
  check_a<=check_c*groups1;
 end
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;done<=0;error<=0;resident<=0;store_seen<=0;bank<=0;pair<=0;hit<=0;hmode<=0;lhalf<=0;weight_base<=0;weight_epoch<=0;cursor<=0;awords<=0;bwords<=0;remain<=0;left<=0;bad_pair<=0;
   for(i=0;i<6;i=i+1)begin rb[i]<=0;repoch[i]<=0;rn[i]<=0;end weight_bytes<=0;saved_weight_bytes<=0;loads<=0;
  end else begin
   done<=0;if(store_done)store_seen<=1;
   if(we!=0)begin error<=we;resident<=0;state<=IDLE;end
   else if(error==0)case(state)
    IDLE:if(start)begin
     bank<=cfg_bank;pair<=cfg_pair;hmode<=cfg_hmode;lhalf<=cfg_half;weight_base<=cfg_weight_base;weight_epoch<=cfg_weight_epoch;bwords<=cfg_weight_words;
     hit<=resident[ce]&&rb[ce]==cfg_weight_base&&rn[ce]==cfg_weight_words&&repoch[ce]==cfg_weight_epoch&&
      (!cfg_pair||(resident[ce0]&&resident[ce1]&&rb[ce0]==rb[ce1]&&rn[ce0]==rn[ce1]&&repoch[ce0]==repoch[ce1]));
     store_seen<=0;state<=SIZE_WAIT1;bad_pair<=cfg_pair&&(!cfg_wide||cfg_high||cfg_bank);
    end
    SIZE_WAIT1:state<=SIZE_WAIT2;
    SIZE_WAIT2:state<=SIZE_CHECK;
    SIZE_CHECK:begin
     awords<=check_a[12:0];state<=CHECK;
     if(check_a==0||check_a>4096)error<=7;else if(bad_pair)error<=10;
    end
    CHECK:if(bwords==0||bwords>4096||weight_base[4:0]!=0||({1'b0,weight_base}+({20'b0,bwords}<<5))>33'h40000000)begin error<=8;state<=IDLE;end
    else begin if(!hit)resident<=resident&~overlap(hmode,lhalf,bank,pair);state<=BEGIN_LOAD;end
    BEGIN_LOAD:if(store_start_ready)state<=BEGIN_A;
    BEGIN_A:if(wr)state<=A;
    A:if(wd)begin
     if(hit)state<=WAIT_STORE;
     else begin cursor<=weight_base;remain<=bwords;state<=B_REQUEST;end
    end
    B_REQUEST:if(rd_ready)begin left<=bs;state<=B_READ;end
    B_READ:if(r_valid&&store_ready)begin
     if(r_error||r_last!=(left==1))begin error<=9;resident<=0;state<=IDLE;end
     else begin
      cursor<=cursor+32;remain<=remain-1;left<=left-1;weight_bytes<=weight_bytes+32;
      if(left==1)state<=remain==1?WAIT_STORE:B_REQUEST;
     end
    end
    WAIT_STORE:if(store_seen||store_done)begin
     resident[se]<=1;rb[se]<=weight_base;rn[se]<=bwords;repoch[se]<=weight_epoch;
     if(pair)begin resident[se|3'd1]<=1;rb[se|3'd1]<=weight_base;rn[se|3'd1]<=bwords;repoch[se|3'd1]<=weight_epoch;end
     if(hit)saved_weight_bytes<=saved_weight_bytes+({51'b0,bwords}<<5);
     loads<=loads+1;done<=1;state<=IDLE;
    end
   endcase
  end
 end
endmodule
