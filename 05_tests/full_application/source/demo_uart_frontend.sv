// Uses the already board-tested 8N1 RX/TX primitives. One byte of RX elasticity;
// the stop-and-wait FBD1 host must not stream a new packet while a reply is due.
module demo_uart_frontend #(
 parameter integer CLOCK_HZ=133250000,BAUD=921600
)(input wire clk,rst,input wire uart_rx_pin,output wire uart_tx_pin,
 output wire rx_valid,input wire rx_ready,output wire[7:0]rx_data,
 input wire tx_valid,output wire tx_ready,input wire[7:0]tx_data,
 output reg frame_fault,overflow_fault);
 wire received,frame_error,busy;wire[7:0]received_data;
 reg have;reg[7:0]held;
 reg tx_pending;reg[7:0]tx_held;
 always @(posedge clk)begin
  if(rst)tx_pending<=0;
  else begin
   if(tx_pending&&!busy)tx_pending<=0;
   if(tx_valid&&tx_ready)begin tx_held<=tx_data;tx_pending<=1;end
  end
 end
 kq_uart_rx #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) rx(
  .clk(clk),.rst_n(!rst),.rx(uart_rx_pin),.data(received_data),.ready(received),.frame_error(frame_error));
 kq_uart_tx #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) tx(
  .clk(clk),.rst_n(!rst),.start(tx_pending&&!busy&&!rst),.data(tx_held),.tx(uart_tx_pin),.busy(busy));
 assign tx_ready=!rst&&!tx_pending;
 assign rx_valid=!rst&&have;
 assign rx_data=held;
 always @(posedge clk)begin
  if(rst)begin have<=0;held<=0;frame_fault<=0;overflow_fault<=0;end
  else begin
   if(rx_valid&&rx_ready)have<=0;
   if(frame_error)frame_fault<=1;
   if(received)begin
    if(have&&!rx_ready)overflow_fault<=1;
    else begin held<=received_data;have<=1;end
   end
  end
 end
endmodule
