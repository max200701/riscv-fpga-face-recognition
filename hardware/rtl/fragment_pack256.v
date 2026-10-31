// Contiguous fragments within a 32-byte line -> masked 256-bit writes.
// A last flag terminates a tile. Completion means transport acceptance only;
// the system still needs its existing posted-write acknowledgement barrier.
// claude_c02 c20: a registered pre-stage computes the byte mask, the shifted 256-bit data/strobe and the
// fragment fault predicate; the merge stage (unchanged logic) starts at those registers. Same output
// stream and fault decisions, one cycle more latency.
module fragment_pack256(
 input wire clk,rst,
 input wire in_valid,output wire in_ready,
 input wire [31:0] in_addr,input wire [127:0] in_data,
 input wire [4:0] in_bytes,input wire in_last,input wire [31:0] in_tag,
 output reg out_valid,input wire out_ready,
 output reg [31:0] out_addr,output reg [255:0] out_data,
 output reg [31:0] out_strb,output reg out_last,output reg [31:0] out_tag,
 output reg fault
);
 reg used,pending,alast;
 reg [31:0] addr,mask,tag;
 reg [255:0] data;
 // PF: local elastic emission boundary. Wide payload enable depends only on
 // registered occupancy, never on same-line/error/last combinational decisions.
 reg emit_valid;
 reg [31:0] emit_addr,emit_strb,emit_tag;
 reg [255:0] emit_data;
 reg emit_last;
 wire out_space=!out_valid || out_ready;
 wire space=!emit_valid || out_space;
 // Byte predicates replace a wide variable shift/subtract mask carry chain.
 wire [15:0] byte_mask;wire[127:0] masked_data;
 genvar g;
 generate for(g=0;g<16;g=g+1)begin:byte_enable
  assign byte_mask[g]=in_bytes>g;
  assign masked_data[g*8+:8]=in_data[g*8+:8]&{8{byte_mask[g]}};
 end endgenerate
 // pre-stage registers
 reg qv,qbad,qlast;reg [26:0] qline;reg [31:0] qfm,qtag;reg [255:0] qfd;
 wire same=used && addr=={qline,5'b0};
 wire [31:0] nm=(same ? mask : 32'b0)|qfm;
 wire [255:0] nd=(same ? data : 256'b0)|qfd;
 wire take=qv && !fault && !pending && (!used || same || space);
 wire bad=qbad || (same&&(mask&qfm)!=0);
 wire emit_old=pending || (used&&!same);
 wire emit_event=!fault && ((pending&&space) ||
       (take&&!bad&&((used&&!same)||((qlast||&nm)&&space))));
 assign in_ready=!rst && !fault && (!qv || take);
 // Invalid payload can change. Occupied stages hold under backpressure;
 // valid/reset defines whether payload may be consumed. No payload reset.
 always @(posedge clk)begin
  if(space)begin
   emit_addr<=emit_old?addr:{qline,5'b0};
   emit_data<=emit_old?data:nd;
   emit_strb<=emit_old?mask:nm;
   emit_last<=emit_old?alast:qlast;
   emit_tag<=emit_old?tag:qtag;
  end
  if(out_space && emit_valid)begin
   out_addr<=emit_addr;out_data<=emit_data;out_strb<=emit_strb;
   out_last<=emit_last;out_tag<=emit_tag;
  end
  if(rst)begin emit_valid<=0;out_valid<=0;end
  else begin
   if(space)emit_valid<=emit_event;
   if(out_space)out_valid<=emit_valid;
  end
 end
 always @(posedge clk)begin
  if(rst)qv<=0;
  else if(in_valid&&in_ready)begin
   qv<=1;qline<=in_addr[31:5];qlast<=in_last;qtag<=in_tag;
   qfm<={16'b0,byte_mask}<<in_addr[4:0];
   qfd<={128'b0,masked_data}<<{in_addr[4:0],3'b0};
   qbad<=in_bytes==0 || in_bytes>16 || {1'b0,in_addr[4:0]}+in_bytes>32;
  end else if(take)qv<=0;
 end
 always @(posedge clk)begin
  if(rst)begin used<=0;pending<=0;fault<=0;end
  else begin
   if(!fault)begin
   if(pending&&space)begin
    used<=0;pending<=0;
   end
   if(take)begin
    if(qbad || (same&&(mask&qfm)!=0))fault<=1;
    else if(used&&!same)begin
     used<=1;addr<={qline,5'b0};mask<=qfm;data<=qfd;tag<=qtag;alast<=qlast;
     pending<=qlast || &qfm;
    end else if((qlast || &nm)&&space)begin
     used<=0;
    end else begin
     used<=1;addr<={qline,5'b0};mask<=nm;data<=nd;tag<=qtag;alast<=qlast;
     pending<=qlast || &nm;
    end
   end
   end
  end
 end
endmodule
