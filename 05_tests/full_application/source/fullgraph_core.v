// RTL simulation wrapper; unchanged production CPU and accelerator hierarchy.
module fullgraph_core #(parameter FAST_CONTROL=1, NATIVE=1, DMA_FETCH=1, LOCAL_APPLICATION_HOLD=0)(
 input wire uart_rx,output wire uart_tx,output wire[3:0]gpio,
 input wire application_cold_rst,application_hold_next,
 input wire arst,cpu_clk,npu_clk,ddr_clk,ddr_init_done,
 input wire[1:0] application_mode,input wire[31:0] benchmark_iterations,
 input wire resident_model_verified,resident_gallery_verified,
 output wire axi_arvalid,input wire axi_arready,output wire[27:0]axi_araddr,
 output wire[3:0]axi_arlen,axi_aruser_id,output wire axi_aruser_ap,
 input wire axi_rvalid,input wire[255:0]axi_rdata,input wire axi_rlast,input wire[3:0]axi_rid,
 output wire axi_awvalid,input wire axi_awready,output wire[27:0]axi_awaddr,
 output wire[3:0]axi_awlen,axi_awuser_id,output wire axi_awuser_ap,
 output wire[255:0]axi_wdata,output wire[31:0]axi_wstrb,
 input wire axi_wready,input wire[3:0]axi_wusero_id,input wire axi_wusero_last,
 output wire fault,output wire[63:0]npu_macs,vector_elements,
 output wire finished,output wire[31:0]cpu_status,cpu_pc,cpu_phase,
 output reg[31:0]command_index,mark_kind,mark_a,mark_b,mark_c,output reg mark_toggle,output reg[63:0]cpu_cycles

);

// Preserve a common asynchronous assertion, but release CPU-local reset
// on the CPU clock. UI ownership must not feed the CPU ALU combinationally.
// Same-cycle local roots: source ownership state and destination reset release are unchanged.
 wire[5:0] local_arst;
 genvar hr;
 generate for(hr=0;hr<6;hr=hr+1)begin:hold_roots
  if(LOCAL_APPLICATION_HOLD)begin:local_root
   demo_hold_root root(.clk(ddr_clk),.cold_rst(application_cold_rst),.hold_next(application_hold_next),.reset(local_arst[hr]));
  end else begin:legacy_root
   assign local_arst[hr]=arst;
  end
 end endgenerate
wire cpu_arst;
cpu_reset_release cpu_reset_domain(.clk(cpu_clk),.arst(local_arst[0]),.reset(cpu_arst));
wire bv,bw,br,be,abr,abe,irq;wire[11:0]ba;wire[31:0]bdw,bd,abd;wire[3:0]bs;
 wire cbv,cbw,cbr,cbe,sr,se,sa,si,mv,mw;wire[11:0]cba,ma;wire[31:0]cbwd,cbrd,sdata,md;wire[3:0]cbs;
 wire sbv,sbw,sbr,sbe;wire[11:0]sba;wire[31:0]sbwd,sbrd;wire[3:0]sbs;
 wire xv,xw,xr,xe,axr,axe;wire[11:0]xa;wire[31:0]xd,xrd,axrd;wire[3:0]xs;   // c19/c20: registered side of bus_slice
 wire control_clk=FAST_CONTROL?npu_clk:cpu_clk;
 wire mailbox_arst; graph_reset_leaf mailbox_reset_leaf(.clk(control_clk),.arst(local_arst[1]),.reset(mailbox_arst));
 wire sequencer_arst; graph_reset_leaf sequencer_reset_leaf(.clk(control_clk),.arst(local_arst[2]),.reset(sequencer_arst));
 wire program_arst; graph_reset_leaf program_reset_leaf(.clk(control_clk),.arst(local_arst[3]),.reset(program_arst));
 wire bus_arst; graph_reset_leaf bus_reset_leaf(.clk(control_clk),.arst(local_arst[4]),.reset(bus_arst));
 wire marker_arst; graph_reset_leaf marker_reset_leaf(.clk(control_clk),.arst(local_arst[5]),.reset(marker_arst));

 wire dqv,dqr,drv,drp;wire[31:0]dqd;wire[255:0]dqa;wire[127:0]drd;   // c22: sequencer <-> NPU queue direct port
 wire six;wire[31:0]sixv;   // c25: sequencer command_index side channel
 generate if(FAST_CONTROL)begin:fast_control
 graph_mmio_cdc cpu_transactions(.arst(mailbox_arst),.cpu_clk(cpu_clk),.fast_clk(npu_clk),.valid(sbv),.write(sbw),.addr(sba),.wdata(sbwd),.wstrb(sbs),.ready(sbr),.error(sbe),.rdata(sbrd),
 .mvalid(cbv),.mwrite(cbw),.maddr(cba),.mwdata(cbwd),.mwstrb(cbs),.mready(cbr),.merror(cbe),.mrdata(cbrd));
 end else begin:direct_control
 assign cbv=sbv;assign cbw=sbw;assign cba=sba;assign cbwd=sbwd;assign cbs=sbs;assign sbr=cbr;assign sbe=cbe;assign sbrd=cbrd;
 end endgenerate
 (* ASYNC_REG="TRUE" *)reg[1:0]irq_sync;
 always @(posedge cpu_clk or posedge cpu_arst)if(cpu_arst)irq_sync<=0;else irq_sync<={irq_sync[0],irq|si};
 wire control=cba[11:8]==4'h3;
 assign bv=sa?mv:(cbv&&!control);assign bw=sa?mw:cbw;assign ba=sa?ma:cba;assign bdw=sa?md:cbwd;assign bs=sa?4'hf:cbs;
 assign cbr=control?sr:(sa?1'b1:br);assign cbe=control?se:(sa?1'b1:be);assign cbrd=control?sdata:bd;
 wire fetch_valid,fetch_ready,fetched_valid,fetched_ready;wire[31:0]fetch_address;wire[511:0]fetched_data;wire[7:0]fetched_error;
 wire program_rdv,program_rdr,program_rv,program_rr,program_rl,program_re;wire[31:0]program_ra;wire[4:0]program_rn;wire[255:0]program_data;
 generate if(DMA_FETCH)begin:dma_fetch
 graph_mmio_dma_sequencer sequencer(.clk(control_clk),.rst(sequencer_arst),.valid(cbv&&control),.write(cbw),.addr(cba[7:0]),.wdata(cbwd),.wstrb(cbs),.ready(sr),.error(se),.rdata(sdata),.active(sa),.irq(si),
 .mvalid(mv),.mwrite(mw),.mready(br),.merror(be),.maddr(ma),.mwdata(md),.mrdata(bd),
 .fetch_valid(fetch_valid),.fetch_ready(fetch_ready),.fetch_address(fetch_address),.fetched_valid(fetched_valid),.fetched_ready(fetched_ready),.fetched_data(fetched_data),.fetched_error(fetched_error),
 .dq_valid(dqv),.dq_ready(dqr),.dq_door(dqd),.dq_args(dqa),.dr_valid(drv),.dr_pop(drp),.dr_data(drd),.index_set(six),.index_value(sixv));
 graph_program_cache programs(.clk(control_clk),.rst(program_arst),.cmd_valid(fetch_valid),.cmd_ready(fetch_ready),.cmd_address(fetch_address),
 .rsp_valid(fetched_valid),.rsp_ready(fetched_ready),.rsp_data(fetched_data),.rsp_error(fetched_error),
 .rd_valid(program_rdv),.rd_ready(program_rdr),.rd_address(program_ra),.rd_beats(program_rn),
 .r_valid(program_rv),.r_ready(program_rr),.r_data(program_data),.r_last(program_rl),.r_error(program_re),.fills(),.hits());
 end else begin:mmio_fetch
 assign program_rdv=0;assign program_ra=0;assign program_rn=0;assign program_rr=1;
 assign dqv=0;assign dqd=0;assign dqa=0;assign drp=0;assign six=0;assign sixv=0;
 graph_mmio_sequencer sequencer(.clk(control_clk),.rst(sequencer_arst),.valid(cbv&&control),.write(cbw),.addr(cba[7:0]),.wdata(cbwd),.wstrb(cbs),.ready(sr),.error(se),.rdata(sdata),.active(sa),.irq(si),
 .mvalid(mv),.mwrite(mw),.mready(br),.merror(be),.maddr(ma),.mwdata(md),.mrdata(bd));
 end endgenerate
 // diag (0x2xx) is decoded after the request slice (xdiag below).
 assign br=abr;assign be=abe;assign bd=abd;
 wire halted;wire[31:0]trap;wire[159:0]cpu_debug;
 cpu_soc #(.ICACHE_DATA_BRAM(1)) dut(.clk(cpu_clk),.rst_n(!cpu_arst),.uart_rx_pin(uart_rx),.uart_tx_pin(uart_tx),.gpio(gpio),.status(cpu_status),.halted(halted),.trap_cause(trap),.debug_data(cpu_debug),.debug_trigger(),
 .ext_valid(sbv),.ext_write(sbw),.ext_addr(sba),.ext_wdata(sbwd),.ext_wstrb(sbs),.ext_ready(sbr),.ext_error(sbe),.ext_rdata(sbrd),.ext_irq(irq_sync[1]));
 // registered MMIO request/response between the masters and the accelerator bus.
 mmio_req_slice bus_slice(.clk(control_clk),.rst(bus_arst),.s_tag(sa),.s_valid(bv),.s_write(bw),.s_addr(ba),.s_wdata(bdw),.s_wstrb(bs),
  .s_ready(abr),.s_error(abe),.s_rdata(abd),.m_valid(xv),.m_write(xw),.m_addr(xa),.m_wdata(xd),.m_wstrb(xs),.m_ready(xr),.m_error(xe),.m_rdata(xrd));
 wire xdiag=xa[11:8]==4'h2;
 // The deployed FAST_CONTROL=1 instance reads the retained UI-domain receipt
 // through the existing CPU MMIO CDC. No asynchronous CPU sampling is added.
 wire residency_read=!xw&&(xa==12'h218||xa==12'h21c||xa==12'h220||xa==12'h224);
 assign xr=xdiag?1'b1:axr;
 assign xe=xdiag?(residency_read?1'b0:(!xw||xs!=15)):axe;
 assign xrd=xdiag?(xa==12'h220 ? {30'b0,application_mode}:xa==12'h224 ? benchmark_iterations:xa==12'h218&&resident_model_verified?32'h50454d31:xa==12'h21c&&resident_gallery_verified?32'h50474c31:32'b0):axrd;
 fullgraph_accelerators #(.NATIVE(NATIVE),.PROGRAM_CACHE(DMA_FETCH),.SAME_CLOCK(FAST_CONTROL),.LOCAL_APPLICATION_HOLD(LOCAL_APPLICATION_HOLD)) acceleration(.application_cold_rst(application_cold_rst),.application_hold_next(application_hold_next),.arst(arst),.cpu_clk(control_clk),.npu_clk(npu_clk),.ddr_clk(ddr_clk),.ddr_init_done(ddr_init_done),
 .npu_dq_valid(dqv),.npu_dq_ready(dqr),.npu_dq_door(dqd),.npu_dq_args(dqa),.npu_dr_valid(drv),.npu_dr_pop(drp),.npu_dr_data(drd),
 .bus_valid(xv&&!xdiag),.bus_write(xw),.bus_addr(xa),.bus_wdata(xd),.bus_wstrb(xs),.bus_ready(axr),.bus_error(axe),.bus_rdata(axrd),.irq(irq),
 .program_owner(sa),.program_rd_valid(program_rdv),.program_rd_ready(program_rdr),.program_rd_address(program_ra),.program_rd_beats(program_rn),
 .program_r_valid(program_rv),.program_r_ready(program_rr),.program_r_data(program_data),.program_r_last(program_rl),.program_r_error(program_re),
 .fault(fault),.npu_macs(npu_macs),.vector_elements(vector_elements),
.axi_arvalid(axi_arvalid),
.axi_arready(axi_arready),
.axi_araddr(axi_araddr),
.axi_arlen(axi_arlen),
.axi_aruser_id(axi_aruser_id),
.axi_aruser_ap(axi_aruser_ap),
.axi_rvalid(axi_rvalid),
.axi_rdata(axi_rdata),
.axi_rlast(axi_rlast),
.axi_rid(axi_rid),
.axi_awvalid(axi_awvalid),
.axi_awready(axi_awready),
.axi_awaddr(axi_awaddr),
.axi_awlen(axi_awlen),
.axi_awuser_id(axi_awuser_id),
.axi_awuser_ap(axi_awuser_ap),
.axi_wdata(axi_wdata),
.axi_wstrb(axi_wstrb),
.axi_wready(axi_wready),
.axi_wusero_id(axi_wusero_id),
.axi_wusero_last(axi_wusero_last));

 reg[31:0]phase;assign cpu_phase=phase;assign cpu_pc=cpu_debug[31:0];
 assign finished=cpu_status!=0||halted;
 always @(posedge cpu_clk or posedge cpu_arst)begin
  if(cpu_arst)cpu_cycles<=0;else cpu_cycles<=cpu_cycles+1'b1;
 end
 always @(posedge control_clk or posedge marker_arst)begin
  if(marker_arst)begin mark_kind<=0;mark_a<=0;mark_b<=0;mark_c<=0;mark_toggle<=0;command_index<=0;phase<=0;end
  else if(six)command_index<=sixv;   // c25
  else if(xv&&xr&&!xe&&xw&&xdiag)case(xa)
    12'h200:command_index<=xd;
    12'h204:mark_a<=xd;
    12'h208:mark_b<=xd;
    12'h20c:mark_c<=xd;
    12'h210:begin mark_kind<=xd;mark_toggle<=!mark_toggle;end
    12'h214:phase<=xd;
   endcase
 end
endmodule

// Assertion never waits for a clock; deassertion requires two local edges.
// The original CPU and mailbox numerical/data protocols are unchanged.
module cpu_reset_release(input wire clk,arst,output wire reset);
 (* ASYNC_REG="TRUE" *) reg[1:0] stages /* synthesis syn_preserve=1 */;
 always @(posedge clk or posedge arst)
  if(arst)stages<=2'b11;else stages<={stages[0],1'b0};
 assign reset=stages[1];
endmodule
