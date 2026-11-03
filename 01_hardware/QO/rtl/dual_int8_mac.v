// Mode-Z register aligns with product register; no additional latency.
// Two independent signed INT8 MACs. Every accepted product has three
// registered stages (operand, multiply, accumulate); no output backpressure.
// first starts a new dot product, including when batches are back-to-back.
// Contract: at most 256 products per dot; 24-bit partials are exact for INT8.
// Cross-K partial sums must be sign-extended and accumulated in INT32 outside.
module dual_int8_mac #(
    parameter PANGO_SIMD = 0
)(
    input wire clk, input wire rst,
    input wire valid, input wire first, input wire last,
    input wire signed [7:0] a0, b0, a1, b1,
    output reg out_valid, output reg out_last,
    output wire signed [31:0] sum0, sum1
);
    reg [1:0] vp, fp, lp;
    always @(posedge clk) begin
        if (rst) begin
            vp <= 0; fp <= 0; lp <= 0;
            out_valid <= 0; out_last <= 0;
        end else begin
            vp <= {vp[0],valid}; fp <= {fp[0],first}; lp <= {lp[0],last};
            out_valid <= vp[1]; out_last <= vp[1] && lp[1];
        end
    end
    generate if (PANGO_SIMD) begin: native
        wire [47:0] p;
        GTP_APM_E2 #(
            .GRS_EN("FALSE"), .USE_SIMD(1), .USE_MULT(1),
            .USE_POSTADD(1), .X_REG(1), .Y_REG(1),
            .MULT_REG(1), .P_REG(1), .MODEZ_REG(1), .ASYNC_RST(0)
        ) apm (
            .CLK(clk),
            .X({6'b0, {4{a1[7]}},a1, {4{a0[7]}},a0}),
            .Y({b1[7],b1,b0[7],b0}),
            .XB(25'b0), .CXI(30'b0), .CXBI(25'b0), .Z(48'b0),
            .CPI(48'b0), .CIN(1'b0),
            .MODEIN(5'b00010), .MODEY(3'b001),
            .MODEZ(fp[0] ? 4'b0000 : 4'b0001),
            .CEX1(valid), .CEX2(1'b0), .CEX3(1'b0), .CEXB(1'b0),
            .CEY1(valid), .CEY2(1'b0), .CEZ(1'b0), .CEPRE(1'b0),
            .CEM(vp[0]), .CEP(vp[1]),
            .CEMODEY(1'b0), .CEMODEZ(vp[0]), .CEMODEIN(1'b0),
            .RSTX(rst), .RSTXB(rst), .RSTY(rst), .RSTZ(rst),
            .RSTPRE(rst), .RSTM(rst), .RSTP(rst),
            .RSTMODEY(rst), .RSTMODEZ(rst), .RSTMODEIN(rst),
            .P(p), .CPO(), .COUT(), .CXO(), .CXBO()
        );
        assign sum0 = {{8{p[23]}},p[23:0]};
        assign sum1 = {{8{p[47]}},p[47:24]};
    end else begin: portable
        reg signed [7:0] ar0,br0,ar1,br1;
        reg signed [15:0] m0,m1;
        reg signed [23:0] s0,s1;
        always @(posedge clk) begin
            if (rst) begin
                ar0<=0; br0<=0; ar1<=0; br1<=0;
                m0<=0; m1<=0; s0<=0; s1<=0;
            end else begin
                if(valid) begin ar0<=a0; br0<=b0; ar1<=a1; br1<=b1; end
                if(vp[0]) begin m0<=ar0*br0; m1<=ar1*br1; end
                if(vp[1]) begin
                    s0 <= (fp[1] ? 24'sd0:s0) + {{8{m0[15]}},m0};
                    s1 <= (fp[1] ? 24'sd0:s1) + {{8{m1[15]}},m1};
                end
            end
        end
        assign sum0={{8{s0[23]}},s0};
        assign sum1={{8{s1[23]}},s1};
    end endgenerate
endmodule
