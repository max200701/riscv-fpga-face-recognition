// Candidate: PFD12.5MHz, VCO975MHz, CPU162.5MHz. Native tool clock and simulation must confirm.
module cpu_perf_pll(input wire ref_clk,rst,output wire clk_out,locked);
 GTP_GPLL #(.CLKIN_FREQ(125.0),.STATIC_RATIOI(10),.STATIC_RATIOM(13),
  .STATIC_RATIOF(6.0),.STATIC_RATIO0(6.0),.STATIC_DUTYF(6),.STATIC_DUTY0(6),
  .INTERNAL_FB("CLKOUTF"),.EXTERNAL_FB("DISABLE")) pll(
  .CLKIN1(ref_clk),.CLKIN2(1'b0),.CLKIN_SEL(1'b0),.CLKFB(1'b0),
  .CLKOUT0(clk_out),.LOCK(locked),.RST(rst),.PLL_PWD(1'b0),
  .DPS_CLK(1'b0),.DPS_EN(1'b0),.DPS_DIR(1'b0),
  .CLKOUT0_SYN(1'b0),.CLKOUT1_SYN(1'b0),.CLKOUT2_SYN(1'b0),.CLKOUT3_SYN(1'b0),
  .CLKOUT4_SYN(1'b0),.CLKOUT5_SYN(1'b0),.CLKOUT6_SYN(1'b0),.CLKOUTF_SYN(1'b0),
  .APB_CLK(1'b0),.APB_RST_N(1'b1),.APB_ADDR(5'b0),.APB_SEL(1'b0),
  .APB_EN(1'b0),.APB_WRITE(1'b0),.APB_WDATA(16'b0));
endmodule
