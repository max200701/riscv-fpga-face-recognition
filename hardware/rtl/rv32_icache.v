`timescale 1ns/1ps
// Read-only instruction cache: two ways, 2**SET_BITS sets, eight words/line
// (SET_BITS=6: 4 KiB).
// A hit completes in one cycle; a miss blocks the CPU until the full line is
// refilled. Backend uses the same completion handshake as the CPU. No AXI burst
// claim: each refill word is a separate, stable valid/ready transaction.
module rv32_icache #(parameter TARGET_PAIR_FETCH=0, BURST_ENABLE=0, SET_BITS=8, DATA_BRAM=0) (
 input wire b_cmd_ready,b_valid,b_last,b_error,input wire [31:0] b_data,
 output wire b_cmd_valid,b_ready,output wire [31:0] b_addr,
 input wire clk,rst_n,c_valid,invalidate, input wire [31:0] c_addr,
 input wire [31:0] c_pair_addr,
 output wire c_ready, output wire [31:0] c_rdata, output wire c_error,
 output wire c_pair_valid, output wire [31:0] c_rdata1,
 output wire m_valid, output wire [31:0] m_addr,
 input wire m_ready, input wire [31:0] m_rdata, input wire m_error,
 output reg [31:0] hit_count,miss_count
);
 localparam IDLE=2'd0, FILL=2'd1, RESP=2'd2;
 reg [1:0] state;
 reg [31:0] saved_addr;
 reg burst_started;
 assign b_cmd_valid=rst_n && BURST_ENABLE && state==FILL && !burst_started;
 assign b_addr={saved_addr[31:5],5'b0};
 assign b_ready=rst_n && BURST_ENABLE && state==FILL && burst_started;
 wire refill_valid=BURST_ENABLE ? b_valid && b_ready : m_ready;
 wire refill_error=BURST_ENABLE ? b_error : m_error;
 wire [31:0] refill_data=BURST_ENABLE ? b_data : m_rdata;

 localparam SETS=1<<SET_BITS, TOP=SET_BITS+4, TW=27-SET_BITS;
 reg [31:0] data0[0:SETS*8-1], data1[0:SETS*8-1];
 reg [TW-1:0] tag0[0:SETS-1],tag1[0:SETS-1];
 reg [SETS-1:0] valid0,valid1,lru;
 wire [SET_BITS-1:0] c_set=c_addr[TOP:5];
 wire [SET_BITS+2:0] c_index=c_addr[TOP:2];
 wire hit0=valid0[c_set] && tag0[c_set]==c_addr[31:TOP+1];
 wire hit1=valid1[c_set] && tag1[c_set]==c_addr[31:TOP+1];
 reg fill_way,resp_error;
 reg [2:0] fill_word;
 wire [SET_BITS-1:0] saved_set=saved_addr[TOP:5];
 wire [SET_BITS+2:0] fill_index={saved_set,fill_word};
 // Exactly the data-array write condition of the FILL state below.
 wire refill_write=rst_n && !invalidate && state==FILL && refill_valid && !refill_error && !(BURST_ENABLE && resp_error);
 // A refill replay and an ordinary primary hit are mutually exclusive.
 // Share their physical asynchronous read port; keep the independent target
 // pair port, cache capacity, hit latency and refill semantics unchanged.
 wire [SET_BITS+2:0] primary_index=state==RESP ? saved_addr[TOP:2] : c_index;
 wire [31:0] primary_data0,primary_data1,second_data0,second_data1;
 assign c_ready=rst_n && c_valid && ((state==IDLE && (hit0 || hit1)) || state==RESP);
 assign c_rdata=(state==RESP ? fill_way : !hit0) ? primary_data1 : primary_data0;
 // Both words use full independent tags, including same-line and refill
 // responses. A second-address miss/misalignment only disables the second word:
 // no refill is launched and no exception is attached to the first word.
 wire [31:0] second_addr=TARGET_PAIR_FETCH ? c_pair_addr :
   (state==RESP ? saved_addr : c_addr)+32'd4;
 wire [SET_BITS+2:0] second_index=second_addr[TOP:2];
 wire [SET_BITS-1:0] second_set=second_addr[TOP:5];
 wire second_hit0=valid0[second_set] && tag0[second_set]==second_addr[31:TOP+1];
 wire second_hit1=valid1[second_set] && tag1[second_set]==second_addr[31:TOP+1];
 assign c_pair_valid=c_ready && !c_error && second_addr[1:0]==0 &&
   (second_hit0 || second_hit1);
 assign c_rdata1=second_hit0 ? second_data0 : second_data1;
 // claude_c02 c16 (enabled from fullgraph_core): DATA_BRAM=1 keeps the line data in four simple-dual-port block RAMs (way x read
 // port) instead of 4 x SETS*8 x 32 distributed RAM. Writes stay on the rising edge (same refill
 // timing); reads are clocked on the falling edge, so the addressed word is available for the rest of
 // the same CPU cycle: hits still complete in one cycle and the CPU cycle behaviour is unchanged.
 // Half-cycle paths (address -> falling edge, RAM -> rising edge) are timed by STA.
 generate if(DATA_BRAM)begin:bram
   reg [31:0] p0[0:SETS*8-1] /* synthesis syn_ramstyle="block_ram" */;
   reg [31:0] p1[0:SETS*8-1] /* synthesis syn_ramstyle="block_ram" */;
   reg [31:0] s0[0:SETS*8-1] /* synthesis syn_ramstyle="block_ram" */;
   reg [31:0] s1[0:SETS*8-1] /* synthesis syn_ramstyle="block_ram" */;
   reg [31:0] p0q,p1q,s0q,s1q;
   always @(posedge clk)if(refill_write)begin
     if(fill_way)begin p1[fill_index]<=refill_data;s1[fill_index]<=refill_data;end
     else begin p0[fill_index]<=refill_data;s0[fill_index]<=refill_data;end
   end
   always @(negedge clk)begin p0q<=p0[primary_index];p1q<=p1[primary_index];s0q<=s0[second_index];s1q<=s1[second_index];end
   assign primary_data0=p0q;assign primary_data1=p1q;assign second_data0=s0q;assign second_data1=s1q;
 end else begin:lutram
   assign primary_data0=data0[primary_index];assign primary_data1=data1[primary_index];
   assign second_data0=data0[second_index];assign second_data1=data1[second_index];
 end endgenerate
 assign c_error=state==RESP && resp_error;
 assign m_valid=rst_n && !BURST_ENABLE && state==FILL;
 assign m_addr={saved_addr[31:5],fill_word,2'b00};
 always @(posedge clk) begin
   if(!rst_n) begin
     state<=IDLE;burst_started<=0;valid0<=0;valid1<=0;lru<=0;
     saved_addr<=0;fill_word<=0;fill_way<=0;resp_error<=0;
     hit_count<=0;miss_count<=0;
   end else if(invalidate)begin
     // Core drains the outstanding fetch before asserting this pulse.
     // No backend transaction is cancelled; stale prefetched instructions
     // and BTB entries are flushed in the core on the same edge.
     valid0<=0;valid1<=0;lru<=0;
   end else case(state)
     IDLE: if(c_valid) begin
       if(hit0 || hit1) begin
         hit_count<=hit_count+1;
         lru[c_set]<=hit0; // next victim is the other way
       end else begin
         miss_count<=miss_count+1;
         saved_addr<=c_addr;fill_word<=0;resp_error<=0;
         if(!valid0[c_set]) begin fill_way<=0;valid0[c_set]<=0; end
         else if(!valid1[c_set]) begin fill_way<=1;valid1[c_set]<=0; end
         else begin
           fill_way<=lru[c_set];
           if(lru[c_set]) valid1[c_set]<=0;else valid0[c_set]<=0;
         end
         burst_started<=0;state<=FILL;
       end
     end
     FILL: begin
       if(b_cmd_valid && b_cmd_ready)burst_started<=1;
       if(refill_valid)begin
         if(BURST_ENABLE)begin
           // Finish/drain a burst before reporting errors. Never publish a partial line.
           if(refill_error || (b_last!=(fill_word==7)))resp_error<=1;
           if(!refill_error && !resp_error)begin
             if(fill_way)data1[fill_index]<=refill_data;else data0[fill_index]<=refill_data;
           end
           if(b_last)begin
             if(!refill_error && !resp_error && fill_word==7)begin
               if(fill_way)begin tag1[saved_set]<=saved_addr[31:TOP+1];valid1[saved_set]<=1;end
               else begin tag0[saved_set]<=saved_addr[31:TOP+1];valid0[saved_set]<=1;end
               lru[saved_set]<=!fill_way;
             end
             state<=RESP;
           end else if(fill_word!=7)fill_word<=fill_word+1'b1;
         end else if(refill_error)begin resp_error<=1;state<=RESP;end
         else begin
           if(fill_way)data1[fill_index]<=refill_data;else data0[fill_index]<=refill_data;
           if(fill_word==7)begin
             if(fill_way)begin tag1[saved_set]<=saved_addr[31:TOP+1];valid1[saved_set]<=1;end
             else begin tag0[saved_set]<=saved_addr[31:TOP+1];valid0[saved_set]<=1;end
             lru[saved_set]<=!fill_way;state<=RESP;
           end else fill_word<=fill_word+1'b1;
         end
       end
     end
     RESP: if(c_valid) state<=IDLE;
     default: state<=IDLE;
   endcase
 end
endmodule
