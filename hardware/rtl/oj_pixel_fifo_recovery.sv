// Single-producer/single-consumer Gray-pointer asynchronous FIFO.
// Coordinated reset only; no per-frame pointer reset. RAM read is synchronous.
module oj_pixel_fifo_recovery #(parameter AW=12)(
 input wire wclk,wrst,wen,input wire[23:0]wdata,output wire full,
 input wire rclk,rrst,output reg valid,input wire ready,output reg[23:0]rdata,output wire empty);
 reg[23:0]mem[0:(1<<AW)-1];
 reg[AW:0]wb,wg,rb,rg;
 (* async_reg="true" *) reg[AW:0]rs1,rs2,ws1,ws2;
 wire[AW:0]wbn=wb+1'b1;
 wire[AW:0]rbn=rb+1'b1;
 assign full=wg=={~rs2[AW:AW-1],rs2[AW-2:0]};
 assign empty=(rg==ws2)&&!valid;
 always @(posedge wclk or posedge wrst)begin
  if(wrst)begin wb<=0;wg<=0;rs1<=0;rs2<=0;end
  else begin
   rs1<=rg;rs2<=rs1;
   if(wen&&!full)begin mem[wb[AW-1:0]]<=wdata;wb<=wbn;wg<=(wbn>>1)^wbn;end
  end
 end
 always @(posedge rclk or posedge rrst)begin
  if(rrst)begin rb<=0;rg<=0;ws1<=0;ws2<=0;valid<=0;rdata<=0;end
  else begin
   ws1<=wg;ws2<=ws1;
   if(!valid||ready)begin
    if(rg!=ws2)begin rdata<=mem[rb[AW-1:0]];rb<=rbn;rg<=(rbn>>1)^rbn;valid<=1;end
    else valid<=0;
   end
  end
 end
endmodule
