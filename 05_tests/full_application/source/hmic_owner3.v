// PL: bounded ordered read-owner queue; unchanged single write owner.
module hmic_owner3 #(parameter integer READ_SLOTS=4)(
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

 // The downstream board client/bridge returns reads in acceptance order.
 // Reserve owner metadata at request acceptance; retire only on valid RLAST.
 localparam PTR_W=(READ_SLOTS<=1)?1:$clog2(READ_SLOTS);
 reg pending;reg[1:0]ro,rturn;
 reg[27:0]ra;reg[3:0]rn,ri;reg rap;
 reg[PTR_W-1:0]rhead,rtail;reg[PTR_W:0]rcount;
 reg[1:0]owners[0:READ_SLOTS-1];reg[3:0]ids[0:READ_SLOTS-1];
 reg[4:0]lengths[0:READ_SLOTS-1];reg[4:0]rindex;
 reg[1:0]ws,wo,wturn;reg[4:0]wleft;
 reg[27:0]wa;reg[3:0]wn,wi;reg wap;
 integer k,n;reg found;
 function [PTR_W-1:0]advance(input[PTR_W-1:0]p);
  advance=(p==READ_SLOTS-1)?0:p+1'b1;
 endfunction
 assign arvalid=pending&&!rst&&!fault;assign araddr=ra;assign arlen=rn;assign arid=ri;assign arap=rap;
 assign awvalid=ws==1&&!rst&&!fault;assign awaddr=wa;assign awlen=wn;assign awid=wi;assign awap=wap;
 assign sv_rdata=rdata;assign sv_rlast=rlast;assign sv_rid=rid;assign sv_wid=wid;assign sv_wlast=wlast;
 assign wdata=sv_wdata[wo*256+:256];assign wstrb=sv_wstrb[wo*32+:32];
 wire push=arvalid&&arready;
 wire good_r=rcount!=0&&rid==ids[rhead]&&rlast==(rindex+1==lengths[rhead]);
 wire pop=rvalid&&good_r&&rlast&&!fault;
 always @*begin
  sv_arready=0;sv_awready=0;sv_rvalid=0;sv_wready=0;
  if(!rst&&!fault)begin
   if(pending)sv_arready[ro]=arready;
   if(rcount!=0&&good_r)sv_rvalid[owners[rhead]]=rvalid;
   if(ws==1)sv_awready[wo]=awready;
   if(ws==2)sv_wready[wo]=wready;
  end
 end
 always @(posedge clk)begin
  if(rst)begin
   pending<=0;ro<=0;rturn<=0;ra<=0;rn<=0;ri<=0;rap<=0;rhead<=0;rtail<=0;rcount<=0;rindex<=0;
   ws<=0;wo<=0;wturn<=0;wleft<=0;wa<=0;wn<=0;wi<=0;wap<=0;fault<=0;
  end else begin
   if(!pending&&rcount<READ_SLOTS&&!fault)begin
    found=0;
    for(k=0;k<3;k=k+1)begin
     n=rturn+k;if(n>=3)n=n-3;
     if(!found&&sv_arvalid[n])begin
      found=1;ro<=n;pending<=1;ra<=sv_araddr[n*28+:28];rn<=sv_arlen[n*4+:4];ri<=sv_arid[n*4+:4];rap<=sv_arap[n];
     end
    end
   end
   if(push)begin
    pending<=0;owners[rtail]<=ro;ids[rtail]<=ri;lengths[rtail]<={1'b0,rn}+1'b1;
    rtail<=advance(rtail);rturn<=ro==2?0:ro+1'b1;
   end
   case({push,pop})2'b10:rcount<=rcount+1'b1;2'b01:rcount<=rcount-1'b1;default:begin end endcase
   if(rvalid&&!fault)begin
    if(!good_r)fault<=1;
    else if(rlast)begin rhead<=advance(rhead);rindex<=0;end
    else rindex<=rindex+1'b1;
   end
   if(ws==0&&!fault)begin
    found=0;
    for(k=0;k<3;k=k+1)begin
     n=wturn+k;if(n>=3)n=n-3;
     if(!found&&sv_awvalid[n])begin
      found=1;wo<=n;ws<=1;wa<=sv_awaddr[n*28+:28];wn<=sv_awlen[n*4+:4];wi<=sv_awid[n*4+:4];wap<=sv_awap[n];
     end
    end
   end
   if(ws==1&&awready&&!fault)begin ws<=2;wleft<={1'b0,wn}+1'b1;wturn<=wo==2?0:wo+1'b1;end
   if(wready&&ws==2&&!fault)begin
    if(wlast!=(wleft==1)||wid!=wi)fault<=1;
    if(wleft==1||wlast)ws<=0;else wleft<=wleft-1'b1;
   end
  end
 end
endmodule
