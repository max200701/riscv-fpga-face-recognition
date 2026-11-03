`timescale 1ns/1ps
// Board-specific hard primitive. UG040009 V1.6 pages 19-24 (printed).
// DCLK=27MHz. ADC_A temperature ONLY, ADC_B off, internal reference,
// 64-sample averaging, offset/gain calibration, ad_clk=DCLK/32.
// This is an estimate: the guide's accuracy condition requires an external
// precision reference, which is not established for this physical MINI.
module logos2_temperature_adc(
  input wire clk, rst_n, loadsc_n, den, secen, input wire [7:0] daddr,
  output wire [15:0] data, output wire drdy, done_a, dmodified, over_temp
);
  GTP_ADC_E2 #(
    .CREG_00H(16'hB303), .CREG_01H(16'hD21E), .CREG_02H(16'h0008),
    .CREG_31H(14'h0000),
    .CREG_03H(16'h0004), .CREG_04H(16'h0000), .CREG_0AH(16'h0000),
    .CREG_05H(16'h0000), .CREG_06H(16'h0000), .CREG_0CH(16'h0000),
    .CREG_07H(16'h0004), .CREG_08H(16'h0000), .CREG_0EH(16'h0000),
    .CREG_20H(12'hB52), .CREG_21H(12'hB00), // approx 80/70C alarm hysteresis
    .CREG_22H(12'h000), .CREG_23H(12'h000),
    .CREG_24H(12'h000), .CREG_25H(12'h000),
    .CREG_26H(12'h000), .CREG_27H(12'h000),
    .CREG_28H(12'h000), .CREG_29H(12'h000),
    .CREG_2AH(12'hCC2), .CREG_2BH(12'hA5B) // vendor OT defaults; NOT safe limits
  ) sensor (
    .VA(2'b00), .VAUX(32'b0), .DCLK(clk), .DADDR(daddr),
    .DEN(den), .SECEN(secen), .DWE(1'b0), .DI(16'b0), .DO(data), .DRDY(drdy),
    .CONVST(1'b0), .RST_N(rst_n), .LOADSC_N(loadsc_n),
    .OVER_TEMP(over_temp), .LOGIC_DONE_A(done_a), .LOGIC_DONE_B(),
    .ADC_CLK_OUT(), .DMODIFIED(dmodified), .ALARM()
  );
endmodule
