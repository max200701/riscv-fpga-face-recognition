// NEW reconstruction. Exact integer interpolation, no floating arithmetic.
module warp_bilinear_new(input wire clk,rst,in_valid,output wire in_ready,
 input wire[95:0]pixels_bgr,input wire[3:0]valid_corners,input wire[4:0]fx,fy,
 output wire out_valid,input wire out_ready,output reg[23:0]rgb);
 reg[2:0]valid;reg[4:0]fy_q;
 reg signed[15:0]top[0:2],bottom[0:2];reg signed[20:0]acc[0:2];
 wire advance=!valid[2]||out_ready;assign in_ready=!rst&&advance;assign out_valid=valid[2];
 function automatic signed[20:0]times5(input signed[20:0]a,input[4:0]b);
 reg signed[20:0]p0,p1,p2,p3,p4;begin
 p0=b[0]?a:0;p1=b[1]?(a<<<1):0;p2=b[2]?(a<<<2):0;p3=b[3]?(a<<<3):0;p4=b[4]?(a<<<4):0;
 times5=((p0+p1)+(p2+p3))+p4;end endfunction
 function automatic signed[15:0]horizontal(input[7:0]a,b,input[4:0]f);
 reg signed[20:0]aa,bb;begin aa=$signed({1'b0,a});bb=$signed({1'b0,b});horizontal=(aa<<<5)+times5(bb-aa,f);end endfunction
 integer k;
 always @(posedge clk)begin
  if(rst)begin valid<=0;rgb<=0;fy_q<=0;for(k=0;k<3;k=k+1)begin top[k]<=0;bottom[k]<=0;acc[k]<=0;end end
  else if(advance)begin
   valid<={valid[1:0],in_valid};fy_q<=fy;
   for(k=0;k<3;k=k+1)begin
    top[k]<=horizontal(valid_corners[0]?pixels_bgr[k*8+:8]:8'd0,valid_corners[1]?pixels_bgr[24+k*8+:8]:8'd0,fx);
    bottom[k]<=horizontal(valid_corners[2]?pixels_bgr[48+k*8+:8]:8'd0,valid_corners[3]?pixels_bgr[72+k*8+:8]:8'd0,fx);
    acc[k]<=($signed({{5{top[k][15]}},top[k]})<<<5)+times5($signed({{5{bottom[k][15]}},bottom[k]})-$signed({{5{top[k][15]}},top[k]}),fy_q);
    rgb[(2-k)*8+:8]<=(acc[k]+21'sd512)>>>10;
   end
  end
 end
endmodule
