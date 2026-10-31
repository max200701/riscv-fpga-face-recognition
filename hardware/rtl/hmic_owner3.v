// Single outstanding read and write owner on an HMIC controller port.
// Request fields are held from grant until acceptance. Entire responses/bursts
// belong to that owner. No synthetic AXI B response is created.
module hmic_owner3(
 input wire clk,rst,
 input wire[2:0]sv_arvalid,output reg[2:0]sv_arready,input wire[83:0]sv_araddr,
 input wire[11:0]sv_arlen,sv_arid,input wire[2:0]sv_arap,
 output reg[2:0]sv_rvalid,output wire[255:0]sv_rdata,output wire sv_rlast,output wire[3:0]sv_rid,
 input wire[2:0]sv_awvalid,output reg[2:0]sv_awready,input wire[83:0]sv_awaddr,
 input wire[11:0]sv_awlen,sv_awid,input wire[2:0]sv_awap,
 input wire[767:0]sv_wdata,input wire[95:0]sv_wstrb,output reg[2:0]sv_wready,
 output wire[3:0]sv_wid,output wire sv_wlast,
 output wire arvalid,input wire arready,output wire[27:0]araddr,output wire[3:0]arlen,arid,output wire arap,
 input wire rvalid,input wire[255:0]rdata,input wire rlast,input wire[3:0]rid,
 output wire awvalid,input wire awready,output wire[27:0]awaddr,output wire[3:0]awlen,awid,output wire awap,
 output wire[255:0]wdata,output wire[31:0]wstrb,input wire wready,input wire[3:0]wid,input wire wlast,
 output reg fault
);
 reg[1:0]rs,ws,ro,wo,rturn,wturn;reg[4:0]rleft,wleft;
 reg[27:0]ra,wa;reg[3:0]rn,wn,ri,wi;reg rap,wap;
 integer k,n;reg found;
 assign arvalid=rs==1&&!rst;assign araddr=ra;assign arlen=rn;assign arid=ri;assign arap=rap;
 assign awvalid=ws==1&&!rst;assign awaddr=wa;assign awlen=wn;assign awid=wi;assign awap=wap;
 assign sv_rdata=rdata;assign sv_rlast=rlast;assign sv_rid=rid;assign sv_wid=wid;assign sv_wlast=wlast;
 assign wdata=sv_wdata[wo*256+:256];assign wstrb=sv_wstrb[wo*32+:32];
 always @*begin
  sv_arready=0;sv_awready=0;sv_rvalid=0;sv_wready=0;
  if(!rst)begin
   if(rs==1)sv_arready[ro]=arready;
   if(rs==2)sv_rvalid[ro]=rvalid;
   if(ws==1)sv_awready[wo]=awready;
   if(ws==2)sv_wready[wo]=wready;
  end
 end
 always @(posedge clk)begin
  if(rst)begin rs<=0;ws<=0;ro<=0;wo<=0;rturn<=0;wturn<=0;rleft<=0;wleft<=0;ra<=0;wa<=0;rn<=0;wn<=0;ri<=0;wi<=0;rap<=0;wap<=0;fault<=0;end
  else begin
   if(rs==0)begin
    found=0;
    for(k=0;k<3;k=k+1)begin
     n=rturn+k;if(n>=3)n=n-3;
     if(!found&&sv_arvalid[n])begin
      found=1;ro<=n;rs<=1;ra<=sv_araddr[n*28+:28];rn<=sv_arlen[n*4+:4];ri<=sv_arid[n*4+:4];rap<=sv_arap[n];
     end
    end
   end
   if(rs==1&&arready)begin rs<=2;rleft<={1'b0,rn}+1'b1;rturn<=ro==2?0:ro+1'b1;end
   if(rvalid)begin
    if(rs!=2)fault<=1;
    else begin
     if(rlast!=(rleft==1)||rid!=ri)fault<=1;
     if(rleft==1||rlast)rs<=0;else rleft<=rleft-1'b1;
    end
   end
   if(ws==0)begin
    found=0;
    for(k=0;k<3;k=k+1)begin
     n=wturn+k;if(n>=3)n=n-3;
     if(!found&&sv_awvalid[n])begin
      found=1;wo<=n;ws<=1;wa<=sv_awaddr[n*28+:28];wn<=sv_awlen[n*4+:4];wi<=sv_awid[n*4+:4];wap<=sv_awap[n];
     end
    end
   end
   if(ws==1&&awready)begin ws<=2;wleft<={1'b0,wn}+1'b1;wturn<=wo==2?0:wo+1'b1;end
   if(wready&&ws==2)begin
    if(wlast!=(wleft==1)||wid!=wi)fault<=1;
    if(wleft==1||wlast)ws<=0;else wleft<=wleft-1'b1;
   end
  end
 end
endmodule
