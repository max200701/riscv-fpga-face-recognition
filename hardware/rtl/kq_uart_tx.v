`timescale 1ns/1ps
// 8N1, no FIFO. Accept one byte on start && !busy.
module kq_uart_tx #(parameter integer CLOCK_HZ=27000000, BAUD=115200)(
 input wire clk, rst_n, start, input wire [7:0] data,
 output wire tx, output reg busy);
 localparam integer DIV=(CLOCK_HZ+BAUD/2)/BAUD;
 reg [31:0] ticks;
 reg [3:0] bit_index;
 reg [9:0] frame;
 assign tx=busy ? frame[0] : 1'b1;
 always @(posedge clk) begin
   if(!rst_n) begin busy<=0; ticks<=0; bit_index<=0; frame<=10'h3ff; end
   else if(!busy) begin
     if(start) begin frame<={1'b1,data,1'b0}; busy<=1; ticks<=DIV-1; bit_index<=0; end
   end else if(ticks!=0) ticks<=ticks-1;
   else if(bit_index==9) busy<=0;
   else begin frame<={1'b1,frame[9:1]}; bit_index<=bit_index+1; ticks<=DIV-1; end
 end
endmodule
