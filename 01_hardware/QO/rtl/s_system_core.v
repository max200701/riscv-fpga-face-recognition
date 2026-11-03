// Synchronous logic integration boundary, not a physical MINI board wrapper.
// Clocks come from the testbench here; verified PLL/DDR PHY and video ingress
// are still required before a board implementation can be accepted.
module s_system_core #(parameter NATIVE=1,DCACHE=1,CLOCK_HZ=48000000,BAUD=115200)(
 input wire arst,cpu_clk,npu_clk,ddr_clk,ddr_init_done,uart_rx,
 output wire uart_tx,output wire[3:0]gpio,output wire[31:0]status,
 output wire halted,output wire[31:0]trap,
 output wire axi_arvalid,input wire axi_arready,output wire[27:0]axi_araddr,
 output wire[3:0]axi_arlen,axi_aruser_id,output wire axi_aruser_ap,
 input wire axi_rvalid,input wire[255:0]axi_rdata,input wire axi_rlast,input wire[3:0]axi_rid,
 output wire axi_awvalid,input wire axi_awready,output wire[27:0]axi_awaddr,
 output wire[3:0]axi_awlen,axi_awuser_id,output wire axi_awuser_ap,
 output wire[255:0]axi_wdata,output wire[31:0]axi_wstrb,
 input wire axi_wready,input wire[3:0]axi_wusero_id,input wire axi_wusero_last
);
 wire bv,bw,br,be,irq;wire[11:0]ba;wire[31:0]bd,bdw;wire[3:0]bs;
 cpu_soc #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD),.DCACHE_ENABLE(DCACHE)) cpu(
  .clk(cpu_clk),.rst_n(!arst),.uart_rx_pin(uart_rx),.uart_tx_pin(uart_tx),.gpio(gpio),.status(status),
  .halted(halted),.trap_cause(trap),.debug_data(),.debug_trigger(),
  .ext_valid(bv),.ext_write(bw),.ext_addr(ba),.ext_wdata(bdw),.ext_wstrb(bs),
  .ext_ready(br),.ext_error(be),.ext_rdata(bd),.ext_irq(irq));
 cpu_npu_queue #(.NATIVE(NATIVE),.WATCHDOG(2000000)) bridge(
  arst,cpu_clk,npu_clk,ddr_clk,ddr_init_done,bv,bw,ba,bdw,bs,br,be,bd,irq,
  axi_arvalid,axi_arready,axi_araddr,axi_arlen,axi_aruser_id,axi_aruser_ap,
  axi_rvalid,axi_rdata,axi_rlast,axi_rid,
  axi_awvalid,axi_awready,axi_awaddr,axi_awlen,axi_awuser_id,axi_awuser_ap,
  axi_wdata,axi_wstrb,axi_wready,axi_wusero_id,axi_wusero_last);
endmodule
