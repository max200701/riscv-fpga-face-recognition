// pure-copy transpose for vector op 0 (identity, Q16 output). The engine routes
// a descriptor here only when X walks a contiguous source (A stride 4) and Y walks a
// contiguous destination (D stride 4), e.g. the detector anchor table (planar head tensors
// -> per-anchor records). Element values and the written byte set equal the per-element
// path; only the DDR access pattern changes:
//  * walk order z, 8-cell tile, plane y; the 1..2 lines of each (z, tile, y) span are read as
//    single-beat requests (never crossing a 4 KiB page) issued ahead of the consumer
//    (returned beats wait in the transport response FIFO, credit-bounded);
//  * a group of up to 4 consecutive planes is captured, then one fragment of up to four
//    words (16-byte aligned slot) is emitted per cell.
module graph_transpose_stream(
 input wire clk,rst,start,
 input wire[31:0]n,f,nz,abase,dbase,p,q,sd,r,
 output wire rd_valid,input wire rd_ready,output wire[31:0]rd_addr,output wire[4:0]rd_beats,
 input wire r_valid,output wire r_ready,input wire[255:0]r_data,input wire r_last,r_error,
 output wire fragment_valid,input wire fragment_ready,output wire[31:0]fragment_addr,output reg[127:0]fragment_data,
 output wire[4:0]fragment_bytes,output wire fragment_last,
 input wire posted_valid,output wire posted_ready,output reg done,output reg[7:0]error,output reg[63:0]elements
);
 localparam IDLE=0,RUN=1,EMIT=2,POST=3;
 reg[1:0]state;
 // PG: snapshot the immutable command locally; advance tile counts once per tile.
 reg[31:0]n_q,f_q,nz_q,p_q,q_q,sd_q,r_q;
 always @(posedge clk)if(!rst&&state==IDLE&&start)begin
  n_q<=n;f_q<=f;nz_q<=nz;p_q<=p;q_q<=q;sd_q<=sd;r_q<=r;
 end
 reg[31:0]wremain,cremain;reg[3:0]wcount,ccount;
 // ---- request walker (runs ahead) ----
 reg[31:0] wy_left,wz_left,cy_left,cz_left;
 reg wactive,wsub;reg[31:0]wx,wy,wz,wzb,wyb;reg[7:0]credit;   // credit = requested-but-unconsumed beats
 wire[31:0]wcnt={28'b0,wcount};
 wire[31:0]waddr=wyb+{wx[29:0],2'b0};
 wire[5:0]wspan={1'b0,waddr[4:2]}+wcnt[5:0];              // words from line start, <=15
 wire[4:0]wbeats=wspan>8?5'd2:5'd1;
 assign rd_valid=state!=IDLE&&state!=POST&&wactive&&credit<=8'd60&&error==0;
 assign rd_addr={waddr[31:5]+wsub,5'b0};assign rd_beats=5'd1;
 wire wfire=rd_valid&&rd_ready;
 // ---- consumer: captures beats of the current plane group ----
 reg[31:0]cx,cy,cz,cab,cdz,ctile;reg[4:0]cbeat;reg[2:0]ck;reg[511:0]buf0,buf1,buf2,buf3;reg[2:0]off0,off1,off2,off3;
 reg[31:0]cyb;
 reg[31:0]next_ctile,next_cdz,next_cab;
 // Every EMIT entry follows a RUN edge. Prepare locally without a new wait state.
 always @(posedge clk)if(!rst&&state==RUN)begin
  next_ctile<=ctile+{sd_q[28:0],3'b0};next_cdz<=cdz+r_q;next_cab<=cab+q_q;
 end
 wire[31:0]ccnt={28'b0,ccount};
 wire[31:0]caddr=cyb+{cx[29:0],2'b0};
 wire[5:0]cspan={1'b0,caddr[4:2]}+ccnt[5:0];
 wire[4:0]cbeats=cspan>8?5'd2:5'd1;
 wire group_end=cy[1:0]==2'd3||cy_left==1;
 assign r_ready=state==RUN&&error==0;
 wire take=r_valid&&r_ready;
 // ---- emitter ----
 reg[3:0]ej;reg[2:0]egsz;reg[31:0]eptr;reg[3:0]ecnt;reg elast_group;
 assign fragment_valid=state==EMIT&&error==0;
 assign fragment_addr=eptr;assign fragment_bytes={egsz,2'b0};
 assign fragment_last=elast_group&&ej+1==ecnt;
 assign posted_ready=state==POST&&error==0;
 reg[3:0]i0,i1,i2,i3;
 always @*begin
  fragment_data[31:0]=buf0[i0*32+:32];
  fragment_data[63:32]=egsz>1?buf1[i1*32+:32]:32'b0;
  fragment_data[95:64]=egsz>2?buf2[i2*32+:32]:32'b0;
  fragment_data[127:96]=egsz>3?buf3[i3*32+:32]:32'b0;
 end
 always @(posedge clk)begin
  if(rst)begin
   wy_left<=0;wz_left<=0;cy_left<=0;cz_left<=0;
   state<=IDLE;done<=0;error<=0;elements<=0;wactive<=0;wsub<=0;wx<=0;wy<=0;wz<=0;wzb<=0;wyb<=0;credit<=0;
   cx<=0;cy<=0;cz<=0;cab<=0;cdz<=0;cyb<=0;ctile<=0;cbeat<=0;ck<=0;ej<=0;egsz<=0;eptr<=0;ecnt<=0;elast_group<=0;
   off0<=0;off1<=0;off2<=0;off3<=0;i0<=0;i1<=0;i2<=0;i3<=0;wremain<=0;cremain<=0;wcount<=0;ccount<=0;
  end else begin
   done<=0;
   case({wfire,take})
    2'b10:credit<=credit+1'b1;
    2'b01:credit<=credit-1'b1;
    default:begin end
   endcase
   if(wfire&&wbeats==2&&!wsub)wsub<=1;   // second line of a misaligned span
   else if(wfire)begin   // advance walker: y innermost, then tile, then z
    wsub<=0;
    if(wy_left>1)begin wy_left<=wy_left-1;wy<=wy+1;wyb<=wyb+p_q;end
    else if(wremain>8)begin wy_left<=f_q;wy<=0;wyb<=wzb;wx<=wx+8;wremain<=wremain-8;wcount<=wremain>16?4'd8:wremain-8;end
    else if(wz_left>1)begin wy_left<=f_q;wz_left<=wz_left-1;wy<=0;wx<=0;wz<=wz+1;wzb<=wzb+q_q;wyb<=wzb+q_q;wremain<=n_q;wcount<=n_q>8?4'd8:n_q[3:0];end
    else wactive<=0;
   end
   case(state)
    IDLE:if(start)begin
     wy_left<=f;wz_left<=nz;cy_left<=f;cz_left<=nz;
     wactive<=1;wsub<=0;wx<=0;wy<=0;wz<=0;wzb<=abase;wyb<=abase;credit<=0;
     wremain<=n;cremain<=n;wcount<=n>8?4'd8:n[3:0];ccount<=n>8?4'd8:n[3:0];
     cx<=0;cy<=0;cz<=0;cab<=abase;cdz<=dbase;cyb<=abase;ctile<=dbase;cbeat<=0;ck<=0;error<=0;state<=RUN;
    end
    RUN:if(take)begin
     if(r_error||!r_last)error<=8'h3a;
     else begin
      case(ck)
       0:begin if(cbeat==0)begin buf0[255:0]<=r_data;off0<=caddr[4:2];end else buf0[511:256]<=r_data;end
       1:begin if(cbeat==0)begin buf1[255:0]<=r_data;off1<=caddr[4:2];end else buf1[511:256]<=r_data;end
       2:begin if(cbeat==0)begin buf2[255:0]<=r_data;off2<=caddr[4:2];end else buf2[511:256]<=r_data;end
       default:begin if(cbeat==0)begin buf3[255:0]<=r_data;off3<=caddr[4:2];end else buf3[511:256]<=r_data;end
      endcase
      if(cbeat+1<cbeats)cbeat<=cbeat+1'b1;
      else begin
       cbeat<=0;
       if(group_end)begin
        // Cursor snapshot removes offset addition from the wide output mux.
        i0<={1'b0,(ck==0&&cbeat==0?caddr[4:2]:off0)};
        i1<={1'b0,(ck==1&&cbeat==0?caddr[4:2]:off1)};
        i2<={1'b0,(ck==2&&cbeat==0?caddr[4:2]:off2)};
        i3<={1'b0,(ck==3&&cbeat==0?caddr[4:2]:off3)};
        // emit this group: one fragment per cell of the tile
        ej<=0;egsz<=ck+1'b1;ecnt<=ccnt[3:0];eptr<=ctile+{cy[29:2],4'b0};
        elast_group<=cy_left==1&&cremain<=8&&cz_left==1;state<=EMIT;
       end else begin ck<=ck+1'b1;cy_left<=cy_left-1;cy<=cy+1;cyb<=cyb+p_q;end
      end
     end
    end
    EMIT:if(fragment_ready)begin
     i0<=i0+1'b1;i1<=i1+1'b1;i2<=i2+1'b1;i3<=i3+1'b1;
     elements<=elements+egsz;eptr<=eptr+sd_q;
     if(ej+1<ecnt)ej<=ej+1'b1;
     else begin   // advance consumer to the next group (same walk order as the requests)
      ck<=0;
      if(cy_left>1)begin cy_left<=cy_left-1;cy<=cy+1;cyb<=cyb+p_q;state<=RUN;end
      else if(cremain>8)begin cy_left<=f_q;cy<=0;cyb<=cab;cx<=cx+8;ctile<=next_ctile;cremain<=cremain-8;ccount<=cremain>16?4'd8:cremain-8;state<=RUN;end
      else if(cz_left>1)begin cy_left<=f_q;cz_left<=cz_left-1;cy<=0;cx<=0;cz<=cz+1;cab<=next_cab;cyb<=next_cab;cdz<=next_cdz;ctile<=next_cdz;cremain<=n_q;ccount<=n_q>8?4'd8:n_q[3:0];state<=RUN;end
      else state<=POST;
     end
    end
    POST:if(posted_valid)begin done<=1;state<=IDLE;end
   endcase
  end
 end
endmodule
