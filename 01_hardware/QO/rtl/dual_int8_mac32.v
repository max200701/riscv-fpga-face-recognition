// Exact INT32 extension with a directly maintained upper byte.
// Positive product: low 24-bit unsigned wrap iff sign changes 1->0.
// Negative product: unsigned borrow iff sign changes 0->1.
// Since each product magnitude is <2^23, these tests are sufficient.
// This avoids a second upper-byte sign-correction adder on the output path.
// Same four-edge latency, full partial results and K<=65535 contract.
module dual_int8_mac32 #(parameter PANGO_SIMD=1)(
    input wire clk,rst,valid,first,last,
    input wire signed [7:0] a0,b0,a1,b1,
    output reg out_valid,out_last,
    output reg signed [31:0] sum0,sum1
);
    wire bv,bl;wire signed[31:0]p0,p1;
    dual_int8_mac #(.PANGO_SIMD(PANGO_SIMD)) base(.clk(clk),.rst(rst),.valid(valid),
        .first(first),.last(last),.a0(a0),.b0(b0),.a1(a1),.b1(b1),
        .out_valid(bv),.out_last(bl),.sum0(p0),.sum1(p1));
    reg[2:0]fp,np0,np1;
    reg ps0,ps1;reg signed[7:0]high0,high1;
    wire carry0=(ps0!=np0[2])&&(ps0!=p0[23]);
    wire carry1=(ps1!=np1[2])&&(ps1!=p1[23]);
    wire signed[7:0]nh0=fp[2]?{8{p0[23]}}:high0+(carry0?(ps0?8'sd1:-8'sd1):8'sd0);
    wire signed[7:0]nh1=fp[2]?{8{p1[23]}}:high1+(carry1?(ps1?8'sd1:-8'sd1):8'sd0);
    always @(posedge clk)begin
        if(rst)begin
            fp<=0;np0<=0;np1<=0;ps0<=0;ps1<=0;high0<=0;high1<=0;
            out_valid<=0;out_last<=0;sum0<=0;sum1<=0;
        end else begin
            fp<={fp[1:0],first};np0<={np0[1:0],a0[7]^b0[7]};np1<={np1[1:0],a1[7]^b1[7]};
            out_valid<=bv;out_last<=bl;
            if(bv)begin
                ps0<=p0[23];ps1<=p1[23];high0<=nh0;high1<=nh1;
                sum0<={nh0,p0[23:0]};sum1<={nh1,p1[23:0]};
            end
        end
    end
endmodule
