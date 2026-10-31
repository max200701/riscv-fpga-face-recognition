// Exact Q16 -> signed INT8/INT12, four lanes, eight elastic stages.
// PK: four registered unsigned 16x16 products, two exact recombination stages.
// This removes the unregistered four-APM 32x32 cascade; II remains one.
// Descriptor contract: 2^24 < d < 2^40, m=floor(2^56/d), m fits uint32,
// and zero_point is in the selected signed activation range.
// abs(x)*m >> 32 underestimates floor(abs(x)*2^24/d) by at most one.
// One residual correction and nearest-even rounding therefore suffice.
// Descriptor identity/CRC and m consistency are checked by the package loader.
module requant_stream4 #(
    parameter LANES=4, parameter FREE_RUNNING=0
)(
    input wire clk, rst,
    input wire in_valid, output wire in_ready,
    input wire [LANES*32-1:0] in_data,
    input wire [39:0] denominator,
    input wire [31:0] reciprocal,
    input wire signed [15:0] zero_point,
    input wire [4:0] activation_bits,
    input wire [31:0] in_meta,
    output wire out_valid, input wire out_ready,
    output wire [LANES*16-1:0] out_data,
    output wire [31:0] out_meta,
    output wire out_error
);
    reg [7:0] valid;
    reg [31:0] meta[0:7];
    wire advance=FREE_RUNNING || !valid[7] || out_ready;
    assign in_ready=advance;
    assign out_valid=valid[7];
    assign out_meta=meta[7];
    wire [LANES-1:0] error;
    assign out_error=|error;
    integer t;
    always @(posedge clk) begin
        if(rst) valid<=0;
        else if(advance) begin
            valid<={valid[6:0],in_valid};
            meta[0]<=in_meta;
            for(t=1;t<8;t=t+1) meta[t]<=meta[t-1];
        end
    end
    genvar lane;
    generate for(lane=0;lane<LANES;lane=lane+1) begin: g
        wire signed [31:0] x=in_data[lane*32+:32];
        reg [31:0] a0,m0;
        reg [31:0] pp00,pp01,pp10,pp11;
        reg [47:0] mul_lo,mul_hi;
        reg [55:0] num_pp,num_sum;
        reg [39:0] d_pp,d_sum;
        reg signed [15:0] z_pp,z_sum;
        reg [4:0] b_pp,b_sum;
        reg s_pp,s_sum,e_pp,e_sum;
        reg [39:0] d0,d1,d2,d3,d4;
        reg signed [15:0] z0,z1,z2,z3,z4;
        reg [4:0] b0,b1,b2,b3,b4;
        reg s0,s1,s2,s3,s4;
        reg e0,e1,e2,e3,e4,e5;
        reg [63:0] product1;
        reg [55:0] num1,num2,remainder3,remainder4;
        reg [51:0] estimate_product2;
        reg [12:0] quotient2,quotient3,quotient4;
        reg saturated2,saturated3,saturated4;
        reg signed [15:0] result5;
        wire [31:0] estimate1=product1[63:32];
        wire [56:0] twice4={remainder4,1'b0};
        wire round_up4=(twice4>{17'b0,d4}) || ((twice4=={17'b0,d4}) && quotient4[0]);
        wire [13:0] rounded4={1'b0,quotient4}+round_up4;
        wire signed [17:0] signed4=s4 ? -$signed({4'b0,rounded4}):$signed({4'b0,rounded4});
        wire signed [18:0] shifted4=$signed(signed4)+$signed(z4);
        wire signed [18:0] low4=(b4==12) ? -19'sd2048:-19'sd128;
        wire signed [18:0] high4=(b4==12) ? 19'sd2047:19'sd127;
        assign out_data[lane*16+:16]=result5;
        assign error[lane]=e5;
        always @(posedge clk) if(FREE_RUNNING || (!rst && advance)) begin
            a0<=x[31] ? (~x+32'd1):x;
            m0<=reciprocal;d0<=denominator;z0<=zero_point;
            b0<=activation_bits;s0<=x[31];
            e0<=denominator<=40'd16777216 || reciprocal==0 ||
                 (activation_bits!=8 && activation_bits!=12) ||
                 (activation_bits==8 && (zero_point < -16'sd128 || zero_point > 16'sd127)) ||
                 (activation_bits==12 && (zero_point < -16'sd2048 || zero_point > 16'sd2047));
            pp00<=a0[15:0]*m0[15:0];pp01<=a0[15:0]*m0[31:16];
            pp10<=a0[31:16]*m0[15:0];pp11<=a0[31:16]*m0[31:16];
            num_pp<={a0,24'b0};d_pp<=d0;z_pp<=z0;b_pp<=b0;s_pp<=s0;e_pp<=e0;
            mul_lo<={16'b0,pp00}+{pp01,16'b0};
            mul_hi<={16'b0,pp10}+{pp11,16'b0};
            num_sum<=num_pp;d_sum<=d_pp;z_sum<=z_pp;b_sum<=b_pp;s_sum<=s_pp;e_sum<=e_pp;
            product1<={16'b0,mul_lo}+{mul_hi,16'b0};num1<=num_sum;
            d1<=d_sum;z1<=z_sum;b1<=b_sum;s1<=s_sum;e1<=e_sum;
            estimate_product2<=estimate1[11:0]*d1;
            quotient2<={1'b0,estimate1[11:0]};
            saturated2<=estimate1>=32'd4096;num2<=num1;
            d2<=d1;z2<=z1;b2<=b1;s2<=s1;e2<=e1;
            remainder3<=num2-{4'b0,estimate_product2};
            quotient3<=quotient2;saturated3<=saturated2;
            d3<=d2;z3<=z2;b3<=b2;s3<=s2;
            e3<=e2 || (!saturated2 && {4'b0,estimate_product2}>num2);
            if(remainder3>={16'b0,d3}) begin
                remainder4<=remainder3-{16'b0,d3};
                quotient4<=quotient3+13'd1;
            end else begin
                remainder4<=remainder3;quotient4<=quotient3;
            end
            saturated4<=saturated3;d4<=d3;z4<=z3;b4<=b3;s4<=s3;
            e4<=e3 || (!saturated3 && remainder3>={15'b0,d3,1'b0});
            if(saturated4) result5<=s4 ? low4[15:0]:high4[15:0];
            else if(shifted4<low4) result5<=low4[15:0];
            else if(shifted4>high4) result5<=high4[15:0];
            else result5<=shifted4[15:0];
            e5<=e4;
        end
    end endgenerate
endmodule
