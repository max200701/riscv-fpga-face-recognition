// One CPU MMIO transaction in flight. Immutable bundled-data mailboxes provide
// exactly one fast-domain request and one CPU-domain completion per transfer.
// Physical synchronizer and bundled-data constraints remain a separate gate.
module graph_mmio_cdc(
 input wire arst,cpu_clk,fast_clk,
 input wire valid,write,input wire[11:0]addr,input wire[31:0]wdata,input wire[3:0]wstrb,
 output wire ready,error,output wire[31:0]rdata,
 output wire mvalid,mwrite,output wire[11:0]maddr,output wire[31:0]mwdata,output wire[3:0]mwstrb,
 input wire mready,merror,input wire[31:0]mrdata
);
 wire cpu_arst;
 cpu_reset_release cpu_reset_domain(.clk(cpu_clk),.arst(arst),.reset(cpu_arst));
 reg inflight;wire qready,qvalid,qtake,sready,svalid;wire[48:0]qdata;wire[32:0]sdata;
 wire push=valid&&!inflight&&!cpu_arst;
 package_mailbox #(.WIDTH(49)) requests(arst,cpu_clk,push,qready,{write,addr,wstrb,wdata},fast_clk,qvalid,qtake,qdata);
 assign {mwrite,maddr,mwstrb,mwdata}=qdata;
 assign mvalid=qvalid&&sready;assign qtake=mready&&sready;
 package_mailbox #(.WIDTH(33)) responses(arst,fast_clk,mvalid&&mready,sready,{merror,mrdata},cpu_clk,svalid,valid&&ready,sdata);
 assign ready=svalid&&!cpu_arst;assign error=sdata[32];assign rdata=sdata[31:0];
 always @(posedge cpu_clk or posedge cpu_arst)begin
  if(cpu_arst)inflight<=0;
  else begin
   if(push&&qready)inflight<=1;
   if(valid&&ready)inflight<=0;
  end
 end
endmodule
