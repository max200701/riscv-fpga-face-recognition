// Common asynchronous assertion, synchronous release in EACH domain.
// Reset flushes both sides. Do not reset one endpoint independently.
// Gray pointer synchronizers require physical CDC/skew constraints at integration.
// Read prefetch is registered (dual-clock RAM inference); output adds one slot.
module joint_async_fifo #(parameter WIDTH=32, parameter LGDEPTH=4, parameter OUTPUT_PIPE=0)(
    input wire arst,
    input wire wclk, input wire w_valid, output wire w_ready,
    input wire [WIDTH-1:0] w_data, output wire [LGDEPTH:0] w_used,
    input wire rclk, output wire r_valid, input wire r_ready,
    output wire [WIDTH-1:0] r_data
);
    reg [WIDTH-1:0] mem [0:(1<<LGDEPTH)-1] /* synthesis syn_ramstyle="block_ram" */;
    reg [LGDEPTH:0] wb, wg, rb, rg;
    (* ASYNC_REG="TRUE" *) reg [LGDEPTH:0] rg1,rg2,wg1,wg2;
    (* ASYNC_REG="TRUE" *) reg [1:0] wrst,rrst;
    always @(posedge wclk or posedge arst) if(arst)wrst<=3;else wrst<={wrst[0],1'b0};
    always @(posedge rclk or posedge arst) if(arst)rrst<=3;else rrst<={rrst[0],1'b0};
    function [LGDEPTH:0] ungray(input [LGDEPTH:0] g);
        integer j;begin ungray[LGDEPTH]=g[LGDEPTH];
            for(j=LGDEPTH-1;j>=0;j=j-1)ungray[j]=ungray[j+1]^g[j];
        end
    endfunction
    reg raw_valid;reg[WIDTH-1:0]raw_data;wire raw_ready;
    generate if(OUTPUT_PIPE)begin:output_pipe
      reg valid;reg[WIDTH-1:0]data;
      assign raw_ready=!valid||r_ready;
      assign r_valid=valid;assign r_data=data;
      always @(posedge rclk)if(raw_ready&&raw_valid)data<=raw_data;
      always @(posedge rclk or posedge arst)begin
        if(arst)valid<=0;else if(rrst[1])valid<=0;
        else if(raw_ready)valid<=raw_valid;
      end
    end else begin:no_output_pipe
      assign r_valid=raw_valid;assign r_data=raw_data;assign raw_ready=r_ready;
    end endgenerate
    assign w_used=wb-ungray(rg2);
    assign w_ready=(!wrst[1])&&(w_used<((1<<LGDEPTH)-OUTPUT_PIPE));
    wire fetch=(!rrst[1])&&(!raw_valid||raw_ready)&&(rg!=wg2);
    wire [LGDEPTH:0] wn=wb+1'b1,rn=rb+1'b1;
    always @(posedge wclk or posedge arst) begin
        if(arst)begin wb<=0;wg<=0;rg1<=0;rg2<=0;end
        else if(wrst[1])begin wb<=0;wg<=0;rg1<=0;rg2<=0;end
        else begin
            rg1<=rg;rg2<=rg1;
            if(w_valid&&w_ready)begin wb<=wn;wg<=(wn>>1)^wn;end
        end
    end
    always @(posedge wclk) if(w_valid&&w_ready)mem[wb[LGDEPTH-1:0]]<=w_data;
    always @(posedge rclk) if(fetch)raw_data<=mem[rb[LGDEPTH-1:0]];
    always @(posedge rclk or posedge arst) begin
        if(arst)begin rb<=0;rg<=0;wg1<=0;wg2<=0;raw_valid<=0;end
        else if(rrst[1])begin rb<=0;rg<=0;wg1<=0;wg2<=0;raw_valid<=0;end
        else begin
            wg1<=wg;wg2<=wg1;
            if(!raw_valid||raw_ready)raw_valid<=fetch;
            if(fetch)begin rb<=rn;rg<=(rn>>1)^rn;end
        end
    end
endmodule
