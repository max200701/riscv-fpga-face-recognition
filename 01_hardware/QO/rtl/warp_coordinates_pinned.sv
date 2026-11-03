// Independent bounded integer-coordinate helper. CPU supplies separately rounded
// OpenCV-compatible 1024-scale row/column terms; no fixed-point matrix shortcut.
module warp_coordinates_pinned(
 input wire pinned_mode,
 input wire clk,rst,in_valid,output wire in_ready,
 input wire signed[31:0] ax,ay,bx,by,input wire[15:0] src_w,src_h,
 input wire[31:0] in_tag,output wire out_valid,input wire out_ready,
 output reg signed[15:0] sx,sy,output reg[4:0] fx,fy,
 output reg[3:0] valid_corners,output wire[31:0] out_tag,output wire out_error
);
 reg[2:0] valid,errors;reg[31:0]tags[0:2];
 wire advance=!valid[2]||out_ready;assign in_ready=!rst&&advance;
 assign out_valid=valid[2];assign out_tag=tags[2];assign out_error=errors[2];
 reg signed[32:0] sumx,sumy;reg[15:0]w0,h0,w1,h1;
 reg signed[15:0]x1,y1;reg[4:0]fx1,fy1;
 wire signed[32:0] ix=sumx>>>10,iy=sumy>>>10;
 wire signed[16:0] x0e={x1[15],x1},y0e={y1[15],y1};
 wire signed[16:0] xne=x0e+17'sd1,yne=y0e+17'sd1;
 wire xok=x0e>=0&&x0e<$signed({1'b0,w1});
 wire xnok=xne>=0&&xne<$signed({1'b0,w1});
 wire yok=y0e>=0&&y0e<$signed({1'b0,h1});
 wire ynok=yne>=0&&yne<$signed({1'b0,h1});
 wire bad=src_w==0||src_h==0||src_w>32767||src_h>32767||
 (!pinned_mode&&(ax>32'sd1000000000||ax< -32'sd1000000000||ay>32'sd1000000000||ay< -32'sd1000000000||
 bx>32'sd1000000000||bx< -32'sd1000000000||by>32'sd1000000000||by< -32'sd1000000000));
 wire[31:0]wrapx=ax+bx+32'd16,wrapy=ay+by+32'd16;
 integer k;
 always @(posedge clk)begin
  if(rst)begin valid<=0;errors<=0;sumx<=0;sumy<=0;x1<=0;y1<=0;fx1<=0;fy1<=0;w0<=0;h0<=0;w1<=0;h1<=0;sx<=0;sy<=0;fx<=0;fy<=0;valid_corners<=0;for(k=0;k<3;k=k+1)tags[k]<=0;end
  else if(advance)begin
   valid<={valid[1:0],in_valid};errors<={errors[1:0],bad};tags[0]<=in_tag;tags[1]<=tags[0];tags[2]<=tags[1];
   sumx<=pinned_mode?$signed({wrapx[31],wrapx}):$signed({ax[31],ax})+$signed({bx[31],bx})+33'sd16;
   sumy<=pinned_mode?$signed({wrapy[31],wrapy}):$signed({ay[31],ay})+$signed({by[31],by})+33'sd16;w0<=src_w;h0<=src_h;
   x1<=ix>32767?16'sd32767:ix< -32768?-16'sd32768:ix[15:0];
   y1<=iy>32767?16'sd32767:iy< -32768?-16'sd32768:iy[15:0];
   fx1<=sumx[9:5];fy1<=sumy[9:5];w1<=w0;h1<=h0;
   sx<=x1;sy<=y1;fx<=fx1;fy<=fy1;
   valid_corners<=errors[1]?4'b0:{ynok&&xnok,ynok&&xok,yok&&xnok,yok&&xok};
  end
 end
endmodule
