// Stable multi-bit mailbox; source holds its bundle until returned ACK.
// Both ends require the same coordinated cold reset, never a one-end warm reset.
module demo_reset_sync(input wire clk,arst,output wire rst);
 (* ASYNC_REG="TRUE" *)reg[2:0]q;
 always @(posedge clk or posedge arst)if(arst)q<=3'b111;else q<={q[1:0],1'b0};
 assign rst=q[2];
endmodule
module demo_status_cdc #(parameter integer W=32)(
 input wire s_clk,d_clk,arst,input wire[W-1:0]s_data,
 output reg[W-1:0]d_data,output reg d_valid);
 wire sr,dr;demo_reset_sync rs(s_clk,arst,sr);demo_reset_sync rd(d_clk,arst,dr);
 reg[W-1:0]hold;reg req,ack;
 (* ASYNC_REG="TRUE" *)reg[1:0]a,r;
 always @(posedge s_clk)begin
  if(sr)begin a<=0;req<=0;hold<=0;end
  else begin a<={a[0],ack};if(a[1]==req)begin hold<=s_data;req<=!req;end end
 end
 always @(posedge d_clk)begin
  if(dr)begin r<=0;ack<=0;d_data<=0;d_valid<=0;end
  else begin r<={r[0],req};if(r[1]!=ack)begin d_data<=hold;d_valid<=1;ack<=r[1];end end
 end
endmodule
