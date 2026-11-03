`timescale 1ns/1ps
module cpu_perf_board #(parameter BAUD=115200)(input ref_clk_p,ref_clk_n,uart_rx,output uart_tx);
 wire ref_clk,pll_clk,clk,locked;
 GTP_INBUFDS ref_clk_buf(.I(ref_clk_p),.IB(ref_clk_n),.O(ref_clk));
 reg[7:0] power_count=0;
 always @(posedge ref_clk)if(!(&power_count))power_count<=power_count+1'b1;
 cpu_perf_pll clock_gen(.ref_clk(ref_clk),.rst(!(&power_count)),.clk_out(pll_clk),.locked(locked));
 GTP_CLKBUFG cpu_clk_buf(.CLKIN(pll_clk),.CLKOUT(clk));
 // Async assertion on loss of lock; synchronous three-edge release.
 reg[2:0] reset_release=0 /* synthesis syn_preserve=1 */;
 always @(posedge clk or negedge locked)
   if(!locked)reset_release<=0;else reset_release<={reset_release[1:0],1'b1};
 reg[15:0] start_count=0;reg rst_n=0;
 always @(posedge clk)begin
   if(!reset_release[2])begin start_count<=0;rst_n<=0;end
   else begin if(!(&start_count))start_count<=start_count+1'b1;rst_n<=&start_count;end
 end
 cpu_soc #(.CLOCK_HZ(162500000),.BAUD(BAUD),.ICACHE_DATA_BRAM(1)) dut(
 .clk(clk),.rst_n(rst_n),.uart_rx_pin(uart_rx),.uart_tx_pin(uart_tx),
 .ext_ready(1'b1),.ext_error(1'b1),.ext_rdata(32'b0),.ext_irq(1'b0));
endmodule
