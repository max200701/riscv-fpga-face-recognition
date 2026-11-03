// 32 (or 40) rows x 32 columns, two INT8 MACs/APM, exact INT32.
// 4x4 local clusters limit operand fanout. Two completed-result snapshots
// separate compute from draining. Caller reserves a free capture bank before
// starting a dot and must not overwrite a bank still owned by the consumer.
// Read 16 INT32 elements/cycle; row-major halves. Three registered read stages.
module mac_array_snapshot #(parameter ROW_GROUPS=4, PANGO_SIMD=1)(
 input wire clk,rst,in_valid,in_first,in_last,capture_bank,
 input wire [ROW_GROUPS*64-1:0] rows,input wire [255:0] columns,
 output wire done,
 input wire rd_valid,rd_bank,input wire [6:0] rd_index,
 output reg result_valid,output reg [511:0] result,
 output reg [6:0] result_index
);
 localparam RC=ROW_GROUPS*2;
 wire [127:0] local_read[0:RC*8-1];
 wire [RC*8-1:0] complete;
 genvar g,h,r,c;
 generate for(g=0;g<RC;g=g+1)begin:row_cluster
  for(h=0;h<8;h=h+1)begin:col_cluster
   reg [31:0] aq /* synthesis syn_preserve=1 syn_maxfan=16 */;
   reg [31:0] bq /* synthesis syn_preserve=1 syn_maxfan=16 */;
   reg vq,fq,lq,rq /* synthesis syn_preserve=1 */;
   always @(posedge clk)begin
    rq<=rst;
    if(rst)begin vq<=0;fq<=0;lq<=0;aq<=0;bq<=0;end
    else begin
     vq<=in_valid;fq<=in_first;lq<=in_last;
     if(in_valid)begin aq<=rows[32*g+:32];bq<=columns[32*h+:32];end
    end
   end
   wire [31:0] sums[0:15];wire[7:0]ov,ol;
   for(r=0;r<4;r=r+1)begin:row
    for(c=0;c<2;c=c+1)begin:pair
     dual_int8_mac32 #(.PANGO_SIMD(PANGO_SIMD)) pe(
      .clk(clk),.rst(rq),.valid(vq),.first(fq),.last(lq),
      .a0(aq[8*r+:8]),.a1(aq[8*r+:8]),.b0(bq[16*c+:8]),.b1(bq[16*c+8+:8]),
      .out_valid(ov[r*2+c]),.out_last(ol[r*2+c]),
      .sum0(sums[r*4+c*2]),.sum1(sums[r*4+c*2+1]));
    end
   end
   assign complete[g*8+h]=ol[0];
   wire[127:0]qr;
   if(1)begin:ram_snapshot
    wire[511:0]bank_read;
    genvar word_i,bit_pair;
    for(word_i=0;word_i<16;word_i=word_i+1)begin:word_bank
     for(bit_pair=0;bit_pair<16;bit_pair=bit_pair+1)begin:bits
      GTP_RAM32X2DP mem(.WCLK(clk),.WE(!rst&&ol[0]),
       .WADDR({4'b0,capture_bank}),.DI(sums[word_i][2*bit_pair+:2]),
       .RADDR({4'b0,rd_bank}),.DO(bank_read[32*word_i+2*bit_pair+:2]));
     end
    end
    reg[127:0]read_q;integer i;
    always @(posedge clk)if(rd_valid)for(i=0;i<4;i=i+1)
     read_q[32*i+:32]<=bank_read[32*(rd_index[2:1]*4+i)+:32];
    assign qr=read_q;
   end else begin:ff_snapshot
    reg [31:0] snap0[0:15],snap1[0:15];
    reg [127:0] read_q;integer i;
    always @(posedge clk)begin
     if(!rst&&ol[0])for(i=0;i<16;i=i+1)
      if(capture_bank)snap1[i]<=sums[i];else snap0[i]<=sums[i];
     if(rd_valid)for(i=0;i<4;i=i+1)
      read_q[32*i+:32]<=rd_bank?snap1[rd_index[2:1]*4+i]:snap0[rd_index[2:1]*4+i];
    end
    assign qr=read_q;
   end
   assign local_read[g*8+h]=qr;
  end
 end endgenerate
 assign done=!rst&&complete[0];
 reg[511:0] cluster_read[0:RC-1];
 reg[1:0]vp;reg half;reg[3:0]row0,row1;
 reg[6:0]idx0,idx1;integer q;
 always @(posedge clk)begin
  if(rst)begin vp<=0;result_valid<=0;result<=0;half<=0;row0<=0;row1<=0;idx0<=0;idx1<=0;result_index<=0;end
  else begin
   vp<={vp[0],rd_valid};result_valid<=vp[1];
   half<=rd_index[0];row0<=rd_index[6:3];row1<=row0;idx0<=rd_index;idx1<=idx0;
   if(vp[0])for(q=0;q<RC;q=q+1)
    cluster_read[q]<={local_read[q*8+half*4+3],local_read[q*8+half*4+2],local_read[q*8+half*4+1],local_read[q*8+half*4]};
   if(vp[1])begin result<=(row1<RC)?cluster_read[row1]:512'b0;result_index<=idx1;end
  end
 end
endmodule
