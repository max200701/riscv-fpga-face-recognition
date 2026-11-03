// Exact frozen Q16 graph arithmetic. Four lanes, six elastic stages.
// op: 0 identity, 1 add, 2 subtract, 3 multiply, 4 sigmoid,
//     5 SiLU (sigmoid then multiply), 6 PReLU, 7 square.
// Q16 LUT interpolation and all shifts use nearest-even rounding.
// ROM is not reset. Endpoint 8192 is the exact Q16 value 65536.
module elementwise_stream4 #(
    parameter LANES=4,
    parameter LUT_EVEN_FILE="sigmoid_even.hex",
    parameter LUT_ODD_FILE="sigmoid_odd.hex"
)(
    input wire clk,rst,
    input wire in_valid, output wire in_ready,
    input wire [LANES*32-1:0] in_data,in_rhs,
    input wire [2:0] in_op,
    input wire [31:0] in_meta,
    output wire out_valid,input wire out_ready,
    output wire [LANES*32-1:0] out_data,
    output wire [31:0] out_meta,
    output wire out_error
);
    // 7 elastic stages (the 32x33 multiply is split over stages 3 and 3b).
    reg [6:0] valid;
    reg [31:0] meta[0:6];
    wire advance=!valid[6] || out_ready;
    assign in_ready=advance;assign out_valid=valid[6];assign out_meta=meta[6];
    wire [LANES-1:0] errors;assign out_error=|errors;
    integer stage;
    always @(posedge clk) begin
        if(rst) valid<=0;
        else if(advance) begin
            valid<={valid[5:0],in_valid};meta[0]<=in_meta;
            for(stage=1;stage<7;stage=stage+1)meta[stage]<=meta[stage-1];
        end
    end
    function signed [63:0] nearest16;
        input signed [63:0] value;
        reg signed [63:0] floor_value;
        begin
            floor_value=value>>>16;
            nearest16=floor_value+((value[15:0]>16'h8000) ||
                 ((value[15:0]==16'h8000) && floor_value[0]));
        end
    endfunction
    genvar lane;
    generate for(lane=0;lane<LANES;lane=lane+1) begin:g
        // Neighboring entries always lie in different banks. One synchronous
        // read per bank avoids replication for two arbitrary ROM read ports.
        reg [16:0] rom_even[0:4095];
        reg [16:0] rom_odd[0:4095];
        initial begin
            $readmemh(LUT_EVEN_FILE,rom_even);
            $readmemh(LUT_ODD_FILE,rom_odd);
        end
        wire signed [31:0] x=in_data[lane*32+:32];
        wire signed [31:0] rhs=in_rhs[lane*32+:32];
        wire signed [31:0] clipped=x < -32'sd1048576 ? -32'sd1048576 :
              (x > 32'sd1048576 ? 32'sd1048576:x);
        wire [21:0] offset=clipped+32'sd1048576;
        wire [13:0] index=offset[21:8];
        wire [11:0] even_address=index[12:1]+index[0];
        reg [16:0] even0,odd0,base1,sigmoid2;
        reg parity0,lo_endpoint0,hi_endpoint0;
        wire [16:0] lo0=lo_endpoint0 ? 17'd65536:(parity0 ? odd0:even0);
        wire [16:0] hi0=hi_endpoint0 ? 17'd65536:(parity0 ? even0:odd0);
        reg [7:0] frac0;
        reg [24:0] interpolation1;
        wire [17:0] increment1={1'b0,interpolation1[24:8]}+
            ((interpolation1[7:0]>8'h80)||((interpolation1[7:0]==8'h80)&&interpolation1[8]));
        reg signed [31:0] x0,x1,x2,r0,r1,r2;
        reg [2:0] op0,op1,op2,op3,op3b,op4;
        reg signed [32:0] linear3,linear3b,linear4;
        reg signed [63:0] product3b,rounded4;
        reg signed [48:0] plo3,phi3;   // x*b_lo, x*b_hi (c18)
        reg signed [32:0] mb;   // c20: registered multiplicand (stage 2)
        wire [16:0] sigmoid_next=base1+increment1;
        wire signed [16:0] mb_hi=mb[32:16];
        wire [15:0] mb_lo=mb[15:0];
        reg signed [31:0] result5;
        reg error5;
        assign out_data[lane*32+:32]=result5;
        assign errors[lane]=error5;
        always @(posedge clk) if(!rst && advance) begin
            even0<=rom_even[even_address];odd0<=rom_odd[index[12:1]];
            parity0<=index[0];lo_endpoint0<=index>=14'd8192;hi_endpoint0<=index>=14'd8191;
            frac0<=offset[7:0];x0<=x;r0<=rhs;op0<=in_op;
            interpolation1<=(hi0-lo0)*frac0;base1<=lo0;
            x1<=x0;r1<=r0;op1<=op0;
            sigmoid2<=sigmoid_next;
            mb<=op1==5 ? $signed({16'b0,sigmoid_next}) : op1==7 ? $signed({x1[31],x1}) : $signed({r1[31],r1});
            x2<=x1;r2<=r1;op2<=op1;
            case(op2)
                1:linear3<=$signed({x2[31],x2})+$signed({r2[31],r2});
                2:linear3<=$signed({x2[31],x2})-$signed({r2[31],r2});
                4:linear3<={16'b0,sigmoid2};
                default:linear3<={x2[31],x2};
            endcase
            plo3<=x2*$signed({1'b0,mb_lo});phi3<=x2*mb_hi;
            product3b<=($signed({{15{phi3[48]}},phi3})<<<16)+$signed({{15{plo3[48]}},plo3});linear3b<=linear3;op3b<=op3;
            op3<=op2==6 && !x2[31] ? 3'd0:op2;
            rounded4<=nearest16(product3b);linear4<=linear3b;op4<=op3b;
            if(op4==3 || op4==5 || op4==6 || op4==7)begin
                result5<=rounded4[31:0];
                error5<=rounded4 < -64'sd2147483648 || rounded4 > 64'sd2147483647;
            end else begin
                result5<=linear4[31:0];error5<=linear4[32]!=linear4[31];
            end
        end
    end endgenerate
endmodule
