`timescale 1ns/1ps
// General RV32M execution unit. Registered operands/product keep multiplication
// out of the load-forward/EX path. Restoring division uses 32 iterations.
module rv32_muldiv(input wire clk,rst_n,start,input wire[2:0] op,
 input wire[31:0] a,b,output reg busy,done,output reg[31:0] result);
 localparam IDLE=0,MULTIPLY=1,MUL_RESULT=2,DIVIDE=3,DIV_PREP=4,MUL_JOIN=5,MUL_HIGH1=6,DIV_FINISH=7;
 reg[2:0] state;
 reg[2:0] operation;
 reg[31:0] mul_a,mul_b;
 reg[63:0] product;reg[31:0]p00,p01,p10,p11,high_adjust;
 wire[17:0]mid_sum={2'b0,p00[31:16]}+{2'b0,p01[15:0]}+{2'b0,p10[15:0]};
 reg[31:0] dividend,divisor,quotient;
 reg[32:0] remainder;
 reg[5:0] step;
 reg negate_q,negate_r;
 wire signed_div=!op[0];
 wire[32:0] trial={remainder[31:0],dividend[31]};
 wire subtract=trial>={1'b0,divisor};
 wire[32:0] next_rem=subtract ? trial-{1'b0,divisor} : trial;
 wire[31:0] next_q={quotient[30:0],subtract};
 wire [63:0] unsigned_product=mul_a*mul_b;
 wire[31:0] high_product=product[63:32]-
   ((operation==1 || operation==2) && mul_a[31] ? mul_b : 32'b0)-
   (operation==1 && mul_b[31] ? mul_a : 32'b0);
 always @(posedge clk)begin
   if(!rst_n)begin
     state<=IDLE;busy<=0;done<=0;result<=0;operation<=0;
     mul_a<=0;mul_b<=0;product<=0;p00<=0;p01<=0;p10<=0;p11<=0;high_adjust<=0;dividend<=0;divisor<=0;quotient<=0;
     remainder<=0;step<=0;negate_q<=0;negate_r<=0;
   end else begin
     done<=0;
     case(state)
       IDLE:if(start)begin
         operation<=op;
         if(!op[2])begin mul_a<=a;mul_b<=b;busy<=1;state<=MULTIPLY;end
         else if(b==0)begin result<=op[1] ? a : 32'hffffffff;done<=1;end
         else begin
           mul_a<=a;mul_b<=b;busy<=1;state<=DIV_PREP;
         end
       end
       MULTIPLY:begin
         // Four independent registered 16x16 products: no combinational APM cascade.
         p00<=mul_a[15:0]*mul_b[15:0];p01<=mul_a[15:0]*mul_b[31:16];
         p10<=mul_a[31:16]*mul_b[15:0];p11<=mul_a[31:16]*mul_b[31:16];state<=MUL_JOIN;
       end
       MUL_JOIN:begin
         product[31:0]<={mid_sum[15:0],p00[15:0]};
         product[63:32]<=p11+{16'b0,p01[31:16]}+{16'b0,p10[31:16]}+{30'b0,mid_sum[17:16]};
         if(operation==0)begin result<={mid_sum[15:0],p00[15:0]};done<=1;busy<=0;state<=IDLE;end
         else state<=MUL_HIGH1;
       end
       MUL_HIGH1:begin
         high_adjust<=product[63:32]-((operation==1 || operation==2) && mul_a[31] ? mul_b : 0);
         state<=MUL_RESULT;
       end
       MUL_RESULT:begin result<=high_adjust-(operation==1 && mul_b[31] ? mul_a : 0);done<=1;busy<=0;state<=IDLE;end
       // Share the registered operand bank with multiply. EX forwarding and
       // signed absolute-value carry chains no longer occur in one stage.
       DIV_PREP:begin
         dividend<=!operation[0] && mul_a[31] ? -mul_a : mul_a;
         divisor<=!operation[0] && mul_b[31] ? -mul_b : mul_b;
         negate_q<=!operation[0] && (mul_a[31]^mul_b[31]);
         negate_r<=!operation[0] && mul_a[31];
         quotient<=0;remainder<=0;step<=0;state<=DIVIDE;
       end
       DIVIDE:begin
         dividend<=dividend<<1;remainder<=next_rem;quotient<=next_q;step<=step+1'b1;
         if(step==31)state<=DIV_FINISH;
       end
       DIV_FINISH:begin
         result<=operation[1] ? (negate_r ? -remainder[31:0] : remainder[31:0]) : (negate_q ? -quotient : quotient);
         done<=1;busy<=0;state<=IDLE;
       end
     endcase
   end
 end
endmodule
