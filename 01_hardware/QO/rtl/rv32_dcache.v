`timescale 1ns/1ps
// 2 KiB, two ways, 32 sets, 32-byte lines. Blocking write-through cache.
// Writes do not allocate: acknowledge/update a hit only after backend success.
// MMIO bypasses all lookup/fill logic. There are no dirty lines to lose on reset.
module rv32_dcache #(parameter BURST_ENABLE=0)(
 input wire b_cmd_ready,b_valid,b_last,b_error,input wire [31:0] b_data,
 output wire b_cmd_valid,b_ready,output wire [31:0] b_addr,
 input wire clk,rst_n,c_valid,c_write,c_cacheable,
 input wire [31:0] c_addr,c_wdata,input wire [3:0] c_wstrb,
 output wire c_ready,output wire [31:0] c_rdata,output wire c_error,
 output wire m_valid,m_write,output wire [31:0] m_addr,m_wdata,
 output wire [3:0] m_wstrb,input wire m_ready,m_error,input wire [31:0] m_rdata,
 output reg [31:0] hit_count,miss_count
);
 localparam IDLE=0,FILL=1,RESP=2;
 reg [1:0] state;
 reg [31:0] saved_addr;
 reg burst_started;
 assign b_cmd_valid=rst_n && BURST_ENABLE && state==FILL && !burst_started;
 assign b_addr={saved_addr[31:5],5'b0};
 assign b_ready=rst_n && BURST_ENABLE && state==FILL && burst_started;
 wire refill_valid=BURST_ENABLE ? b_valid && b_ready : m_ready;
 wire refill_error=BURST_ENABLE ? b_error : m_error;
 wire [31:0] refill_data=BURST_ENABLE ? b_data : m_rdata;

 wire [31:0] read0,read1;
 reg [21:0] tag0[0:31],tag1[0:31];
 reg [31:0] valid0,valid1,lru;
 wire [4:0] set=c_addr[9:5];
 wire [7:0] index=c_addr[9:2];
 wire hit0=valid0[set] && tag0[set]==c_addr[31:10];
 wire hit1=valid1[set] && tag1[set]==c_addr[31:10];
 wire bypass=!c_cacheable || c_write;
 reg fill_way,resp_error;
 reg [2:0] word;
 wire [4:0] fill_set=saved_addr[9:5];
 wire [7:0] fill_index={fill_set,word};
 assign m_valid=rst_n && ((!BURST_ENABLE && state==FILL) || (state==IDLE && c_valid && bypass));
 assign m_write=state==IDLE && c_write;
 assign m_addr=state==FILL ? {saved_addr[31:5],word,2'b00} : c_addr;
 assign m_wdata=c_wdata;
 assign m_wstrb=state==FILL ? 4'b0 : c_wstrb;
 assign c_ready=rst_n && c_valid && (state==RESP ||
   (state==IDLE && (bypass ? m_ready : hit0 || hit1)));
 assign c_error=state==RESP ? resp_error : state==IDLE && bypass && m_error;
 assign c_rdata=state==RESP ? (fill_way ? read1 : read0) :
   bypass ? m_rdata : hit0 ? read0 : read1;
 // Merge refill and store-hit writes before memory inference: one address
 // and one write-enable per byte bank. This avoids a two-write-port FF fallback.
 wire fill_write=state==FILL && refill_valid && !refill_error && (!BURST_ENABLE || !resp_error);
 wire store_write=state==IDLE && c_valid && c_write && c_cacheable && m_ready && !m_error && (hit0 || hit1);
 wire write_way=fill_write ? fill_way : !hit0;
 wire [7:0] write_index=fill_write ? fill_index : index;
 wire [7:0] read_index=state==RESP ? saved_addr[9:2] : index;
 wire [31:0] write_data=fill_write ? refill_data : c_wdata;
 wire [3:0] write_mask=fill_write ? 4'b1111 : c_wstrb;
 genvar lane;
 generate for(lane=0;lane<4;lane=lane+1)begin: bytes
   reg [7:0] way0[0:255],way1[0:255];
   assign read0[lane*8+:8]=way0[read_index];
   assign read1[lane*8+:8]=way1[read_index];
   always @(posedge clk)if(rst_n && (fill_write || store_write) && write_mask[lane])begin
     if(!write_way)way0[write_index]<=write_data[lane*8+:8];
     else way1[write_index]<=write_data[lane*8+:8];
   end
 end endgenerate
 always @(posedge clk) begin
   if(!rst_n) begin
     state<=IDLE;burst_started<=0;valid0<=0;valid1<=0;lru<=0;hit_count<=0;miss_count<=0;
     saved_addr<=0;word<=0;fill_way<=0;resp_error<=0;
   end else case(state)
     IDLE: if(c_valid) begin
       if(bypass) begin
         if(c_write && c_cacheable && m_ready && !m_error && (hit0 || hit1)) begin
           lru[set]<=hit0;
         end
       end else if(hit0 || hit1) begin
         hit_count<=hit_count+1;lru[set]<=hit0;
       end else begin
         miss_count<=miss_count+1;saved_addr<=c_addr;word<=0;resp_error<=0;
         if(!valid0[set]) begin fill_way<=0;valid0[set]<=0;end
         else if(!valid1[set]) begin fill_way<=1;valid1[set]<=0;end
         else begin fill_way<=lru[set];if(lru[set])valid1[set]<=0;else valid0[set]<=0;end
         burst_started<=0;state<=FILL;
       end
     end
     FILL: begin
       if(b_cmd_valid && b_cmd_ready)burst_started<=1;
       if(refill_valid)begin
         if(BURST_ENABLE)begin
           // Finish/drain a burst before reporting errors. Never publish a partial line.
           if(refill_error || (b_last!=(word==7)))resp_error<=1;
           if(!refill_error && !resp_error)begin

           end
           if(b_last)begin
             if(!refill_error && !resp_error && word==7)begin
               if(fill_way)begin tag1[saved_addr[9:5]]<=saved_addr[31:10];valid1[saved_addr[9:5]]<=1;end
               else begin tag0[saved_addr[9:5]]<=saved_addr[31:10];valid0[saved_addr[9:5]]<=1;end
               lru[saved_addr[9:5]]<=!fill_way;
             end
             state<=RESP;
           end else if(word!=7)word<=word+1'b1;
         end else if(refill_error)begin resp_error<=1;state<=RESP;end
         else begin

           if(word==7)begin
             if(fill_way)begin tag1[saved_addr[9:5]]<=saved_addr[31:10];valid1[saved_addr[9:5]]<=1;end
             else begin tag0[saved_addr[9:5]]<=saved_addr[31:10];valid0[saved_addr[9:5]]<=1;end
             lru[saved_addr[9:5]]<=!fill_way;state<=RESP;
           end else word<=word+1'b1;
         end
       end
     end
     RESP: if(c_valid)state<=IDLE;
     default:state<=IDLE;
   endcase
 end
endmodule
