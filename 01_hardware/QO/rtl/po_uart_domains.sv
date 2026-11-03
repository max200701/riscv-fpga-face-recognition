// Byte-rate management island; packet ownership and the physical writer stay UI.
// Two one-message mailboxes, no block RAM. The existing front end retains the
// stop-and-wait protocol and sticky UART errors. Reset flushes both endpoints.
module po_uart_domains #(parameter CLOCK_HZ=27000000,BAUD=921600)(
 input wire clk,mgmt_clk,rst,uart_rx_pin,output wire uart_tx_pin,
 output wire rx_valid,input wire rx_ready,output wire[7:0]rx_data,
 input wire tx_valid,output wire tx_ready,input wire[7:0]tx_data,
 output wire frame_fault,overflow_fault);
 wire mrst;demo_reset_sync management_reset(.clk(mgmt_clk),.arst(rst),.rst(mrst));
 wire rv,rr,tv,tr,ff,of;wire[7:0]rd,td;
 demo_uart_frontend #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) serial(
  .clk(mgmt_clk),.rst(mrst),.uart_rx_pin(uart_rx_pin),.uart_tx_pin(uart_tx_pin),
  .rx_valid(rv),.rx_ready(rr),.rx_data(rd),.tx_valid(tv),.tx_ready(tr),.tx_data(td),
  .frame_fault(ff),.overflow_fault(of));
 po_uart_mailbox #(.WIDTH(8)) receive_bytes(rst,mgmt_clk,rv,rr,rd,clk,rx_valid,rx_ready,rx_data);
 po_uart_mailbox #(.WIDTH(8)) transmit_bytes(rst,clk,tx_valid,tx_ready,tx_data,mgmt_clk,tv,tr,td);
 (* ASYNC_REG="TRUE" *)reg[1:0]fs,os;
 always @(posedge clk or posedge rst)begin
  if(rst)begin fs<=0;os<=0;end else begin fs<={fs[0],ff};os<={os[0],of};end
 end
 assign frame_fault=fs[1];assign overflow_fault=os[1];
endmodule
