`timescale 1ns/1ps
// General RV32M execution unit. Registered operands/product keep multiplication
// out of the load-forward/EX path. Restoring division uses 32 iterations.
module rv32_muldiv(input wire clk,rst_n,start,input wire[2:0] op,
 input wire[31:0] a,b,output reg busy,done,output reg[31:0] result);
 localparam IDLE=0,MULTIPLY=1,MUL_RESULT=2,DIVIDE=3;
 reg[1:0] state;
 reg[2:0] operation;
 reg[31:0] mul_a,mul_b;
 reg[63:0] product;
 reg[31:0] dividend,divisor,quotient;
 reg[32:0] remainder;
 reg[5:0] step;
 reg negate_q,negate_r;
 // Aggressive candidate: multiplier includes EX forwarding in its timing path.
 wire[63:0] input_product=a*b;
 wire signed_div=!op[0];
 wire[32:0] trial={remainder[31:0],dividend[31]};
 wire subtract=trial>={1'b0,divisor};
 wire[32:0] next_rem=subtract ? trial-{1'b0,divisor} : trial;
 wire[31:0] next_q={quotient[30:0],subtract};
 wire[31:0] high_product=product[63:32]-
   ((operation==1 || operation==2) && mul_a[31] ? mul_b : 32'b0)-
   (operation==1 && mul_b[31] ? mul_a : 32'b0);
 always @(posedge clk)begin
   if(!rst_n)begin
     state<=IDLE;busy<=0;done<=0;result<=0;operation<=0;
     mul_a<=0;mul_b<=0;product<=0;dividend<=0;divisor<=0;quotient<=0;
     remainder<=0;step<=0;negate_q<=0;negate_r<=0;
   end else begin
     done<=0;
     case(state)
       IDLE:if(start)begin
         operation<=op;
         if(!op[2])begin
           mul_a<=a;mul_b<=b;product<=input_product;
           if(op==0)begin result<=input_product[31:0];done<=1;busy<=0;state<=IDLE;end
           else begin busy<=1;state<=MUL_RESULT;end
         end
         else if(b==0)begin result<=op[1] ? a : 32'hffffffff;done<=1;end
         else begin
           dividend<=signed_div && a[31] ? -a : a;
           divisor<=signed_div && b[31] ? -b : b;
           negate_q<=signed_div && (a[31]^b[31]);negate_r<=signed_div && a[31];
           quotient<=0;remainder<=0;step<=0;busy<=1;state<=DIVIDE;
         end
       end
       MUL_RESULT:begin result<=operation==0 ? product[31:0] : high_product;done<=1;busy<=0;state<=IDLE;end
       DIVIDE:begin
         dividend<=dividend<<1;remainder<=next_rem;quotient<=next_q;step<=step+1'b1;
         if(step==31)begin
           result<=operation[1] ? (negate_r ? -next_rem[31:0] : next_rem[31:0]) :
             (negate_q ? -next_q : next_q);
           done<=1;busy<=0;state<=IDLE;
         end
       end
     endcase
   end
 end
endmodule
