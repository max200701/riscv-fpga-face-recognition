`timescale 1ns/1ps
module cpu_soc #(parameter integer CLOCK_HZ=27000000, BAUD=115200,
 parameter ICACHE_ENABLE=1, ICACHE_SET_BITS=7, ICACHE_DATA_BRAM=0, DCACHE_ENABLE=1, MACHINE_ENABLE=1, BURST_ENABLE=1, M_ENABLE=1, FENCEI_ENABLE=1)(
 input wire clk,rst_n,uart_rx_pin,output wire uart_tx_pin,output reg [3:0] gpio,
 output reg [31:0] status,output wire halted,output wire [31:0] trap_cause,
 output wire [159:0] debug_data,output wire [3:0] debug_trigger,
 output wire ext_valid,ext_write,output wire[11:0]ext_addr,output wire[31:0]ext_wdata,output wire[3:0]ext_wstrb,
 input wire ext_ready,ext_error,input wire[31:0]ext_rdata,input wire ext_irq);
 wire [31:0]lookahead,fetch_tag,data_lookahead;wire iv,ir,ie,dv,dw,dr,de,ipair;wire [31:0] id1,ipa;
 wire [31:0] ia,id,da,wd,rd;
 wire [3:0] ws;
 reg ext_sel,rom_sel,ram_sel,uart_data,uart_status,gpio_sel,status_sel,timer_lo,timer_hi,rx_data_sel,rx_status_sel,uart_irq_sel,cmp_lo,cmp_hi,msip_sel,bad_write;
 reg uart_wait_q;wire dp,dpw;wire[31:0]dpa;wire[3:0]dps;
 wire[31:0]ram_data;
 wire[2:0]dpf3;wire[31:0]local_formatted_load;
 wire retire_valid,if_stage_valid,ex_stage_valid,wb_stage_valid;
 wire pipeline_stall,pipeline_flush,instruction_fence;
 wire [31:0] retire_pc,retire_insn,retire_data,retire_next_pc;
 wire [4:0] retire_rd;
 wire [63:0] cycle_count,instret_count,stall_count,flush_count,forward_count;
 wire uart_irq,timer_irq,software_irq;
 rv32_core #(.LOCAL_FORMATTED_LOAD(1),.TARGET_PAIR_FETCH(0),.PAIR_FETCH(1),.MACHINE_ENABLE(MACHINE_ENABLE),.M_ENABLE(M_ENABLE),.FENCEI_ENABLE(FENCEI_ENABLE)) core(.clk(clk),.rst_n(rst_n),.irq_external(uart_irq|ext_irq),.irq_timer(timer_irq),.irq_software(software_irq),.i_valid(iv),.i_addr(ia),.i_ready(ir),.i_rdata(id),.i_pair_addr(ipa),.i_lookahead_addr(lookahead),.i_pair_valid(ipair),.i_rdata1(id1),.i_error(ie),
   .d_valid(dv),.d_write(dw),.d_addr(da),.d_wdata(wd),.d_wstrb(ws),.d_lookahead_addr(data_lookahead),.d_prepare_valid(dp),.d_prepare_addr(dpa),.d_prepare_write(dpw),.d_prepare_wstrb(dps),.d_ready(dr),.d_rdata(rd),.d_error(de),
   .d_prepare_size(dpf3),.local_load_valid(ram_sel),.local_load_data(local_formatted_load),.local_raw_load_data(ram_data),
   .halted(halted),.trap_cause(trap_cause),.trap_pc(),.trap_value(),.retire_valid(retire_valid),.retire_pc(retire_pc),
   .retire_insn(retire_insn),.retire_rd(retire_rd),.retire_data(retire_data),.retire_next_pc(retire_next_pc),
   .cycle_count(cycle_count),.instret_count(instret_count),.stall_count(stall_count),.flush_count(flush_count),
   .forward_count(forward_count),.if_stage_valid(if_stage_valid),.ex_stage_valid(ex_stage_valid),
   .wb_stage_valid(wb_stage_valid),.pipeline_stall(pipeline_stall),.pipeline_flush(pipeline_flush),.instruction_fence(instruction_fence));

 // Packed, vendor-neutral observation interface. The remote board wrapper adds
 // the PDS debug attributes so this SoC remains usable with other toolchains.
 assign debug_data={cycle_count[11:0],trap_cause[4:0],halted,dw,dr,dv,
   pipeline_flush,pipeline_stall,wb_stage_valid,ex_stage_valid,if_stage_valid,
   retire_valid,retire_rd,da,retire_data,retire_insn,retire_pc};
 assign debug_trigger={halted,pipeline_flush,pipeline_stall,retire_valid};

 wire [31:0]icache_hits=0,icache_misses=0,dcache_hits=0,dcache_misses=0;
 wire bv=dv,bw=dw;wire br,be;wire[31:0]ba=da,bdw=wd;wire[31:0]bdr;wire[3:0]bs=ws;
 assign dr=br;assign de=be;assign rd=bdr;
 
 assign ext_valid=bv&&ext_sel;assign ext_write=bw;assign ext_addr=ba[11:0];assign ext_wdata=bdw;assign ext_wstrb=bs;
 
 wire rom_ready=1'b1;wire[31:0]rom_data=0;wire ram_ready;
 sprint_tcm ram(.clk(clk),.rst_n(rst_n),.fetch_addr(lookahead),.fetch_tag(fetch_tag),.insn0(id),.insn1(id1),
   .valid(bv&&ram_sel),.write(bw),.word_addr(ba[15:2]),.read_word_addr(data_lookahead[15:2]),.wdata(bdw),.wstrb(bs),.ready(ram_ready),.rdata(ram_data),
   .format_prepare(dp),.format_local(dpa[31:16]==1),.format_size(dpf3),.format_offset(dpa[1:0]),.formatted_data(local_formatted_load));
 // AY: this adapter owns a fixed one-edge TCM, and both response tag
 // and request PC capture the same lookahead selection. No external fetch can
 // stall or reorder here. Keep the identity assertion in all RTL simulations;
 // a future variable-latency instruction interface must restore a handshake.
 assign ir=iv;
`ifndef SYNTHESIS
 always @(posedge clk)if(rst_n && iv && fetch_tag!==ia)
   $fatal(1,"AY fixed-latency TCM request/response identity");
`endif
 // BD: response eligibility is metadata sampled with the actual one-edge
 // instruction TCM. It no longer decodes the current PC in the predictor's
 // address-selection feedback loop. No extra request or response cycle.
 reg fetch_fault_q,fetch_pair_room_q;
 always @(posedge clk)begin
   fetch_fault_q<=lookahead[31:16]>1;
   fetch_pair_room_q<=lookahead[15:2]!=14'h3fff;
 end
 assign ie=fetch_fault_q;
 assign ipair=ir && !fetch_fault_q && fetch_pair_room_q;
`ifndef SYNTHESIS
 always @(posedge clk)if(rst_n && iv)begin
   if(ie!==(ia[31:16]>1))$fatal(1,"BD fetch fault metadata identity");
   if(ipair!==(ir && !(ia[31:16]>1) && ia[15:2]!=14'h3fff))$fatal(1,"BD pair boundary metadata identity");
 end
`endif
 
 
 
 
 
 wire mmio=uart_data || uart_status || gpio_sel || status_sel || timer_lo || timer_hi ||
   rx_data_sel || rx_status_sel || uart_irq_sel || cmp_lo || cmp_hi || msip_sel;
 wire busy;
 // AP: address map and write-permission decode are X/M snapshot registers.
 // Live external-ready/UART-busy are still observed during the M transaction.
 always @(posedge clk)begin
   if(!rst_n)begin
     ext_sel<=0;
     rom_sel<=0;
     ram_sel<=0;
     uart_data<=0;
     uart_status<=0;
     gpio_sel<=0;
     status_sel<=0;
     timer_lo<=0;
     timer_hi<=0;
     rx_data_sel<=0;
     rx_status_sel<=0;
     uart_irq_sel<=0;
     cmp_lo<=0;
     cmp_hi<=0;
     msip_sel<=0;
     bad_write<=0;
     uart_wait_q<=0;
   end else if(dp)begin
     uart_wait_q<=dpa==32'h10000100 && dpw && (dps==4'b0001 || dps==4'b1111);
     ext_sel<=dpa[31:12]==20'h10010;
     rom_sel<=dpa[31:16]==0;
     ram_sel<=dpa[31:16]==1;
     uart_data<=dpa==32'h10000100;
     uart_status<=dpa==32'h10000104;
     gpio_sel<=dpa==32'h10000200;
     status_sel<=dpa==32'h10000000;
     timer_lo<=dpa==32'h10000300;
     timer_hi<=dpa==32'h10000304;
     rx_data_sel<=dpa==32'h10000108;
     rx_status_sel<=dpa==32'h1000010c;
     uart_irq_sel<=dpa==32'h10000110;
     cmp_lo<=dpa==32'h10000308;
     cmp_hi<=dpa==32'h1000030c;
     msip_sel<=dpa==32'h10000310;
     bad_write<=dpw && (((dpa==32'h10000100) && dps!=4'b0001 && dps!=4'b1111) ||
   (((dpa==32'h10000200) || (dpa==32'h10000000)) && dps!=4'b1111) || (dpa==32'h10000104) || (dpa==32'h10000300) || (dpa==32'h10000304) || (dpa==32'h10000108) ||
   (((dpa==32'h1000010c) || (dpa==32'h10000110) || (dpa==32'h10000308) || (dpa==32'h1000030c) || (dpa==32'h10000310)) && dps!=4'b1111));
   end
 end
`ifndef SYNTHESIS
 always @(posedge clk)if(rst_n && bv)begin
   if(ext_sel!==(ba[31:12]==20'h10010))$fatal(1,"AP snapshot ext_sel");
   if(rom_sel!==(ba[31:16]==0))$fatal(1,"AP snapshot rom_sel");
   if(ram_sel!==(ba[31:16]==1))$fatal(1,"AP snapshot ram_sel");
   if(uart_data!==(ba==32'h10000100))$fatal(1,"AP snapshot uart_data");
   if(uart_status!==(ba==32'h10000104))$fatal(1,"AP snapshot uart_status");
   if(gpio_sel!==(ba==32'h10000200))$fatal(1,"AP snapshot gpio_sel");
   if(status_sel!==(ba==32'h10000000))$fatal(1,"AP snapshot status_sel");
   if(timer_lo!==(ba==32'h10000300))$fatal(1,"AP snapshot timer_lo");
   if(timer_hi!==(ba==32'h10000304))$fatal(1,"AP snapshot timer_hi");
   if(rx_data_sel!==(ba==32'h10000108))$fatal(1,"AP snapshot rx_data_sel");
   if(rx_status_sel!==(ba==32'h1000010c))$fatal(1,"AP snapshot rx_status_sel");
   if(uart_irq_sel!==(ba==32'h10000110))$fatal(1,"AP snapshot uart_irq_sel");
   if(cmp_lo!==(ba==32'h10000308))$fatal(1,"AP snapshot cmp_lo");
   if(cmp_hi!==(ba==32'h1000030c))$fatal(1,"AP snapshot cmp_hi");
   if(msip_sel!==(ba==32'h10000310))$fatal(1,"AP snapshot msip_sel");
   if(bad_write!==(bw && ((uart_data && bs!=4'b0001 && bs!=4'b1111) ||
   ((gpio_sel || status_sel) && bs!=4'b1111) || uart_status || timer_lo || timer_hi || rx_data_sel ||
   ((rx_status_sel || uart_irq_sel || cmp_lo || cmp_hi || msip_sel) && bs!=4'b1111))))$fatal(1,"AP write permission snapshot");
 end
`endif
 assign be=ext_sel ? ext_error : rom_sel ? bw : ram_sel ? 1'b0 : (!mmio || bad_write || (uart_data && !bw));
 // Fixed TCM/ROM and nonblocking registers always respond. Only a legal
 // UART TX write and the external slave can wait. Error reporting remains be.
 assign br=rst_n && (ext_sel ? ext_ready : uart_wait_q ? !busy : 1'b1);
`ifndef SYNTHESIS
 always @(posedge clk)if(rst_n && bv)begin
   if(br!==(rst_n && (ext_sel ? ext_ready : rom_sel ? rom_ready : ram_sel ? ram_ready : (be || !uart_data || !busy))))
     $fatal(1,"BC response-capacity qualification mismatch");
 end
`endif
 reg [63:0] timer,timer_compare;
 reg msip;
 reg [2:0] uart_irq_enable;
 reg [7:0] rx_fifo[0:3];reg [1:0] rx_wptr,rx_rptr;reg [2:0] rx_count;
 reg rx_overrun,rx_framing;
 wire [7:0] rx_byte;wire rx_ready,rx_bad;
 wire rx_pop=bv && br && !bw && !be && rx_data_sel && rx_count!=0;
 wire rx_push=rx_ready && (rx_count<4 || rx_pop);
 assign uart_irq=(uart_irq_enable[0] && rx_count!=0) ||
   (uart_irq_enable[1] && rx_overrun) || (uart_irq_enable[2] && rx_framing);
 assign timer_irq=timer>=timer_compare;
 assign software_irq=msip;
 uart_rx #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) receiver(.clk(clk),.rst_n(rst_n),
   .rx(uart_rx_pin),.data(rx_byte),.ready(rx_ready),.frame_error(rx_bad));
 // CB: local TCM data has its own formatted path into the CPU load result.
 // It is intentionally absent from bdr, whose original-priority assertion now
 // checks only peripheral data. The complete accepted load still compares with
 // original raw TCM data plus ISA alignment/sign extension in rv32_core.
 // BQ: all region selectors are mutually-exclusive captured address decodes.
 // A parallel one-hot data merge avoids the inherited long MMIO priority chain.
 assign bdr=({32{ext_sel}}&ext_rdata)|({32{rom_sel}}&rom_data)|
   ({32{uart_status}}&{31'b0,busy})|({32{gpio_sel}}&{28'b0,gpio})|({32{status_sel}}&status)|
   ({32{timer_lo}}&timer[31:0])|({32{timer_hi}}&timer[63:32])|
   ({32{rx_data_sel && rx_count!=0}}&{24'b0,rx_fifo[rx_rptr]})|
   ({32{rx_status_sel}}&{24'b0,rx_count,2'b0,rx_framing,rx_overrun,(rx_count!=0)})|
   ({32{uart_irq_sel}}&{29'b0,uart_irq_enable})|({32{cmp_lo}}&timer_compare[31:0])|
   ({32{cmp_hi}}&timer_compare[63:32])|({32{msip_sel}}&{31'b0,msip});
`ifndef SYNTHESIS
 wire[13:0]data_selects={ext_sel,rom_sel,ram_sel,uart_status,gpio_sel,status_sel,timer_lo,timer_hi,
   rx_data_sel,rx_status_sel,uart_irq_sel,cmp_lo,cmp_hi,msip_sel};
 wire[31:0]bdr_priority_reference;
 assign bdr_priority_reference=ext_sel ? ext_rdata : rom_sel ? rom_data : ram_sel ? 32'b0 : uart_status ? {31'b0,busy} :
   gpio_sel ? {28'b0,gpio} : status_sel ? status : timer_lo ? timer[31:0] : timer_hi ? timer[63:32] :
   rx_data_sel ? (rx_count!=0 ? {24'b0,rx_fifo[rx_rptr]} : 32'b0) :
   rx_status_sel ? {24'b0,rx_count,2'b0,rx_framing,rx_overrun,(rx_count!=0)} :
   uart_irq_sel ? {29'b0,uart_irq_enable} : cmp_lo ? timer_compare[31:0] :
   cmp_hi ? timer_compare[63:32] : msip_sel ? {31'b0,msip} : 32'b0;

 always @(posedge clk)if(rst_n && bv)begin
   if((data_selects & (data_selects-14'd1))!=0)$fatal(1,"BQ read-region selectors not onehot0");
   if(bdr!==bdr_priority_reference)$fatal(1,"BQ parallel read merge differs from original priority semantics");
 end
`endif
 wire commit=bv && br && bw && !be;
 uart_tx #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) uart(.clk(clk),.rst_n(rst_n),
   .start(commit && uart_data),.data(bdw[7:0]),.tx(uart_tx_pin),.busy(busy));
 always @(posedge clk) begin
   if(!rst_n) begin
     gpio<=0;status<=0;timer<=0;timer_compare<=64'hffffffffffffffff;msip<=0;
     rx_wptr<=0;rx_rptr<=0;rx_count<=0;rx_overrun<=0;rx_framing<=0;uart_irq_enable<=0;
   end
   else begin
     timer<=timer+1;
     if(commit && cmp_lo)timer_compare[31:0]<=bdw;
     if(commit && cmp_hi)timer_compare[63:32]<=bdw;
     if(commit && msip_sel)msip<=bdw[0];
     if(commit && uart_irq_sel)uart_irq_enable<=bdw[2:0];
     if(commit && rx_status_sel)begin
       if(bdw[1])rx_overrun<=0;if(bdw[2])rx_framing<=0;
     end
     if(rx_ready && !rx_push)rx_overrun<=1;
     if(rx_bad)rx_framing<=1;
     if(rx_push)begin rx_fifo[rx_wptr]<=rx_byte;rx_wptr<=rx_wptr+1'b1;end
     if(rx_pop)rx_rptr<=rx_rptr+1'b1;
     case({rx_push,rx_pop})
       2'b10:rx_count<=rx_count+1'b1;
       2'b01:rx_count<=rx_count-1'b1;
     endcase
     if(commit && gpio_sel) gpio<=bdw[3:0];
     if(commit && status_sel) status<=bdw;
   end
 end
endmodule
