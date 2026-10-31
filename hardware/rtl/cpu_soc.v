`timescale 1ns/1ps
module cpu_soc #(parameter integer CLOCK_HZ=27000000, BAUD=115200,
 parameter ICACHE_ENABLE=1, ICACHE_SET_BITS=7, ICACHE_DATA_BRAM=0, DCACHE_ENABLE=1, MACHINE_ENABLE=1, BURST_ENABLE=1, M_ENABLE=1, FENCEI_ENABLE=1)(
 input wire clk,rst_n,uart_rx_pin,output wire uart_tx_pin,output reg [3:0] gpio,
 output reg [31:0] status,output wire halted,output wire [31:0] trap_cause,
 output wire [159:0] debug_data,output wire [3:0] debug_trigger,
 output wire ext_valid,ext_write,output wire[11:0]ext_addr,output wire[31:0]ext_wdata,output wire[3:0]ext_wstrb,
 input wire ext_ready,ext_error,input wire[31:0]ext_rdata,input wire ext_irq);
 wire iv,ir,ie,dv,dw,dr,de,ipair;wire [31:0] id1,ipa;
 wire [31:0] ia,id,da,wd,rd;
 wire [3:0] ws;
 wire retire_valid,if_stage_valid,ex_stage_valid,wb_stage_valid;
 wire pipeline_stall,pipeline_flush,instruction_fence;
 wire [31:0] retire_pc,retire_insn,retire_data,retire_next_pc;
 wire [4:0] retire_rd;
 wire [63:0] cycle_count,instret_count,stall_count,flush_count,forward_count;
 wire uart_irq,timer_irq,software_irq;
 rv32_core #(.TARGET_PAIR_FETCH(1),.PAIR_FETCH(1),.MACHINE_ENABLE(MACHINE_ENABLE),.M_ENABLE(M_ENABLE),.FENCEI_ENABLE(FENCEI_ENABLE)) core(.clk(clk),.rst_n(rst_n),.irq_external(uart_irq|ext_irq),.irq_timer(timer_irq),.irq_software(software_irq),.i_valid(iv),.i_addr(ia),.i_ready(ir),.i_rdata(id),.i_pair_addr(ipa),.i_pair_valid(ipair),.i_rdata1(id1),.i_error(ie),
   .d_valid(dv),.d_write(dw),.d_addr(da),.d_wdata(wd),.d_wstrb(ws),.d_ready(dr),.d_rdata(rd),.d_error(de),
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
 wire ib_cmd,ib_ack,ib_valid,ib_last,ib_ready;
 wire [31:0] ib_addr,ib_data;
 wire db_cmd,db_ack,db_valid,db_last,db_ready;
 wire [31:0] db_addr,db_data;
 wire rb_ack,rb_valid,rb_last,mb_ack,mb_valid,mb_last;
 wire [31:0] rb_data,mb_data;
 wire db_rom=db_addr[31:16]==0;
 assign db_ack=db_rom ? rb_ack : mb_ack;
 assign db_valid=db_rom ? rb_valid : mb_valid;
 assign db_last=db_rom ? rb_last : mb_last;
 assign db_data=db_rom ? rb_data : mb_data;
 wire bv,bw,br,be;wire [31:0] ba,bdw,bdr;wire [3:0] bs;
 wire [31:0] dcache_hits,dcache_misses;
 generate if(DCACHE_ENABLE)begin: cached_data
   rv32_dcache #(.BURST_ENABLE(BURST_ENABLE)) cache(.b_cmd_valid(db_cmd),.b_addr(db_addr),.b_cmd_ready(db_ack),
     .b_valid(db_valid),.b_last(db_last),.b_ready(db_ready),.b_data(db_data),.b_error(1'b0),.clk(clk),.rst_n(rst_n),.c_valid(dv),.c_write(dw),
     .c_cacheable(da[31:16]==0 || da[31:16]==1),.c_addr(da),.c_wdata(wd),.c_wstrb(ws),
     .c_ready(dr),.c_rdata(rd),.c_error(de),.m_valid(bv),.m_write(bw),.m_addr(ba),
     .m_wdata(bdw),.m_wstrb(bs),.m_ready(br),.m_error(be),.m_rdata(bdr),
     .hit_count(dcache_hits),.miss_count(dcache_misses));
 end else begin: uncached_data
   assign db_cmd=0;assign db_addr=0;assign db_ready=0;
   assign bv=dv;assign bw=dw;assign ba=da;assign bdw=wd;assign bs=ws;
   assign dr=br;assign de=be;assign rd=bdr;assign dcache_hits=0;assign dcache_misses=0;
 end endgenerate
 wire ext_sel=ba[31:12]==20'h10010;
 assign ext_valid=bv&&ext_sel;assign ext_write=bw;assign ext_addr=ba[11:0];
 assign ext_wdata=bdw;assign ext_wstrb=bs;
 wire rom_sel=ba[31:16]==0, ram_sel=ba[31:16]==1;
 wire [31:0] rom_data,ram_data;
 wire rom_ready,ram_ready;
 wire [31:0] icache_hits,icache_misses;
 wire imv,imr;
 wire [31:0] ima,imd;
 wire i_rom_sel=ima[31:16]!=1,ib_rom_sel=ib_addr[31:16]!=1;
 wire irom_ready,iram_ready,ibr_ack,ibr_valid,ibr_last,ibm_ack,ibm_valid,ibm_last;
 wire [31:0] irom_data,iram_data,ibr_data,ibm_data;
 assign imr=i_rom_sel ? irom_ready : iram_ready;
 assign imd=i_rom_sel ? irom_data : iram_data;
 assign ib_ack=ib_rom_sel ? ibr_ack : ibm_ack;
 assign ib_valid=ib_rom_sel ? ibr_valid : ibm_valid;
 assign ib_last=ib_rom_sel ? ibr_last : ibm_last;
 assign ib_data=ib_rom_sel ? ibr_data : ibm_data;
 // One dual-port ROM image serves instruction and data reads (was two copies).
 boot_rom_dp rom(.clk(clk),.rst_n(rst_n),
   .i_valid(imv && i_rom_sel),.i_addr(ima[15:2]),.i_ready(irom_ready),.i_rdata(irom_data),
   .ib_cmd_valid(ib_cmd && ib_rom_sel),.ib_addr(ib_addr[15:2]),.ib_cmd_ready(ibr_ack),
   .ib_valid(ibr_valid),.ib_last(ibr_last),.ib_ready(ib_ready && ib_rom_sel),.ib_data(ibr_data),
   .d_valid(bv && rom_sel),.d_addr(ba[15:2]),.d_ready(rom_ready),.d_rdata(rom_data),
   .db_cmd_valid(db_cmd && db_rom),.db_addr(db_addr[15:2]),.db_cmd_ready(rb_ack),
   .db_valid(rb_valid),.db_last(rb_last),.db_ready(db_ready && db_rom),.db_data(rb_data));
 generate if(ICACHE_ENABLE) begin: cached_fetch
   rv32_icache #(.TARGET_PAIR_FETCH(1),.BURST_ENABLE(BURST_ENABLE),.SET_BITS(ICACHE_SET_BITS),.DATA_BRAM(ICACHE_DATA_BRAM)) cache(.invalidate(instruction_fence),.b_cmd_valid(ib_cmd),.b_addr(ib_addr),.b_cmd_ready(ib_ack),
     .b_valid(ib_valid),.b_last(ib_last),.b_ready(ib_ready),.b_data(ib_data),.b_error(ib_addr[31:16]>1),.clk(clk),.rst_n(rst_n),.c_valid(iv),.c_addr(ia),
     .c_pair_addr(ipa),.c_pair_valid(ipair),.c_rdata1(id1),.c_ready(ir),.c_rdata(id),.c_error(ie),.m_valid(imv),.m_addr(ima),
     .m_ready(imr),.m_rdata(imd),.m_error(ima[31:16]>1),
     .hit_count(icache_hits),.miss_count(icache_misses));
 end else begin: uncached_fetch
   assign ib_cmd=0;assign ib_addr=0;assign ib_ready=0;
   assign ipair=0;assign id1=0;
   assign imv=iv;assign ima=ia;assign ir=imr;assign id=imd;
   assign ie=ia[31:16]>1;assign icache_hits=0;assign icache_misses=0;
 end endgenerate
 sync_ram ram(.i_valid(imv && !i_rom_sel),.i_addr(ima[15:2]),.i_ready(iram_ready),.i_rdata(iram_data),
   .ib_cmd_valid(ib_cmd && !ib_rom_sel),.ib_addr(ib_addr[15:2]),.ib_cmd_ready(ibm_ack),
   .ib_valid(ibm_valid),.ib_last(ibm_last),.ib_ready(ib_ready && !ib_rom_sel),.ib_data(ibm_data),.b_cmd_valid(db_cmd && !db_rom),.b_addr(db_addr[15:2]),.b_cmd_ready(mb_ack),
   .b_valid(mb_valid),.b_last(mb_last),.b_ready(db_ready && !db_rom),.b_data(mb_data),.clk(clk),.rst_n(rst_n),.valid(bv && ram_sel),.write(bw),.word_addr(ba[15:2]),
   .wdata(bdw),.wstrb(bs),.ready(ram_ready),.rdata(ram_data));
 wire uart_data=ba==32'h10000100, uart_status=ba==32'h10000104;
 wire gpio_sel=ba==32'h10000200, status_sel=ba==32'h10000000;
 wire timer_lo=ba==32'h10000300, timer_hi=ba==32'h10000304;
 wire rx_data_sel=ba==32'h10000108,rx_status_sel=ba==32'h1000010c,uart_irq_sel=ba==32'h10000110;
 wire cmp_lo=ba==32'h10000308,cmp_hi=ba==32'h1000030c,msip_sel=ba==32'h10000310;
 wire mmio=uart_data || uart_status || gpio_sel || status_sel || timer_lo || timer_hi ||
   rx_data_sel || rx_status_sel || uart_irq_sel || cmp_lo || cmp_hi || msip_sel;
 wire busy;
 wire bad_write=bw && ((uart_data && bs!=4'b0001 && bs!=4'b1111) ||
   ((gpio_sel || status_sel) && bs!=4'b1111) || uart_status || timer_lo || timer_hi || rx_data_sel ||
   ((rx_status_sel || uart_irq_sel || cmp_lo || cmp_hi || msip_sel) && bs!=4'b1111));
 assign be=ext_sel ? ext_error : rom_sel ? bw : ram_sel ? 1'b0 : (!mmio || bad_write || (uart_data && !bw));
 assign br=rst_n && (ext_sel ? ext_ready : rom_sel ? rom_ready : ram_sel ? ram_ready :
   (be || !uart_data || !busy));
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
 assign bdr=ext_sel ? ext_rdata : rom_sel ? rom_data : ram_sel ? ram_data : uart_status ? {31'b0,busy} :
   gpio_sel ? {28'b0,gpio} : status_sel ? status : timer_lo ? timer[31:0] : timer_hi ? timer[63:32] :
   rx_data_sel ? (rx_count!=0 ? {24'b0,rx_fifo[rx_rptr]} : 32'b0) :
   rx_status_sel ? {24'b0,rx_count,2'b0,rx_framing,rx_overrun,(rx_count!=0)} :
   uart_irq_sel ? {29'b0,uart_irq_enable} : cmp_lo ? timer_compare[31:0] :
   cmp_hi ? timer_compare[63:32] : msip_sel ? {31'b0,msip} : 32'b0;
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
