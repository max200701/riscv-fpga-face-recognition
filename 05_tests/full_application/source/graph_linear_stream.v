// Burst-fed contiguous inner loops. Two 1KiB input tiles, synchronous RAMs.
// Shares the parent's exact arithmetic/quantization pipeline and write packer.
// up to four read bursts (64 beats) are requested ahead of the data.
// two tile slots. A fill machine walks the x/y/z tiles and loads tile t+1
// into the free slot while the stream machine feeds tile t to the pipeline and emits its
// fragments. Feed values, fragment addresses/sizes and their order are unchanged. A tile is
// only filled early if its A/B byte ranges do not overlap the destination range of the
// tile still being streamed (otherwise it waits, as the single-slot design always did).
module graph_linear_stream(
 input wire clk,rst,start,input wire[31:0]nx_p,ny_p,nz_p,abase_p,bbase_p,dbase_p,
 input wire[31:0]ax_p,ay_p,az_p,bx_p,by_p,bz_p,dy_p,dz_p,input wire need_b_p,input wire[31:0]immediate_p,input wire[2:0]bpe_p,input wire repeat_rhs_p,
 output wire rd_valid,input wire rd_ready,output wire[31:0]rd_addr,output wire[4:0]rd_beats,
 input wire r_valid,output wire r_ready,input wire[255:0]r_data,input wire r_last,r_error,
 output wire feed_valid,input wire feed_ready,output reg[127:0]feed_a,feed_b,output wire[31:0]feed_meta,
 input wire result_valid,output wire result_ready,input wire[31:0]result_meta,
 output wire fragment_valid,input wire fragment_ready,output wire[31:0]fragment_addr,output wire[4:0]fragment_bytes,output wire fragment_last,
 input wire posted_valid,output wire posted_ready,output reg done,output reg[7:0]error,output reg[63:0]elements
);
 // configuration captured at start (ports *_p are only read in the start branch).
 reg[31:0]nx,ny,nz,abase,bbase,dbase,ax,ay,az,bx,by,bz,dy,dz,immediate;reg need_b,repeat_rhs;reg[2:0]bpe;
 // ---------------- fill side ----------------
 localparam IDLE=0,BEGIN=1,REQ=2,READ=3,FLUSH=4,FDONE=5,PRE=6,CONTEXT=7,SELECT=8,FINISH=9;
 reg[3:0]state;reg[31:0]x,y,z,ap,bp,dp,ar,br,dr,apl,bpl,dpl;
 // Stable command decode; no 32-bit stride compare in the read completion cone.
 reg a_sparse,b_sparse,b_broadcast;
 reg[5:0]a_logical_q,b_logical_q,current_logical;
 reg[2:0]b_prefix_q;
 reg[31:0]walk_x,walk_y,walk_z;
 reg[31:0]x_ap,x_bp,x_dp,row_ap,row_bp,row_dp,plane_ap,plane_bp,plane_dp;
 reg[1:0]advance_kind;
 reg tile_last_q;
 reg[31:0]next_ap,next_bp,next_dp;
 reg[2:0]lcount;wire[4:0]beat_left;
 reg[8:0]count;reg repeat_b;reg[1:0]format_shift;reg read_b;reg[5:0]remaining,offset;reg[4:0]burst_left;
 reg[5:0]logical_offset;reg[2:0]prefix;reg seen;reg[255:0]previous_word;
 // tile queue (slot = queue position): count, destination, last-tile flag
 reg[8:0]mcount[0:1];reg[31:0]mdp[0:1];reg mlast[0:1];reg mhead,mtail;reg[1:0]mused;
 wire[8:0]capacity=(ax==8||(need_b&&bx==8))?9'd128:9'd256;
 wire[8:0]next_count=nx-x>capacity?capacity:nx-x;
 wire[9:0]a_words=(ax==8)?{next_count,1'b0}:{1'b0,next_count};
 wire[9:0]b_words=repeat_b?{2'b0,count[8:1]}:(bx==8)?{count,1'b0}:{1'b0,count};
 wire accepted_word=state==READ&&r_valid&&!r_error&&lcount!=0&&r_last==(beat_left==1)&&error==0;
 wire tile_write=((accepted_word&&(prefix==0||seen))||state==FLUSH)&&error==0;
 wire[9:0]a_words_current=ax==8?{count,1'b0}:{1'b0,count};
 wire[5:0]logical_words=current_logical;
 wire[511:0]shift_source={state==FLUSH?256'b0:r_data,previous_word};
 wire[255:0]aligned_word=prefix==0?r_data:(shift_source>>{prefix,5'b0});
 wire stride_eight=read_b?b_sparse:a_sparse;
 wire broadcast_rhs=read_b&&b_broadcast;
 wire[6:0]tile_wa={read_b,6'b0}+(stride_eight?{2'b0,logical_offset[4:0]}:broadcast_rhs?7'b0:{1'b0,logical_offset[4:0],1'b0});
 wire[127:0]sparse_data={aligned_word[223:192],aligned_word[159:128],aligned_word[95:64],aligned_word[31:0]};
 wire[127:0]tile_data=broadcast_rhs?{4{r_data[bp[4:2]*32+:32]}}:stride_eight?sparse_data:aligned_word[127:0];
 reg[5:0]req_left;reg[31:0]req_cursor;
 reg[4:0]lens[0:3];reg[1:0]lhead,ltail;reg[6:0]inflight;
 reg[5:0]req2_left;reg[31:0]req2_cursor;reg req2_valid;
 wire[9:0]b_words_next=repeat_rhs?{2'b0,next_count[8:1]}:(bx==8)?{next_count,1'b0}:{1'b0,next_count};
 wire[5:0]b_beats_next=bx==0?6'd1:((b_words_next-(bx==8?1:0)+bp[4:2]+7)>>3);
 wire[7:0]page_beats=8'd128-{1'b0,req_cursor[11:5]};
 wire[5:0]page_limit=req_left<page_beats?req_left:page_beats;
 wire[32:0]read_end={1'b0,req_cursor}+{23'b0,rd_beats,5'b0};
 // PI: exact under rd_beats <= page_beats. Checked in the boundary fixture.
 wire read_range=req_cursor[4:0]==0&&rd_beats!=0&&req_cursor[31:30]==0;
 wire want_read=(state==REQ||state==READ)&&req_left!=0&&lcount<4&&inflight<=7'd48&&error==0;
 assign rd_valid=want_read&&read_range;
 reg range_bad_q;always @(posedge clk)range_bad_q<=!rst&&want_read&&!read_range;   // c23: fault check, one cycle later
 assign rd_addr=req_cursor;assign rd_beats=page_limit>16?5'd16:page_limit[4:0];
 wire rd_fire=rd_valid&&rd_ready;
 assign r_ready=state==READ&&error==0;
 assign beat_left=burst_left==0?lens[lhead]:burst_left;
 // Early-fill hazard guard: [A or B bytes of the next tile] vs [destination bytes of the queued tile].
 wire[33:0]a_lo={2'b0,ap},a_hi={2'b0,ap}+(ax==8?{22'b0,next_count,3'b0}:{23'b0,next_count,2'b0});
 wire[33:0]b_lo={2'b0,bp},b_hi={2'b0,bp}+(bx==0?34'd4:repeat_rhs?{23'b0,next_count,1'b0}:bx==8?{22'b0,next_count,3'b0}:{23'b0,next_count,2'b0});
 wire[8:0]qc=mcount[mhead];
 wire[33:0]d_lo={2'b0,mdp[mhead]},d_hi={2'b0,mdp[mhead]}+(format_shift==2?{23'b0,qc,2'b0}:format_shift==1?{24'b0,qc,1'b0}:{25'b0,qc});
 // BEGIN quantities registered in PRE.
 reg[8:0]next_count_q;reg[31:0]a_beats_q;reg[5:0]b_beats_q;reg[33:0]a_hi_q,b_hi_q;
 always @(posedge clk)if(state==PRE)begin
  next_count_q<=next_count;a_beats_q<=(a_words-(ax==8?1:0)+ap[4:2]+7)>>3;b_beats_q<=b_beats_next;a_hi_q<=a_hi;b_hi_q<=b_hi;
 end
 // These private payload registers need no reset: SELECT completes before BEGIN.
 // Keeping payload CE independent of remote ready/completion is deliberate.
 always @(posedge clk)begin
  if(state==CONTEXT)begin
   a_logical_q<=((a_sparse?{next_count_q,1'b0}:{1'b0,next_count_q})+10'd7)>>3;
   b_logical_q<=b_broadcast?6'd1:
      ((repeat_b?{2'b0,next_count_q[8:1]}:b_sparse?{next_count_q,1'b0}:{1'b0,next_count_q})+10'd7)>>3;
   b_prefix_q<=b_broadcast?3'b0:bp[4:2];
   walk_x<=x+next_count_q;walk_y<=y+1'b1;walk_z<=z+1'b1;
   x_ap<=ap+(a_sparse?{next_count_q,3'b0}:{next_count_q,2'b0});
   x_bp<=bp+(repeat_b?{next_count_q,1'b0}:b_broadcast?32'b0:b_sparse?{next_count_q,3'b0}:{next_count_q,2'b0});
   x_dp<=dp+(format_shift==2?{next_count_q,2'b0}:format_shift==1?{next_count_q,1'b0}:next_count_q);
   row_ap<=ar+ay;row_bp<=br+by;row_dp<=dr+dy;
   plane_ap<=apl+az;plane_bp<=bpl+bz;plane_dp<=dpl+dz;
  end
  if(state==SELECT)begin
   tile_last_q<=walk_x==nx&&walk_y==ny&&walk_z==nz;
   if(walk_x<nx)begin advance_kind<=0;next_ap<=x_ap;next_bp<=x_bp;next_dp<=x_dp;end
   else if(walk_y<ny)begin advance_kind<=1;next_ap<=row_ap;next_bp<=row_bp;next_dp<=row_dp;end
   else if(walk_z<nz)begin advance_kind<=2;next_ap<=plane_ap;next_bp<=plane_bp;next_dp<=plane_dp;end
   else begin advance_kind<=3;next_ap<=ap;next_bp<=bp;next_dp<=dp;end
  end
 end
 wire hazard=mused!=0&&((a_lo<d_hi&&d_lo<a_hi_q)||(need_b&&b_lo<d_hi&&d_lo<b_hi_q));
 wire can_begin=mused==0||(mused==1&&!hazard);
 // ---------------- tile RAMs ----------------
 reg[6:0]issue,out_index,slot;reg valid;
 wire[127:0]aout0,bout0,aout1,bout1;reg rslot;   // slot whose read data is on the RAM outputs
 reg[8:0]scount;reg[31:0]fragment_cursor;reg sactive,sdrain,spost;
 reg[8:0]vectors;   // c23: ceil(scount/4), loaded with scount
 wire issue_read=sactive&&!sdrain&&(!valid||feed_ready)&&issue<vectors&&error==0;
 graph_dual_input_tile tile0(.clk(clk),.we(tile_write&&mtail==0),.write_two(!stride_eight&&!broadcast_rhs),.wa(tile_wa),.lo(tile_data),.hi(aligned_word[255:128]),
  .re(issue_read&&mhead==0),.aa({1'b0,issue[5:0]}),.ba(b_broadcast?7'd64:repeat_b?{1'b1,1'b0,issue[5:1]}:{1'b1,issue[5:0]}),.aq(aout0),.bq(bout0));
 graph_dual_input_tile tile1(.clk(clk),.we(tile_write&&mtail==1),.write_two(!stride_eight&&!broadcast_rhs),.wa(tile_wa),.lo(tile_data),.hi(aligned_word[255:128]),
  .re(issue_read&&mhead==1),.aa({1'b0,issue[5:0]}),.ba(b_broadcast?7'd64:repeat_b?{1'b1,1'b0,issue[5:1]}:{1'b1,issue[5:0]}),.aq(aout1),.bq(bout1));
 wire[127:0]aout=rslot?aout1:aout0,bout=rslot?bout1:bout0;
 // ---------------- stream side ----------------
 assign feed_valid=valid&&error==0;assign feed_meta={23'b0,slot,2'b0};
 // PI: the current fragment is qualified at the same edge that installs
 // its cursor/left. No downstream ready participates in this range predicate.
 reg write_range;reg[4:0]fragment_bytes_q;
 reg[8:0]left;   // scount-4*out_index, declared before range functions use it.
 function[4:0]bytes_of(input[8:0]n,input[1:0]fmt);
  reg[2:0]v;begin v=n>=4?3'd4:n[2:0];
   bytes_of=fmt==2?{v,2'b0}:fmt==1?{1'b0,v,1'b0}:{2'b0,v};end
 endfunction
 function aligned(input[31:0]addr,input[1:0]fmt);
  begin aligned=fmt==0||(fmt==1?!addr[0]:addr[1:0]==0);end
 endfunction
 reg[8:0]pend_count;reg[31:0]pend_dp;reg pend_last;   // its metadata, captured before the walk advances
 reg[4:0]mbytes[0:1];reg mrange[0:1];
 wire[4:0]first_bytes=mbytes[mhead];
 wire[4:0]pend_bytes=bytes_of(pend_count,format_shift);
 wire[32:0]pend_end={1'b0,pend_dp}+pend_bytes;
 // Exact for every 9-bit left, including unsigned underflow on last use.
 // Avoid subtract -> saturate -> variable-format -> two 33-bit carry chains.
 wire[2:0]next_lanes=(|left[8:3])||!left[2]?3'd4:{1'b0,left[1:0]};
 wire[4:0]next_bytes=format_shift==2?{next_lanes,2'b0}:
                            format_shift==1?{1'b0,next_lanes,1'b0}:{2'b0,next_lanes};
 wire[5:0]two_fragment_bytes={1'b0,fragment_bytes_q}+{1'b0,next_bytes};
 // Adding at most 63 bytes can cross the 1 GiB bound only in its last 64 B.
 // Keep the inclusive end==bound and zero-byte bound case exactly intact.
 wire[6:0]end_low={1'b0,fragment_cursor[5:0]}+{1'b0,two_fragment_bytes};
 wire next_range=(fragment_cursor[31:30]==0&&
                     (!( &fragment_cursor[29:6])||end_low<=7'd64))||
                 (fragment_cursor==32'h40000000&&two_fragment_bytes==0);
 assign fragment_valid=result_valid&&sactive&&error==0&&write_range;
 assign result_ready=fragment_ready&&sactive&&error==0&&write_range;
 assign fragment_addr=fragment_cursor;
 reg[3:0]lane_off;   // c23: lanes slot*4+i>=scount of the issued slot
wire[2:0]lanes=left>=4?3'd4:left[2:0];
 assign fragment_bytes=fragment_bytes_q;
 assign fragment_last=(left<=4)&&mlast[mhead];
 assign posted_ready=spost&&error==0;
 wire tile_out_done=fragment_valid&&fragment_ready&&left<=4;
 wire push_tile;   // fill side completed a tile this cycle
 integer i;
 always @*begin
  feed_a=aout;feed_b=!need_b?{4{immediate}}:repeat_b?(slot[0]?{bout[127:96],bout[127:96],bout[95:64],bout[95:64]}:{bout[63:32],bout[63:32],bout[31:0],bout[31:0]}):bout;
  for(i=0;i<4;i=i+1)if(lane_off[i])begin feed_a[i*32+:32]=0;feed_b[i*32+:32]=0;end
 end
 reg fill_complete;   // operands of the tile in the fill slot are all written
 assign push_tile=fill_complete;
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;done<=0;error<=0;elements<=0;valid<=0;issue<=0;out_index<=0;slot<=0;rslot<=0;
   x<=0;y<=0;z<=0;ap<=0;bp<=0;dp<=0;ar<=0;br<=0;dr<=0;apl<=0;bpl<=0;dpl<=0;
   count<=0;a_sparse<=0;b_sparse<=0;b_broadcast<=0;current_logical<=0;repeat_b<=0;format_shift<=0;fragment_cursor<=0;read_b<=0;remaining<=0;offset<=0;burst_left<=0;
   req_left<=0;req_cursor<=0;lhead<=0;ltail<=0;lcount<=0;inflight<=0;req2_left<=0;req2_cursor<=0;req2_valid<=0;
   logical_offset<=0;prefix<=0;seen<=0;previous_word<=0;fill_complete<=0;pend_count<=0;pend_dp<=0;pend_last<=0;
   mhead<=0;mtail<=0;mused<=0;scount<=0;sactive<=0;sdrain<=0;spost<=0;vectors<=0;left<=0;lane_off<=4'hf;write_range<=0;fragment_bytes_q<=0;
   for(i=0;i<2;i=i+1)begin mcount[i]<=0;mdp[i]<=0;mlast[i]<=0;mbytes[i]<=0;mrange[i]<=0;end
  end else begin
   done<=0;fill_complete<=0;
   if(valid&&feed_ready)valid<=0;
   if(error==0)begin
    // ---- read requests (run ahead of the data) ----
    if(rd_fire)begin lens[ltail]<=rd_beats;ltail<=ltail+1'b1;
     if(req_left=={1'b0,rd_beats}&&req2_valid)begin req_left<=req2_left;req_cursor<=req2_cursor;req2_valid<=0;end
     else begin req_left<=req_left-rd_beats;req_cursor<=req_cursor+{rd_beats,5'b0};end
    end
    case({rd_fire,state==READ&&r_valid&&r_ready&&beat_left==1&&!r_error})
     2'b10:lcount<=lcount+1'b1;
     2'b01:lcount<=lcount-1'b1;
     default:begin end
    endcase
    if(state==READ&&r_valid&&r_ready&&beat_left==1&&!r_error)lhead<=lhead+1'b1;
    inflight<=inflight+(rd_fire?{2'b0,rd_beats}:7'd0)-((state==READ&&r_valid&&r_ready)?7'd1:7'd0);
    if(tile_write)logical_offset<=logical_offset+1'b1;
    if(accepted_word)begin previous_word<=r_data;seen<=1;end
    // ---- tile queue bookkeeping ----
    case({push_tile,tile_out_done})
     2'b10:mused<=mused+1'b1;
     2'b01:mused<=mused-1'b1;
     default:begin end
    endcase
    if(push_tile)begin mbytes[mtail]<=pend_bytes;mrange[mtail]<=pend_end<=33'h40000000&&aligned(pend_dp,format_shift);mcount[mtail]<=pend_count;mdp[mtail]<=pend_dp;mlast[mtail]<=pend_last;mtail<=!mtail;end
    // ---- stream side ----
    if(issue_read)begin slot<=issue;issue<=issue+1'b1;valid<=1;rslot<=mhead;
     for(i=0;i<4;i=i+1)lane_off[i]<=issue*4+i>=scount;
    end
    if(sactive&&!sdrain&&issue==vectors&&valid&&feed_ready)sdrain<=1;
    if(!sactive&&!spost&&mused!=0&&!push_tile)begin
     sactive<=1;sdrain<=0;scount<=mcount[mhead];fragment_cursor<=mdp[mhead];issue<=0;out_index<=0;
     vectors<=({1'b0,mcount[mhead]}+3)>>2;left<=mcount[mhead];
     fragment_bytes_q<=first_bytes;
     write_range<=mrange[mhead];
    end
    if(fragment_valid&&fragment_ready)begin
     if(result_meta!={23'b0,out_index,2'b0})error<=8'h36;
     elements<=elements+lanes;
     out_index<=out_index+1'b1;fragment_cursor<=fragment_cursor+fragment_bytes;left<=left-9'd4;
     fragment_bytes_q<=next_bytes;
     write_range<=next_range&&aligned(fragment_cursor,format_shift);
     if(left<=4)begin
      sactive<=0;sdrain<=0;mhead<=!mhead;
      if(mlast[mhead])spost<=1;
     end
    end
    if(spost&&posted_valid)begin spost<=0;done<=1;end
    // ---- fill side ----
    case(state)
     IDLE:if(start)begin a_sparse<=ax_p==8;b_sparse<=bx_p==8;b_broadcast<=bx_p==0;repeat_b<=repeat_rhs_p;format_shift<=bpe_p==4?2:bpe_p==2?1:0;x<=0;y<=0;z<=0;ap<=abase_p;bp<=bbase_p;dp<=dbase_p;ar<=abase_p;br<=bbase_p;dr<=dbase_p;apl<=abase_p;bpl<=bbase_p;dpl<=dbase_p;state<=PRE;
      nx<=nx_p;ny<=ny_p;nz<=nz_p;abase<=abase_p;bbase<=bbase_p;dbase<=dbase_p;ax<=ax_p;ay<=ay_p;az<=az_p;bx<=bx_p;by<=by_p;bz<=bz_p;dy<=dy_p;dz<=dz_p;immediate<=immediate_p;need_b<=need_b_p;repeat_rhs<=repeat_rhs_p;bpe<=bpe_p;
     end
     BEGIN:if(can_begin&&!push_tile)begin
      count<=next_count_q;current_logical<=a_logical_q;remaining<=a_beats_q;offset<=0;logical_offset<=0;seen<=0;prefix<=ap[4:2];read_b<=0;state<=REQ;
      req_left<=a_beats_q;req_cursor<={ap[31:5],5'b0};
      req2_valid<=need_b;req2_left<=b_beats_q;req2_cursor<={bp[31:5],5'b0};
      if((ax!=4&&ax!=8)||ap[1:0]!=0||ap>=32'h40000000||dp>=32'h40000000||(need_b&&(bp>=32'h40000000||bp[1:0]!=0)))error<=8'h31;
     end
     PRE:state<=CONTEXT;
     CONTEXT:state<=SELECT;
     SELECT:state<=BEGIN;
     REQ:if(range_bad_q)error<=8'h31;else state<=READ;
     READ:begin
      if(range_bad_q)error<=8'h31;
      else if(r_valid)begin
       if(r_error||lcount==0||r_last!=(beat_left==1))error<=8'h32;
       else begin
        offset<=offset+1'b1;remaining<=remaining-1'b1;burst_left<=beat_left-1'b1;
        if(remaining==1)begin
         if(logical_offset+(tile_write?1:0)<logical_words)state<=FLUSH;
         else state<=FINISH;
        end
       end
      end
     end
     FLUSH:state<=FINISH;
     FINISH:operand_done();
     FDONE:if(done)state<=IDLE;
     default:state<=IDLE;
    endcase
    if(result_valid&&sactive&&!write_range)error<=8'h33;
   end
  end
 end
 task operand_done;   // A finished -> read B (if any); B (or A without B) finished -> queue the tile
  begin
   if(!read_b&&need_b)begin
    read_b<=1;offset<=0;logical_offset<=0;seen<=0;prefix<=b_prefix_q;
    current_logical<=b_logical_q;remaining<=b_beats_q;state<=REQ;
   end else begin
    fill_complete<=1;pend_count<=count;pend_dp<=dp;pend_last<=tile_last_q;
    // Only commit precomputed context after the actual final read/flush edge.
    ap<=next_ap;bp<=next_bp;dp<=next_dp;
    case(advance_kind)
     0:begin x<=walk_x;state<=PRE;end
     1:begin x<=0;y<=walk_y;ar<=next_ap;br<=next_bp;dr<=next_dp;state<=PRE;end
     2:begin x<=0;y<=0;z<=walk_z;apl<=next_ap;bpl<=next_bp;dpl<=next_dp;
       ar<=next_ap;br<=next_bp;dr<=next_dp;state<=PRE;end
     default:state<=FDONE;
    endcase
   end
  end
 endtask
endmodule

// Both 128-bit ports write one 256-bit DDR beat during filling. During
// computation the same ports read A and B in parallel. Sparse stride-2 input
// is compacted while filling, so it never needs an extra RAM read port.
module graph_dual_input_tile(input wire clk,we,write_two,re,input wire[6:0]wa,aa,ba,
 input wire[127:0]lo,hi,output reg[127:0]aq,bq);
 reg[127:0]mem[0:127] /* synthesis syn_ramstyle="block_ram" */;
 wire[6:0]pa=we?wa:aa,pb=we?(wa+1'b1):ba;
 always @(posedge clk)if(we||re)begin if(we)mem[pa]<=lo;aq<=mem[pa];end
 always @(posedge clk)if((we&&write_two)||re)begin if(we&&write_two)mem[pb]<=hi;bq<=mem[pb];end
endmodule
