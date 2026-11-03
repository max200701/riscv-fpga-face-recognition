// Reserve a result slot BEFORE admission. Arithmetic never stops mid-pipeline.
// The FIFO is a local boundary buffer, NOT physical DDR completion or release.
// All descriptor parameters remain immutable until the enclosing command ends,
// as in the parent graph/tail engines. The arithmetic and rounding are unchanged.
module credit_math4 #(parameter LGDEPTH=4)(
 input wire clk,rst,in_valid,output wire in_ready,
 input wire[127:0]in_data,in_rhs,input wire[3:0]in_op,
 input wire signed[31:0]bn_bias,input wire[31:0]in_meta,
 input wire[39:0]denominator,input wire[31:0]reciprocal,
 input wire signed[15:0]zero_point,input wire[4:0]activation_bits,
 output wire out_valid,input wire out_ready,
 output wire[127:0]out_q16,output wire[63:0]out_quant,
 output wire[31:0]out_meta,output wire out_act_error,out_quant_error,
 output reg fault
);
 localparam DEPTH=1<<LGDEPTH;
 // PV: retain the same 21 admitted result credits at LGDEPTH=4.
 // Replace five shifting 226-bit front entries with two. The backing LUT RAM
 // grows from 16 to 32 logical words; PDS actual primitive usage is checked.
 // No extra DDR credit, no earlier ACK or release, no added arithmetic latency.
 localparam FRONT_SLOTS=2,CAPACITY=DEPTH+5;
 localparam RAM_LGDEPTH=$clog2(CAPACITY-FRONT_SLOTS);
 localparam RAM_DEPTH=1<<RAM_LGDEPTH;
 localparam COUNT_W=$clog2(CAPACITY+1);
 localparam WIDTH=226;
 reg[COUNT_W-1:0]outstanding,stored;
 reg[RAM_LGDEPTH-1:0]wp,rp;
 reg[1:0]front_count;
 reg[WIDTH-1:0]front[0:FRONT_SLOTS-1];
 reg[WIDTH-1:0]mem[0:RAM_DEPTH-1] /* synthesis syn_ramstyle="lut_ram" */;
 wire pop=out_valid&&out_ready;
 assign out_valid=(front_count!=0)&&!rst;
 assign in_ready=!rst&&!fault&&(outstanding<CAPACITY);
 wire accept=in_valid&&in_ready;
// PF: valid/credit alone authorizes consumption. FREE_RUNNING arithmetic
 // may evaluate invalid payload, but cannot publish it. Never route downstream
 // range/ready through a wide input-zero mux into arithmetic/ROM addresses.
 wire av,ae,qv,qe;wire[127:0]ad;wire[63:0]qd;wire[31:0]am,qm;
 graph_elementwise4 #(.FREE_RUNNING(1)) arithmetic(
  .clk(clk),.rst(rst),.in_valid(accept),.in_ready(),
  .in_data(in_data),.in_rhs(in_rhs),
  .in_op(in_op),.bn_bias(bn_bias),.in_meta(in_meta),
  .out_valid(av),.out_ready(1'b1),.out_data(ad),.out_meta(am),.out_error(ae));
 requant_stream4 #(.FREE_RUNNING(1)) requant(
  .clk(clk),.rst(rst),.in_valid(av),.in_ready(),.in_data(ad),
  .denominator(denominator),.reciprocal(reciprocal),.zero_point(zero_point),
  .activation_bits(activation_bits),.in_meta(am),
  .out_valid(qv),.out_ready(1'b1),.out_data(qd),.out_meta(qm),.out_error(qe));
 reg[127:0]wide[0:9];reg[9:0]errors;integer i;
 // Payload may change while invalid; valid/credits are reset, stale payload is
 // never consumed. There is no broadcast reset/CE on these payload registers.
 always @(posedge clk)begin
  wide[0]<=ad;errors<={errors[8:0],ae};
  for(i=1;i<10;i=i+1)wide[i]<=wide[i-1];
 end
 wire push=qv&&!rst;
 wire front_space=front_count<FRONT_SLOTS||pop;
 wire refill=!rst&&stored!=0&&front_space;
 // If no older RAM entry exists, retire directly into the existing front slot.
 // This removes an unnecessary RAM round trip, not physical DDR completion.
 wire bypass=push&&stored==0&&front_space;
 wire store_push=push&&!bypass;
 wire[WIDTH-1:0]payload={errors[9],qe,qm,qd,wide[9]};
 wire front_push=refill||bypass;
 wire[1:0]front_tail=front_count-{1'b0,pop};
 assign {out_act_error,out_quant_error,out_meta,out_quant,out_q16}=front[0];
 integer slot;
 always @(posedge clk)begin
  if(store_push)mem[wp]<=payload;
  if(pop)for(slot=0;slot<FRONT_SLOTS-1;slot=slot+1)front[slot]<=front[slot+1];
  if(front_push)front[front_tail]<=refill?mem[rp]:payload;
  if(rst)begin
   wp<=0;rp<=0;stored<=0;outstanding<=0;front_count<=0;fault<=0;
  end else begin
   case({accept,pop})
    2'b10:outstanding<=outstanding+1'b1;
    2'b01:outstanding<=outstanding-1'b1;
    default:;
   endcase
   case({store_push,refill})
    2'b10:stored<=stored+1'b1;
    2'b01:stored<=stored-1'b1;
    default:;
   endcase
   if(store_push)wp<=wp+1'b1;
   if(refill)rp<=rp+1'b1;
   case({front_push,pop})
    2'b10:front_count<=front_count+1'b1;
    2'b01:front_count<=front_count-1'b1;
    default:;
   endcase
   if((push&&outstanding==0)||(store_push&&stored==RAM_DEPTH&&!refill)||
      (pop&&outstanding==0)||outstanding>CAPACITY||stored>RAM_DEPTH||front_count>FRONT_SLOTS)fault<=1;
  end
 end
endmodule
