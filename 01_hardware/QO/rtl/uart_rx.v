`timescale 1ns/1ps
// 8N1 receiver with two-flop input synchronization and center sampling.
// ready/error are one-clock pulses. The SoC owns buffering and sticky flags.
module uart_rx #(parameter integer CLOCK_HZ=27000000,BAUD=115200)(
 input wire clk,rst_n,rx,output reg [7:0] data,output reg ready,frame_error);
 localparam integer DIV=(CLOCK_HZ+BAUD/2)/BAUD;
 localparam integer WIDTH=$clog2(DIV+1);
 reg rx_meta,rx_sync;
 reg [WIDTH-1:0] ticks;
 reg [1:0] state;
 reg [2:0] bit_index;
 reg [7:0] shift;
 always @(posedge clk)begin
   if(!rst_n)begin
     rx_meta<=1;rx_sync<=1;ticks<=0;state<=0;bit_index<=0;shift<=0;
     data<=0;ready<=0;frame_error<=0;
   end else begin
     rx_meta<=rx;rx_sync<=rx_meta;ready<=0;frame_error<=0;
     case(state)
       0:if(!rx_sync)begin state<=1;ticks<=DIV/2-1;end
       1:if(ticks!=0)ticks<=ticks-1;
         else if(rx_sync)state<=0; // reject a short start glitch
         else begin state<=2;ticks<=DIV-1;bit_index<=0;end
       2:if(ticks!=0)ticks<=ticks-1;
         else begin
           shift[bit_index]<=rx_sync;ticks<=DIV-1;
           if(bit_index==7)state<=3;else bit_index<=bit_index+1;
         end
       3:if(ticks!=0)ticks<=ticks-1;
         else begin
           if(rx_sync)begin data<=shift;ready<=1;end else frame_error<=1;
           state<=0;
         end
     endcase
   end
 end
endmodule
