// Candidate adaptation of the recovered warp engine, not historical source identity.
// Fixed Q16 BGR-minus-mean VGA -> exact original normalized Q16 RGB 112x112.
// Preserve wrapped coordinates, 5-bit fractions, zero border and integer rounding.
// Caller owns immutable frame/terms/descriptor and exclusive destination.
// NEW implementation from recovered ABI/partial donor. No old acceptance claim.
// Caller owns immutable descriptor/table/frame and exclusive destination lease.
module retina_warp_q16 #(parameter TIMEOUT_CYCLES=200000,parameter CHECK_AUTHORITY=0)(
 input wire[31:0]authority_source,authority_bytes,authority_dest,authority_terms,authority_desc,
 input wire[31:0]cmd_tag,
 input wire clk,rst,dma_fault,cmd_valid,input wire[31:0]cmd_desc_addr,output wire cmd_ready,
 output reg cmd_done,output reg[3:0]error,
 output wire rd_valid,input wire rd_ready,output wire[31:0]rd_addr,output wire[4:0]rd_beats,
 input wire r_valid,output wire r_ready,input wire[255:0]r_data,input wire r_last,r_error,
 output wire out_valid,input wire out_ready,output wire[255:0]out_data,
 output wire[31:0]out_addr,out_strb,out_tag,output wire out_last,
 input wire posted_valid,output wire posted_ready,input wire[31:0]posted_tag,
 output reg[63:0]cycles,read_requests,cache_misses,read_bytes,write_bytes,
 output reg[2:0]peak_requests);
 localparam IDLE=0,D_AR=1,D_READ=2,D_CHECK=3,ROWS=4,RANGES=5,T_AR=6,T_READ=7,T_FILL=8,
 C_COL=9,C_COL_WAIT=10,C_ROW=11,C_ROW_WAIT=12,C_SEND=13,C_WAIT=14,P_ROW=15,P_ROW_WAIT=16,
 ADDR=17,SCAN=18,GATHER=19,GOT_BYTE=20,B_SEND=21,B_WAIT=22,WRITE=23,POST=24,ADDR2=25,ISSUE_SCAN=26,ISSUE_GATHER=27,D_QUAL=28,RANGE_ENDS=29,RANGE_CHECK=30,FAULT=31;
 reg[31:0]job_tag;reg[4:0]state,prev;reg[31:0]watchdog,desc,d[0:31];reg[1:0]dbeat;
 reg watchdog_clear;
 reg[8:0]rows_left;reg[11:0]row_stride;
 reg[8:0]row_number;reg[31:0]row_acc,plane;reg[5:0]term_beat;reg[2:0]term_word;reg[255:0]term_data;
 reg[6:0]x,y;reg[13:0]pixel;reg signed[31:0]ax,ay,bx,by;reg signed[15:0]sx,sy;
 reg[4:0]fx,fy;reg[3:0]mask;reg[31:0]row0,row1,address[0:11];reg[3:0]scan,byte_index;
 reg[95:0]pixels;reg[255:0]planes[0:2];reg[1:0]write_plane;
 wire pinned_mode=d[1]==3&&d[8]==1;
 assign cmd_ready=state==IDLE&&!rst&&!dma_fault&&!r_valid&&!posted_valid;
 function[6:0]index_of(input[24:0]line);begin index_of=line[6:0]^line[13:7];end endfunction
 function is_valid_byte(input[3:0]n,input[3:0]m);begin is_valid_byte=n<3?m[0]:n<6?m[1]:n<9?m[2]:m[3];end endfunction
 function overlap(input[31:0]a,input[32:0]ae,input[31:0]b,input[32:0]be);begin overlap={1'b0,a}<be&&{1'b0,b}<ae;end endfunction
 wire[32:0]source_size=({1'b0,plane}<<1)+{1'b0,plane};
 reg[32:0]source_padded,source_end,terms_end,dest_end,desc_end;
 reg descriptor_bad_q;
 always @(posedge clk)begin
  if(state==RANGES)source_padded<=(source_size+33'd31)&~33'd31;
  if(state==RANGE_ENDS)begin
   source_end<={1'b0,d[4]}+source_padded;terms_end<={1'b0,d[5]}+33'd1792;
   dest_end<={1'b0,d[6]}+33'd150528;desc_end<={1'b0,desc}+33'd128;
  end
 end
 reg reserved_bad;integer z,reserved_index,pending_index;
 always @*begin reserved_bad=0;for(reserved_index=9;reserved_index<32;reserved_index=reserved_index+1)if(d[reserved_index]!=0)reserved_bad=1;
 if(d[8]!=1)reserved_bad=1;end
 wire ranges_bad=source_end>33'h040000000||terms_end>33'h040000000||dest_end>33'h040000000||desc_end>33'h040000000||
 overlap(d[4],source_end,d[5],terms_end)||overlap(d[4],source_end,d[6],dest_end)||overlap(d[4],source_end,desc,desc_end)||
 overlap(d[5],terms_end,d[6],dest_end)||overlap(d[5],terms_end,desc,desc_end)||overlap(d[6],dest_end,desc,desc_end);
 reg[31:0]table_mem[0:1023];reg[31:0]ta,tb;
 wire table_write=state==ROWS||state==T_FILL;
 wire[9:0]table_wa=state==ROWS?10'd448+row_number:{1'b0,term_beat,term_word};
 wire[31:0]table_wd=state==ROWS?row_acc:term_data[term_word*32+:32];
 wire table_read=state==C_COL||state==C_ROW||state==P_ROW;
 wire[9:0]table_ra=state==C_COL?{3'b0,x}:state==C_ROW?10'd224+y:((mask[0]||mask[1])?10'd448+sy:10'd448);
 wire[9:0]table_rb=state==C_COL?10'd112+x:state==C_ROW?10'd336+y:((mask[2]||mask[3])?10'd449+sy:10'd448);
 wire[9:0]table_port_a=table_write?table_wa:table_ra;
 always @(posedge clk)begin if(table_write)table_mem[table_port_a]<=table_wd;else if(table_read)ta<=table_mem[table_port_a];end
 always @(posedge clk)if(table_read)tb<=table_mem[table_rb];
 reg[31:0]cache_mem[0:1023];reg[31:0]cache_q;reg[127:0]cache_valid;reg[24:0]cache_tag[0:127];
 reg[3:0]request_valid;reg[24:0]request_line[0:3];reg[1:0]head,tail;reg[2:0]requests;
 reg filling;reg[2:0]fill_word;reg[255:0]fill_data;
 wire[6:0]fill_index=index_of(request_line[head]);wire cache_pop=filling&&fill_word==7&&state!=FAULT;
 wire[3:0]candidate_index=state==SCAN?scan:byte_index;
 // registered candidate lookahead (see ADDR2 / SCAN / next_byte).
 reg[31:0]sc_cur,sc_nxt,by_cur,by_nxt;reg[6:0]sc_cur_set,sc_nxt_set,by_cur_set,by_nxt_set;
 wire[3:0]scan_ahead=scan>=10?4'd11:scan+4'd2;wire[3:0]byte_ahead=byte_index>=10?4'd11:byte_index+4'd2;
 wire[31:0]candidate_addr=state==SCAN?sc_cur:by_cur;wire[24:0]candidate_line=candidate_addr[29:5];
 wire[6:0]candidate_set=state==SCAN?sc_cur_set:by_cur_set;
 wire candidate_valid=is_valid_byte(candidate_index,mask);wire cache_hit=cache_valid[candidate_set]&&cache_tag[candidate_set]==candidate_line;
 reg same_pending,index_pending;
 always @*begin same_pending=0;index_pending=0;for(pending_index=0;pending_index<4;pending_index=pending_index+1)if(request_valid[pending_index])begin
 if(request_line[pending_index]==candidate_line)same_pending=1;if(index_of(request_line[pending_index])==candidate_set)index_pending=1;end end
 reg[24:0]cache_request_line;reg[6:0]cache_request_set;
 wire cache_issue=state==ISSUE_SCAN||state==ISSUE_GATHER;
 wire want_cache=(state==SCAN||state==GATHER)&&candidate_valid&&!cache_hit&&!same_pending&&!index_pending&&requests<4;
 assign rd_valid=!rst&&!dma_fault&&error==0&&(state==D_AR||state==T_AR||cache_issue);
 assign rd_addr=state==D_AR?desc:state==T_AR?d[5]+{21'b0,term_beat,5'b0}:{2'b0,cache_request_line,5'b0};
 assign rd_beats=state==D_AR?5'd4:5'd1;
 wire ar_fire=rd_valid&&rd_ready,cache_push=ar_fire&&cache_issue;
 wire cache_phase=(state>=C_COL&&state<=POST)||state==ADDR2||cache_issue;   // c20: ADDR2 lies between ADDR and SCAN
 assign r_ready=state==D_READ||state==T_READ||(cache_phase&&requests!=0&&!filling)||state==FAULT;
 wire r_fire=r_valid&&r_ready;
 wire response_bad=r_fire&&state!=FAULT&&(r_error||(state==D_READ?r_last!=(dbeat==3):!r_last));
 wire unsolicited=r_valid&&state!=FAULT&&state!=D_READ&&state!=T_READ&&requests==0;
 wire bad_post=posted_valid&&(state!=POST||requests!=0||filling||posted_tag!=job_tag);
 wire transport_fault=response_bad||unsolicited||dma_fault||bad_post;
 wire cache_read=state==GATHER&&candidate_valid&&cache_hit&&!transport_fault;
 always @(posedge clk)begin if(filling&&state!=FAULT)cache_mem[{fill_index,fill_word}]<=fill_data[fill_word*32+:32];if(cache_read)cache_q<=cache_mem[{candidate_set,candidate_addr[4:2]}];end
 wire cr,cv,ce;wire signed[15:0]cx,cy;wire[4:0]cfx,cfy;wire[3:0]cm;wire[31:0]ct;
 warp_coordinates_pinned coordinate(.pinned_mode(pinned_mode),.clk(clk),.rst(rst),.in_valid(state==C_SEND),.in_ready(cr),.ax(ax),.ay(ay),.bx(bx),.by(by),.src_w(d[2][15:0]),.src_h(d[3][15:0]),.in_tag({18'b0,pixel}),.out_valid(cv),.out_ready(state==C_WAIT),.sx(cx),.sy(cy),.fx(cfx),.fy(cfy),.valid_corners(cm),.out_tag(ct),.out_error(ce));
 wire br,bv;wire[23:0]rgb;wire[95:0]normalized;
 wire signed[31:0]restore_mean=(byte_index==0||byte_index==3||byte_index==6||byte_index==9)?32'sd104:
  (byte_index==1||byte_index==4||byte_index==7||byte_index==10)?32'sd117:32'sd123;
 wire signed[31:0]restored_pixel=($signed(cache_q)>>>16)+restore_mean;
 retina_warp_normalize normalize(.rgb(rgb),.q16(normalized));
 warp_bilinear_new interpolate(.clk(clk),.rst(rst),.in_valid(state==B_SEND),.in_ready(br),.pixels_bgr(pixels),.valid_corners(mask),.fx(fx),.fy(fy),.out_valid(bv),.out_ready(state==B_WAIT),.rgb(rgb));
 assign out_valid=state==WRITE&&!rst&&error==0&&!transport_fault;
 assign out_addr=d[6]+(write_plane==0?32'd0:write_plane==1?32'd50176:32'd100352)+{16'b0,pixel[13:3],5'b0};
 assign out_data=planes[write_plane];assign out_strb=32'hffffffff;assign out_tag=job_tag;assign out_last=pixel==12543&&write_plane==2;
 assign posted_ready=state==POST&&requests==0&&!filling||state==FAULT;
 task fail(input[3:0]code);begin error<=code;state<=FAULT;cmd_done<=1;end endtask
 task next_pixel;begin pixel<=pixel+1'b1;if(x==111)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;pixels<=0;state<=C_COL;end endtask
 task advance_scan;begin
  if(scan==11)state<=GATHER;
  else begin state<=SCAN;scan<=scan+1'b1;
   sc_cur<=sc_nxt;sc_cur_set<=sc_nxt_set;sc_nxt<=address[scan_ahead];sc_nxt_set<=index_of(address[scan_ahead][29:5]);
  end
 end endtask
 task next_byte;begin if(byte_index==11)state<=B_SEND;else begin byte_index<=byte_index+1'b1;state<=GATHER;
  by_cur<=by_nxt;by_cur_set<=by_nxt_set;by_nxt<=address[byte_ahead];by_nxt_set<=index_of(address[byte_ahead][29:5]);end end endtask
 // PA: descriptor is consumed only after all four beats; terms/fill after
 // their accepted response; every output plane word is written before WRITE.
 // Reset invalidates state/ownership rather than clearing 2304 payload bits.
 integer payload_lane;
 always @(posedge clk)begin
  if(state==D_READ&&r_fire&&!response_bad)
   for(payload_lane=0;payload_lane<8;payload_lane=payload_lane+1)
    d[{dbeat,3'b0}+payload_lane]<=r_data[payload_lane*32+:32];
  if(state==T_READ&&r_fire&&!response_bad)term_data<=r_data;
  if(cache_phase&&r_fire&&!response_bad)fill_data<=r_data;
  if(state==B_WAIT&&bv)
   for(payload_lane=0;payload_lane<3;payload_lane=payload_lane+1)
    planes[payload_lane][pixel[2:0]*32+:32]<=normalized[payload_lane*32+:32];
 end
 // PI: row/table payload has an independent local enable. Invalid commands
 // may initialize these private registers but cannot enter ROWS or publish.
 always @(posedge clk)begin
  if(rst)begin row_number<=0;row_acc<=0;plane<=0;rows_left<=0;row_stride<=0;end
  else if(state==D_QUAL)begin
   row_number<=0;row_acc<=0;rows_left<=d[3][8:0];row_stride<={d[2][9:0],2'b0};
  end else if(state==ROWS)begin
   if(rows_left==0)plane<=row_acc;
   else begin row_number<=row_number+1'b1;rows_left<=rows_left-1'b1;row_acc<=row_acc+row_stride;end
  end
 end
 reg[31:0]loc;integer k,c;
 always @(posedge clk)begin
 if(rst)begin
 state<=IDLE;prev<=IDLE;watchdog<=0;watchdog_clear<=1;cmd_done<=0;error<=0;desc<=0;dbeat<=0;cache_request_line<=0;cache_request_set<=0;
 term_beat<=0;term_word<=0;x<=0;y<=0;pixel<=0;ax<=0;ay<=0;bx<=0;by<=0;sx<=0;sy<=0;fx<=0;fy<=0;mask<=0;row0<=0;row1<=0;scan<=0;byte_index<=0;pixels<=0;write_plane<=0;
 cache_valid<=0;request_valid<=0;head<=0;tail<=0;requests<=0;filling<=0;fill_word<=0;
 cycles<=0;read_requests<=0;cache_misses<=0;read_bytes<=0;write_bytes<=0;peak_requests<=0;

 end else begin
 cmd_done<=0;prev<=state;
 if(state!=IDLE&&state!=FAULT)cycles<=cycles+1;
 // the activity condition is registered (watchdog cleared one cycle later; the timeout is
 // millions of cycles, so only the cycle of a fault report can move by one).
 watchdog_clear<=state==IDLE||state==FAULT||prev!=state||ar_fire||r_fire||filling||(out_valid&&out_ready)||(posted_valid&&posted_ready);
 if(watchdog_clear)watchdog<=0;else watchdog<=watchdog+1;
 if(ar_fire)begin read_requests<=read_requests+1;read_bytes<=read_bytes+{54'b0,rd_beats,5'b0};end
 if(out_valid&&out_ready)write_bytes<=write_bytes+32;
 if(cache_push)begin request_line[tail]<=cache_request_line;request_valid[tail]<=1;tail<=tail+1'b1;cache_valid[cache_request_set]<=0;cache_misses<=cache_misses+1;end
 if(cache_pop)begin cache_valid[fill_index]<=1;cache_tag[fill_index]<=request_line[head];request_valid[head]<=0;head<=head+1'b1;filling<=0;end
 case({cache_push,cache_pop})2'b10:requests<=requests+1'b1;2'b01:requests<=requests-1'b1;default:begin end endcase
 if(requests>peak_requests)peak_requests<=requests;
 if(cache_phase&&r_fire&&!response_bad)begin filling<=1;fill_word<=0;end
 else if(filling&&state!=FAULT&&!cache_pop)fill_word<=fill_word+1'b1;
 case(state)
 IDLE:if(cmd_valid&&cmd_ready)begin
 if(cmd_tag==0||cmd_desc_addr[6:0]!=0||cmd_desc_addr[31:30]!=0||(CHECK_AUTHORITY&&cmd_desc_addr!=authority_desc))fail(1);
 else begin job_tag<=cmd_tag;desc<=cmd_desc_addr;dbeat<=0;state<=D_AR;error<=0;cache_valid<=0;cycles<=0;read_requests<=0;cache_misses<=0;read_bytes<=0;write_bytes<=0;peak_requests<=0;x<=0;y<=0;pixel<=0;pixels<=0;end end
 D_AR:if(ar_fire)state<=D_READ;
 D_READ:if(r_fire&&!response_bad)begin if(dbeat==3)state<=D_CHECK;else dbeat<=dbeat+1'b1;end
 D_CHECK:begin descriptor_bad_q<=(CHECK_AUTHORITY&&(d[4]!=authority_source||d[5]!=authority_terms||d[6]!=authority_dest||authority_bytes!=3686400||d[2]!=640||d[3]!=480||d[7]!=0))||d[0]!=32'h31505257||d[1]!=3||d[2]==0||d[2]>640||d[3]==0||d[3]>480||d[7]!=0||reserved_bad||d[4][4:0]!=0||d[5][4:0]!=0||d[6][4:0]!=0||d[4][31:30]!=0||d[5][31:30]!=0||d[6][31:30]!=0;state<=D_QUAL;end
 D_QUAL:if(descriptor_bad_q)fail(2);else state<=ROWS;
 ROWS:if(rows_left==0)state<=RANGES;
 RANGES:state<=RANGE_ENDS;
 RANGE_ENDS:state<=RANGE_CHECK;
 RANGE_CHECK:if(ranges_bad)fail(2);else begin term_beat<=0;state<=T_AR;end
 T_AR:if(ar_fire)state<=T_READ;
 T_READ:if(r_fire&&!response_bad)begin term_word<=0;state<=T_FILL;end
 // PF: D_CHECK already proves pinned mode; immutable terms have no non-pinned bounds.
 T_FILL:if(!pinned_mode)fail(3);else if(term_word==7)begin if(term_beat==55)state<=C_COL;else begin term_beat<=term_beat+1'b1;state<=T_AR;end end else term_word<=term_word+1'b1;
 C_COL:state<=C_COL_WAIT;
 C_COL_WAIT:begin ax<=ta;ay<=tb;state<=C_ROW;end
 C_ROW:state<=C_ROW_WAIT;
 C_ROW_WAIT:begin bx<=ta;by<=tb;state<=C_SEND;end
 C_SEND:if(cr)state<=C_WAIT;
 C_WAIT:if(cv)begin if(ce||ct!={18'b0,pixel})fail(3);else begin sx<=cx;sy<=cy;fx<=cfx;fy<=cfy;mask<=cm;state<=P_ROW;end end
 P_ROW:state<=P_ROW_WAIT;
 P_ROW_WAIT:begin row0<=ta;row1<=tb;state<=ADDR;end
 ADDR:begin
 for(k=0;k<4;k=k+1)begin
  loc=(k<2?row0:row1)+({{16{sx[15]}},sx}<<2)+((k&1)<<2);
  for(c=0;c<3;c=c+1)address[k*3+c]<=d[4]+loc+(c==0?0:c==1?plane:(plane<<1));
 end
 scan<=0;byte_index<=0;pixels<=0;state<=ADDR2;end
 ADDR2:begin
  sc_cur<=address[0];sc_nxt<=address[1];by_cur<=address[0];by_nxt<=address[1];
  sc_cur_set<=index_of(address[0][29:5]);sc_nxt_set<=index_of(address[1][29:5]);
  by_cur_set<=index_of(address[0][29:5]);by_nxt_set<=index_of(address[1][29:5]);state<=SCAN;
 end
 SCAN:begin
  if(!candidate_valid||cache_hit||same_pending)advance_scan();
  else if(want_cache)begin
   cache_request_line<=candidate_line;cache_request_set<=candidate_set;state<=ISSUE_SCAN;
  end
 end
 ISSUE_SCAN:if(ar_fire)advance_scan();
 GATHER:begin
  if(!candidate_valid)begin pixels[byte_index*8+:8]<=0;next_byte();end
  else if(cache_hit)state<=GOT_BYTE;
  else if(want_cache)begin
   cache_request_line<=candidate_line;cache_request_set<=candidate_set;state<=ISSUE_GATHER;
  end
 end
 ISSUE_GATHER:if(ar_fire)state<=GATHER;
 GOT_BYTE:begin
  if(cache_q[15:0]!=0||restored_pixel<0||restored_pixel>255)fail(7);
  else begin pixels[byte_index*8+:8]<=restored_pixel[7:0];next_byte();end
 end
 B_SEND:if(br)state<=B_WAIT;
 B_WAIT:if(bv)begin

  if(pixel[2:0]==7)begin write_plane<=0;state<=WRITE;end else next_pixel();end
 WRITE:if(out_valid&&out_ready)begin if(write_plane!=2)write_plane<=write_plane+1'b1;else if(pixel==12543)state<=POST;else next_pixel();end
 POST:if(posted_valid&&posted_ready&&!bad_post)begin cmd_done<=1;state<=IDLE;end
 FAULT:begin end
 default:fail(3);
 endcase
 if(state!=FAULT&&transport_fault)fail(bad_post?4'd5:4'd4);
 else if(state!=IDLE&&state!=FAULT&&watchdog>=TIMEOUT_CYCLES)fail(6);
 end end
endmodule
