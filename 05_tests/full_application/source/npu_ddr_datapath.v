// Consolidated NPU-domain panel scheduler + asynchronous HMIC read/write path.
// DDR PHY/PLL and CPU MMIO are integration boundaries, not behavioral substitutes.
// posted_done means HMIC accepted result writes. Software may transfer ownership
// only after the controller-specific visibility/readback gate (not implemented
// as a fabricated B-response). Global reset must quiesce the external controller.
module npu_ddr_datapath #(parameter AW=12,PANGO_SIMD=1,TIMEOUT_CYCLES=65535,ROW_GROUPS=4)(
 input wire arst,npu_clk,ddr_clk,ddr_init_done,
 input wire[31:0]layout_base,layout_plane,layout_spatial,layout_channel,
 input wire[8:0]layout_m,layout_n,input wire[1:0]layout_mode,input wire[2:0]layout_op,
 input wire[39:0]layout_den,input wire[31:0]layout_recip,input wire signed[15:0]layout_zero,input wire[4:0]layout_bits,
 input wire[31:0]window_epoch,weight_epoch,
 input wire[15:0]window_h,window_w,window_c,window_oh,window_ow,window_y,window_x,
 input wire[8:0]window_m,input wire[3:0]window_kh,window_kw,window_py,window_px,
 input wire[1:0]window_sy,window_sx,input wire window_wide,window_high,window_pair,
 input wire signed[15:0]window_zero,
 input wire load_valid,output wire load_ready,input wire load_bank,load_hmode,load_half,
 input wire[31:0]load_a_addr,load_b_addr,input wire[AW:0]load_a_words,load_b_words,
 output wire load_done,
 input wire release_valid,release_bank,release_hmode,release_half,output wire release_ready,output wire[1:0]bank_ready,
 input wire cmd_valid,cmd_bank,cmd_hmode,cmd_half,cmd_first,cmd_last,cmd_wide,cmd_shift8,cmd_q16,input wire[15:0]cmd_k,
 input wire[3:0]cmd_mtiles,cmd_ntiles,input wire[31:0]cmd_dest,
 output wire cmd_ready,output wire compute_done,output reg posted_done,
 input wire params_prelu,params_load_valid,output wire params_load_ready,input wire[31:0]params_load_addr,input wire[8:0]params_load_count,output reg params_load_done,
 input wire param_valid,input wire[7:0]param_index,input wire signed[31:0]param_bias,
 input wire[31:0]param_multiplier,input wire signed[31:0]param_post_bias,input wire[5:0]param_shift,output wire param_ready,
 input wire signed[7:0]zero_point,clamp_min,clamp_max,
 output wire fault,output reg[3:0]local_error,
 output wire axi_arvalid,input wire axi_arready,output wire[27:0]axi_araddr,
 output wire[3:0]axi_arlen,axi_aruser_id,output wire axi_aruser_ap,
 input wire axi_rvalid,input wire[255:0]axi_rdata,input wire axi_rlast,input wire[3:0]axi_rid,
 output wire axi_awvalid,input wire axi_awready,output wire[27:0]axi_awaddr,
 output wire[3:0]axi_awlen,axi_awuser_id,output wire axi_awuser_ap,
 output wire[255:0]axi_wdata,output wire[31:0]axi_wstrb,
 input wire axi_wready,input wire[3:0]axi_wusero_id,input wire axi_wusero_last,
 output wire[63:0]cycles,mac_cycles,input_wait_cycles,result_wait_cycles,
 output wire[63:0]input_words,output_bytes,tiles,overlap_cycles,
 output wire[63:0]read_bytes_ui,write_bytes_ui,credit_stalls_ui
);
 localparam ROWS=ROW_GROUPS*8;
 (* ASYNC_REG="TRUE" *)reg[1:0]rst_pipe;
 always @(posedge npu_clk or posedge arst)if(arst)rst_pipe<=3;else rst_pipe<={rst_pipe[0],1'b0};
 // registered, replicated synchronous resets (asserted asynchronously with arst,
 // released one npu_clk edge after rst_pipe[1]) instead of one combinational arst||rst_pipe net
 // fanning out to the whole NPU. rst_local: this module; the others feed loader / core / tail.
 reg rst_local,rst_loader,rst_core,rst_tail /* synthesis syn_preserve=1 */;
 always @(posedge npu_clk or posedge arst)
  if(arst)begin rst_local<=1;rst_loader<=1;rst_core<=1;rst_tail<=1;end
  else begin rst_local<=rst_pipe[1];rst_loader<=rst_pipe[1];rst_core<=rst_pipe[1];rst_tail<=rst_pipe[1];end
 wire rst=rst_local;
 // registered copies of the LAYOUT M/N for the core and the tail (written by a LAYOUT
 // command, several cycles before the RUN that uses them); keeps the queue->core wire register-to-register.
 reg[8:0]core_m,core_n,tail_m,tail_n /* synthesis syn_preserve=1 */;
 always @(posedge npu_clk)begin core_m<=layout_m;core_n<=layout_n;tail_m<=layout_m;tail_n<=layout_n;end
 wire transport_fault;assign fault=transport_fault||(local_error!=0);
 reg loading,all_issued;reg[31:0]cursor;reg[AW+1:0]remaining;
 reg operation_active,arithmetic_finished;wire rv,rl,re;wire[255:0]rdata;
 reg params_mode,params_half,params_has_prelu;reg[8:0]params_count,params_index;
 wire core_param_ready,start_ready,sload_done,sdata_ready;
 wire native_ready,native_done,native_rd,native_rr,ns,nsv,nsbank;
 wire[31:0]native_addr;wire[4:0]native_beats;wire[3:0]native_error;
 wire[12:0]naw,nbw;wire[11:0]nindex;wire[255:0]nsdata,nshigh;wire nspair;
 wire[63:0]native_input_bytes,native_weight_bytes,native_saved_bytes,native_loads,
 native_cycles,native_hits,native_misses;
 assign param_ready=core_param_ready&&!params_mode;
 assign params_load_ready=!rst&&!fault&&!params_mode&&native_ready&&!operation_active&&core_param_ready;
 wire params_start=params_load_valid&&params_load_ready;
 wire[32:0]params_end={1'b0,params_load_addr}+({24'b0,params_load_count}<<4);
 wire params_bad=params_load_count==0||params_load_count>256||params_load_addr[4:0]!=0||params_end>33'h40000000;
 wire[127:0]param_record=params_half?rdata[255:128]:rdata[127:0];
 wire params_emit=params_mode&&rv&&!re&&!fault&&core_param_ready;
 wire params_final=params_index+1'b1==params_count;
 wire params_receive=params_mode&&core_param_ready&&(params_half||params_final);
 wire data_ready=params_mode?params_receive:native_rr;
 assign load_ready=!rst&&!fault&&!params_mode&&native_ready;
 wire start=load_valid&&load_ready;
 assign load_done=native_done&&!fault;
 wire rd_ready,rd_valid;wire[4:0]rd_beats;wire[31:0]rd_address;
 wire[7:0]page_beats=8'd128-{1'b0,cursor[11:5]};
 wire[AW+1:0]limit_page=(remaining<page_beats)?remaining:page_beats;
 wire[4:0]param_beats=limit_page>16?5'd16:limit_page[4:0];
 assign rd_beats=params_mode?param_beats:native_beats;
 assign rd_address=params_mode?cursor:native_addr;
 assign rd_valid=!fault&&(params_mode?(loading&&!all_issued):native_rd);
 native_panel_loader loader(.clk(npu_clk),.rst(rst_loader),.start(start),.cfg_bank(load_bank),.cfg_hmode(load_hmode),.cfg_half(load_half),.cfg_pair(window_pair),
  .cfg_base(load_a_addr),.cfg_epoch(window_epoch),.cfg_weight_base(load_b_addr),.cfg_weight_epoch(weight_epoch),.cfg_weight_words(load_b_words),
  .cfg_h(window_h),.cfg_w(window_w),.cfg_c(window_c),.cfg_oh(window_oh),.cfg_ow(window_ow),.cfg_y(window_y),.cfg_x(window_x),.cfg_m(window_m),
  .cfg_kh(window_kh),.cfg_kw(window_kw),.cfg_sy(window_sy),.cfg_sx(window_sx),.cfg_py(window_py),.cfg_px(window_px),
  .cfg_wide(window_wide),.cfg_high(window_high),.cfg_cache(1'b1),.cfg_zero(window_zero),
  .ready(native_ready),.done(native_done),.error(native_error),.store_pair(nspair),.store_high_data(nshigh),.store_start(ns),.store_bank(nsbank),.store_a_words(naw),.store_b_words(nbw),
  .store_start_ready(start_ready),.store_valid(nsv),.store_data(nsdata),.store_index(nindex),.store_ready(sdata_ready),.store_done(sload_done),
  .rd_valid(native_rd),.rd_ready(rd_ready&&!params_mode&&!fault),.rd_addr(native_addr),.rd_beats(native_beats),
  .r_valid(rv&&!params_mode),.r_ready(native_rr),.r_data(rdata),.r_last(rl),.r_error(re),
  .input_bytes(native_input_bytes),.weight_bytes(native_weight_bytes),.saved_weight_bytes(native_saved_bytes),.loads(native_loads),
  .window_cycles(native_cycles),.window_hits(native_hits),.window_misses(native_misses));

 wire cr,cdone,ov,ore,outputs_idle;wire[3:0]core_error;wire[127:0]odata;wire[31:0]oaddr;

 assign cmd_ready=cr&&!operation_active&&!fault&&!rst;
 assign compute_done=cdone&&!fault;
 panel_compute #(.AW(AW),.PANGO_SIMD(PANGO_SIMD),.ROW_GROUPS(ROW_GROUPS)) core(
  .clk(npu_clk),.rst(rst_core),.load_pair(nspair),.load_high_data(nshigh),.load_start(ns),.load_bank(nsbank),.load_hmode(load_hmode),.load_half(load_half),.load_index(nindex),
  .load_a_words(naw),.load_b_words(nbw),.load_start_ready(start_ready),
  .load_valid(nsv&&!fault),.load_data(nsdata),.load_ready(sdata_ready),.load_done(sload_done),
  .release_valid(release_valid&&!fault),.release_bank(release_bank),.release_hmode(release_hmode),.release_half(release_half),.release_ready(release_ready),.bank_ready(bank_ready),
  .cmd_valid(cmd_valid&&cmd_ready),.cmd_bank(cmd_bank),.cmd_hmode(cmd_hmode),.cmd_half(cmd_half),.cmd_first(cmd_first),.cmd_last(cmd_last),
  .cmd_k(cmd_k),.cmd_mtiles(cmd_mtiles),.cmd_ntiles(cmd_ntiles),.cmd_dest(cmd_dest),.cmd_wide(cmd_wide),.cmd_shift8(cmd_shift8),.cmd_q16(cmd_q16),
  .cmd_ready(cr),.cmd_done(cdone),.error(core_error),
  .param_valid(params_mode?params_emit:param_valid),.param_index(params_mode?params_index[7:0]:param_index),.param_bias(params_mode?param_record[31:0]:param_bias),
  .param_multiplier(params_mode?param_record[63:32]:param_multiplier),.param_post_bias(params_mode?param_record[95:64]:param_post_bias),.param_shift(params_mode?6'd24:param_shift),.param_ready(core_param_ready),
  .zero_point(zero_point),.clamp_min(clamp_min),.clamp_max(clamp_max),.cfg_m(core_m),.cfg_n(core_n),
  .out_valid(ov),.out_ready(ore),.out_data(odata),.out_addr(oaddr),
  .cycles(cycles),.mac_cycles(mac_cycles),.input_wait_cycles(input_wait_cycles),.result_wait_cycles(result_wait_cycles),
  .input_words(input_words),.output_bytes(output_bytes),.tiles(tiles),.overlap_cycles(overlap_cycles),.outputs_idle(outputs_idle));
 wire tv,tr,tl,tposted,tpostready,taildone;wire[31:0]ta,ts,tt,tposttag;wire[255:0]td;wire[3:0]tailerror;
 reg final_segment,tail_finished;
 wire[63:0]usefulwrites,writebursts,fullbursts,idleflush;
 npu_layout_tail tail(.clk(npu_clk),.rst(rst_tail),.start(cmd_valid&&cmd_ready&&cmd_last),
  .param_begin(params_start),.param_valid(params_emit&&params_has_prelu),.param_index(params_index[7:0]),.param_value(param_record[127:96]),
  .mtiles(cmd_mtiles),.ntiles(cmd_ntiles),.logical_base(cmd_dest),
  .cfg_base(layout_base),.cfg_plane(layout_plane),.cfg_spatial(layout_spatial),.cfg_channel(layout_channel),
  .cfg_m(tail_m),.cfg_n(tail_n),.cfg_mode(layout_mode),.cfg_op(layout_op),
  .cfg_den(layout_den),.cfg_recip(layout_recip),.cfg_zero(layout_zero),.cfg_bits(layout_bits),
  .in_valid(ov),.in_ready(ore),.in_q16(odata),.in_addr(oaddr),
  .out_valid(tv),.out_ready(tr),.out_data(td),.out_addr(ta),.out_strb(ts),.out_tag(tt),.out_last(tl),
  .posted_valid(tposted),.posted_ready(tpostready),.posted_tag(tposttag),.done(taildone),.error(tailerror));
 hmic_layout_cdc #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) transport(
  .arst(arst),.npu_clk(npu_clk),.ddr_clk(ddr_clk),.ddr_init_done(ddr_init_done),
  .rd_valid(rd_valid),.rd_ready(rd_ready),.rd_addr(rd_address),.rd_beats(rd_beats),
  .r_valid(rv),.r_ready(data_ready||fault),.r_data(rdata),.r_last(rl),.r_error(re),
  .in_valid(tv),.in_ready(tr),.in_addr(ta),.in_data(td),.in_strb(ts),.in_tag(tt),.in_last(tl),
  .posted_valid(tposted),.posted_ready(tpostready),.posted_tag(tposttag),.fault_npu(transport_fault),
  .axi_arvalid(axi_arvalid),.axi_arready(axi_arready),.axi_araddr(axi_araddr),.axi_arlen(axi_arlen),
  .axi_aruser_id(axi_aruser_id),.axi_aruser_ap(axi_aruser_ap),.axi_rvalid(axi_rvalid),.axi_rdata(axi_rdata),.axi_rlast(axi_rlast),.axi_rid(axi_rid),
  .axi_awvalid(axi_awvalid),.axi_awready(axi_awready),.axi_awaddr(axi_awaddr),.axi_awlen(axi_awlen),
  .axi_awuser_id(axi_awuser_id),.axi_awuser_ap(axi_awuser_ap),.axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),
  .axi_wready(axi_wready),.axi_wusero_id(axi_wusero_id),.axi_wusero_last(axi_wusero_last),
  .read_bytes_ui(read_bytes_ui),.write_bytes_ui(write_bytes_ui),.credit_stalls_ui(credit_stalls_ui),
  .useful_write_bytes_ui(usefulwrites),.write_bursts_ui(writebursts),.full_bursts_ui(fullbursts),.idle_flushes_ui(idleflush));
 always @(posedge npu_clk)begin
  if(rst)begin
   loading<=0;all_issued<=0;cursor<=0;remaining<=0;
   local_error<=0;final_segment<=0;tail_finished<=0;params_mode<=0;params_half<=0;params_has_prelu<=0;params_index<=0;params_count<=0;params_load_done<=0;
   operation_active<=0;arithmetic_finished<=0;posted_done<=0;
  end else begin
   posted_done<=0;params_load_done<=0;
   if(native_error!=0)local_error<=native_error;
   if(params_start)begin
    if(params_bad)local_error<=12;
    else begin
     loading<=1;all_issued<=0;cursor<=params_load_addr;remaining<=({1'b0,params_load_count}+1)>>1;
     params_mode<=1;params_half<=0;params_has_prelu<=params_prelu;params_index<=0;params_count<=params_load_count;
    end
   end
   if(params_emit)begin
    if((!params_has_prelu&&param_record[127:96]!=0)||(params_has_prelu&&($signed(param_record[127:96]) < -32'sd1048576 || $signed(param_record[127:96])>32'sd1048576)))local_error<=13;
    else if(params_final)begin params_mode<=0;loading<=0;params_load_done<=1;params_half<=0;end
    else begin params_index<=params_index+1'b1;params_half<=!params_half;end
   end
   if(params_mode&&rd_valid&&rd_ready)begin   // rd_beats==param_beats in params mode
    if(remaining==param_beats)begin remaining<=0;all_issued<=1;end
    else begin remaining<=remaining-param_beats;cursor<=cursor+{22'b0,param_beats,5'b0};end
   end
   if(rv&&re)local_error<=2;
   if(core_error!=0)local_error<=core_error;
   if(tailerror!=0)local_error<=tailerror;
   if(taildone)tail_finished<=1;
   if(cmd_valid&&cmd_ready)begin
    operation_active<=1;arithmetic_finished<=0;final_segment<=cmd_last;tail_finished<=0;
    if(!cmd_wide||!cmd_q16)local_error<=11;
   end
   if(cdone)arithmetic_finished<=1;
   if(operation_active&&arithmetic_finished&&(!final_segment||tail_finished)&&outputs_idle&&!fault)begin
    operation_active<=0;arithmetic_finished<=0;posted_done<=1;
   end
  end
 end
endmodule
