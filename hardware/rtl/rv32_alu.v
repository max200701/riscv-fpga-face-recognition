`timescale 1ns/1ps
module rv32_alu (
    input wire [31:0] a, b, input wire [3:0] op,
    output reg [31:0] y
);
    localparam ADD=0, SUB=1, SLL=2, SLT=3, SLTU=4,
               XOR_=5, SRL=6, SRA=7, OR_=8, AND_=9;
    always @* begin
        case(op)
            ADD: y = a + b;
            SUB: y = a - b;
            SLL: y = a << b[4:0];
            SLT: y = {31'b0, $signed(a) < $signed(b)};
            SLTU: y = {31'b0, a < b};
            XOR_: y = a ^ b;
            SRL: y = a >> b[4:0];
            SRA: y = $signed(a) >>> b[4:0];
            OR_: y = a | b;
            AND_: y = a & b;
            default: y = 0;
        endcase
    end
endmodule
