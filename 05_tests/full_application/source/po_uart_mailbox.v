// Single immutable load-time message. Bundled data stays stable from request
// until acknowledged consumption; only request/ack toggles cross synchronizers.
// Physical CDC/max-delay constraints are required before board acceptance.
// Common reset asserts asynchronously and releases synchronously at both ends.
module po_uart_mailbox #(parameter WIDTH=32)(
 input wire arst,wclk,w_valid,output wire w_ready,input wire[WIDTH-1:0]w_data,
 input wire rclk,output reg r_valid,input wire r_ready,output reg[WIDTH-1:0]r_data
);
 reg[WIDTH-1:0]payload;reg request,ack;
 (* ASYNC_REG="TRUE" *)reg[1:0]rq_sync,ack_sync,wrst,rrst;
 assign w_ready=!wrst[1]&&(request==ack_sync[1]);
 // Common asynchronous assertion; each local state releases on its own clock.
 always @(posedge wclk or posedge arst)if(arst)wrst<=3;else wrst<={wrst[0],1'b0};
 always @(posedge rclk or posedge arst)if(arst)rrst<=3;else rrst<={rrst[0],1'b0};
 always @(posedge wclk or posedge wrst[1])begin
  if(wrst[1])begin request<=0;ack_sync<=0;end
  else begin
   ack_sync<={ack_sync[0],ack};
   if(w_valid&&w_ready)request<=!request;
  end
 end
 always @(posedge wclk)if(w_valid&&w_ready)payload<=w_data;
 always @(posedge rclk or posedge rrst[1])begin
  if(rrst[1])begin ack<=0;rq_sync<=0;r_valid<=0;end
  else begin
   rq_sync<={rq_sync[0],request};
   if(!rrst[1])begin
    if(r_valid&&r_ready)begin r_valid<=0;ack<=rq_sync[1];end
    else if(!r_valid&&(rq_sync[1]!=ack))r_valid<=1;
   end
  end
 end
 always @(posedge rclk)if(!rrst[1]&&!r_valid&&(rq_sync[1]!=ack))r_data<=payload;
endmodule
