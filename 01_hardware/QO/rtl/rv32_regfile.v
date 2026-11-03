`timescale 1ns/1ps
// Two asynchronous read ports, one synchronous write port; x0 is immutable.
module rv32_regfile (
    input wire clk, input wire rst_n,
    input wire [4:0] rs1, rs2, rd,
    input wire we, input wire [31:0] wd,
    output wire [31:0] a, b
);
    reg [31:0] regs [0:31];
    integer i;
    assign a = (rs1 == 0) ? 32'b0 : regs[rs1];
    assign b = (rs2 == 0) ? 32'b0 : regs[rs2];
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i=0; i<32; i=i+1) regs[i] <= 0;
        end else if (we && rd != 0) regs[rd] <= wd;
    end
endmodule
