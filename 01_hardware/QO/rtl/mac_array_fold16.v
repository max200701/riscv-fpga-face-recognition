// Physical 32x16 array, logical 32x32 tile by replaying the resident panels.
// RB2: result banks are per-cluster block RAM (was 256 RAM32X2DP).
// A snapshot bank owns both halves until the caller publishes the entire tile.
// Each local 4x4 cluster uses eight SIMD APMs; 32 clusters -> 256 APMs.
// The two logical column halves share the same physical snapshot RAM ports.
// Row-major 16-element output ABI is unchanged. One local address stage makes
// the read latency four clocks; panel_compute delays its metadata accordingly.
// the PEs are the bare SIMD APM accumulators (24-bit lanes, exact
// for dots of at most 511 INT8 products; panel_compute splits longer K into chunks
// that the INT32 partial-sum store adds exactly). The per-PE 32-bit extension
// registers (sum/high/carry tracking, ~70 FF per PE) are gone; result banks and
// the read path carry 24-bit lanes, sign-extended later.
// a read returns one 4-lane phase (rd_index {row[4:0],half,phase}),
// the rate the quantizer consumes. Only cluster (row/4, phase) reads its bank; the
// gather is a 4:1 select inside each row cluster then an 8:1 select (96 bits),
// replacing the 8 x 384-bit snapshot registers. Read latency is still four clocks.
module mac_array_fold16 #(parameter ROW_GROUPS=4, PANGO_SIMD=1)(
 input wire clk,rst,in_valid,in_first,in_last,capture_bank,capture_half,
 input wire [ROW_GROUPS*64-1:0] rows,input wire [255:0] columns,
 output wire done,
 input wire rd_valid,rd_bank,input wire [7:0] rd_index,
 output reg result_valid,output reg [95:0] result,
 output reg [7:0] result_index
);
 localparam RC=ROW_GROUPS*2;
 wire [95:0] local_read[0:RC*4-1];
 wire [RC*4-1:0] complete;
 genvar g,h,r,c;
 // the logical column half is selected once here (same cycle, same value), so each
 // column-cluster broadcast is 32 bits to 8 row clusters instead of 64 bits with a mux in every cluster.
 wire[127:0]half_columns=capture_half?columns[255:128]:columns[127:0];
 generate for(g=0;g<RC;g=g+1)begin:row_cluster
  for(h=0;h<4;h=h+1)begin:col_cluster
   reg[31:0]aq /* synthesis syn_preserve=1 syn_maxfan=16 */;
   reg[31:0]bq /* synthesis syn_preserve=1 syn_maxfan=16 */;
   reg vq,fq,lq,rq /* synthesis syn_preserve=1 */;
   reg capture_bank_q,capture_half_q /* synthesis syn_preserve=1 syn_keep=1 */;
   reg read_valid_q,read_bank_q,read_half_q /* synthesis syn_preserve=1 syn_keep=1 */;
   reg[1:0]read_row_q /* synthesis syn_preserve=1 syn_keep=1 */;
   always @(posedge clk)begin
    rq<=rst;
    if(rst)begin
     capture_bank_q<=0;capture_half_q<=0;read_valid_q<=0;
     read_bank_q<=0;read_half_q<=0;read_row_q<=0;
    end else begin
     // Tags belong to the dot, not to a later global controller transition.
     if(in_valid&&in_first)begin capture_bank_q<=capture_bank;capture_half_q<=capture_half;end
     read_valid_q<=rd_valid&&(rd_index[7:5]==g)&&(rd_index[1:0]==h);
     // Only the selected row group consumes this address next cycle. A
     // real local enable also prevents ADS reducing all read tags to a
     // single unconditional global register. No read-valid latency changes.
     if(rd_valid&&(rd_index[7:5]==g)&&(rd_index[1:0]==h))begin
      read_bank_q<=rd_bank;read_half_q<=rd_index[2];read_row_q<=rd_index[4:3];
     end
    end
    if(rst)begin vq<=0;fq<=0;lq<=0;end
    else begin vq<=in_valid;fq<=in_first;lq<=in_last;end
    // c17: operands captured every cycle (no clock enable, no reset): the PEs load them only under vq.
    aq<=rows[32*g+:32];
    bq<=half_columns[32*h+:32];
   end
   wire[31:0]sx[0:15];wire[23:0]sums[0:15];wire[7:0]ov,ol;
   for(r=0;r<4;r=r+1)begin:row
    for(c=0;c<2;c=c+1)begin:pair
     dual_int8_mac #(.PANGO_SIMD(PANGO_SIMD)) pe(
      .clk(clk),.rst(rq),.valid(vq),.first(fq),.last(lq),
      .a0(aq[8*r+:8]),.a1(aq[8*r+:8]),
      .b0(bq[16*c+:8]),.b1(bq[16*c+8+:8]),
      .out_valid(ov[r*2+c]),.out_last(ol[r*2+c]),
      .sum0(sx[r*4+c*2]),.sum1(sx[r*4+c*2+1]));
     assign sums[r*4+c*2]=sx[r*4+c*2][23:0];assign sums[r*4+c*2+1]=sx[r*4+c*2+1][23:0];
    end
   end
   assign complete[g*4+h]=ol[0];
   // one 16x96 block RAM per cluster, entry {bank,half,row} =
   // sums[4*row+:4]. Row 0 is written on the capture edge; rows 1..3 on the next
   // three edges, straight from the APM accumulators (P holds while no product is
   // valid). panel_compute starts the next dot only after array_done, and its first
   // accumulator update lands >= 7 edges later (asserted in simulation below).
   reg drain_act;reg[1:0]drain_row;reg[1:0]drain_tag;
   wire drain_we=!rst&&(ol[0]||drain_act);
   wire[3:0]waddr=ol[0]?{capture_bank_q,capture_half_q,2'd0}:{drain_tag,drain_row};
   wire[95:0]wdata=ol[0]?{sums[3],sums[2],sums[1],sums[0]}:drain_row==2'd1 ? {sums[7],sums[6],sums[5],sums[4]}:
    drain_row==2'd2 ? {sums[11],sums[10],sums[9],sums[8]}:{sums[15],sums[14],sums[13],sums[12]};
   wire[95:0]read_q;
   always @(posedge clk)begin
    if(rst)begin drain_act<=0;drain_row<=0;end
    else if(ol[0])begin drain_act<=1;drain_row<=1;end
    else if(drain_act)begin drain_row<=drain_row+1'b1;if(drain_row==3)drain_act<=0;end
    if(ol[0])drain_tag<={capture_bank_q,capture_half_q};
   end
   // PX: per-cluster physical memory choice; exact ports and read clocks retained.
   if((g*4+h)==2 || (g*4+h)==3 || (g*4+h)==4 || (g*4+h)==5 || (g*4+h)==6 || (g*4+h)==10 || (g*4+h)==15 || (g*4+h)==18 || (g*4+h)==19 || (g*4+h)==22)begin: snapshot_block
    reg[95:0]mem[0:15] /* synthesis syn_ramstyle="block_ram" */;
    reg[95:0]q;
    always @(posedge clk)begin
     if(drain_we)mem[waddr]<=wdata;
     if(read_valid_q)q<=mem[{read_bank_q,read_half_q,read_row_q}];
    end
    assign read_q=q;
   end else begin: snapshot_local
    reg[95:0]mem[0:15] /* synthesis syn_ramstyle="lut_ram" */;
    reg[95:0]q;
    always @(posedge clk)begin
     if(drain_we)mem[waddr]<=wdata;
     if(read_valid_q)q<=mem[{read_bank_q,read_half_q,read_row_q}];
    end
    assign read_q=q;
   end
   // synthesis translate_off
   always @(posedge clk)if(!rst&&ol[0]&&drain_act)$display("MAC_ARRAY_DRAIN_OVERLAP %m %0t",$time);
   always @(posedge clk)if(!rst&&drain_act&&(|ov))$display("MAC_ARRAY_DRAIN_SUM_UPDATE %m %0t",$time);
   // synthesis translate_on
   assign local_read[g*4+h]=read_q;
  end
 end endgenerate
 assign done=!rst&&complete[0];
 // QF: decode at the existing address pipeline boundary. Each 24-bit lane
 // sees its own one-hot choice; each row produces zero when not selected.
 // The final result is a reduction, not a central idx2-controlled 96-bit MUX.
 // Original four-edge latency, one request/edge and all external tags remain.
 wire[95:0]phase_read[0:RC-1];
 reg[2:0]vp;reg[7:0]idx0,idx1,idx2;
 genvar qr,ql;
 generate for(qr=0;qr<RC;qr=qr+1)begin:collect_row
  for(ql=0;ql<4;ql=ql+1)begin:lane
   (* syn_preserve=1 *) reg[3:0]select_q;
   reg[23:0]value;
   always @(posedge clk)begin
    select_q<={idx0[7:5]==qr&&idx0[1:0]==3,
               idx0[7:5]==qr&&idx0[1:0]==2,
               idx0[7:5]==qr&&idx0[1:0]==1,
               idx0[7:5]==qr&&idx0[1:0]==0};
    // Intermediate data is observed only under delayed vp[2].
    // Keep the data register running; valid/reset remain in the output stage.
    value<=
      ({24{select_q[0]}}&local_read[qr*4+0][ql*24+:24])|
      ({24{select_q[1]}}&local_read[qr*4+1][ql*24+:24])|
      ({24{select_q[2]}}&local_read[qr*4+2][ql*24+:24])|
      ({24{select_q[3]}}&local_read[qr*4+3][ql*24+:24]);
   end
   assign phase_read[qr][ql*24+:24]=value;
  end
 end endgenerate
 integer q;reg[95:0]collected;
 always @*begin
  collected=96'b0;
  for(q=0;q<RC;q=q+1)collected=collected|phase_read[q];
 end
 always @(posedge clk)begin
  if(rst)begin
   vp<=0;result_valid<=0;result<=0;idx0<=0;idx1<=0;idx2<=0;result_index<=0;
  end else begin
   vp<={vp[1:0],rd_valid};result_valid<=vp[2];
   idx0<=rd_index;idx1<=idx0;idx2<=idx1;
   if(vp[2])begin result<=collected;result_index<=idx2;end
  end
 end
endmodule
