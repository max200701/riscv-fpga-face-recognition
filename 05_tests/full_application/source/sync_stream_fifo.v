// single-clock drop-in for async_stream_fifo, used when both endpoints share one clock
// (FAST_CONTROL: control clock == NPU clock). Same ports and behaviour: depth 2^LGDEPTH RAM entries plus
// one registered output slot, w_used counts entries written but not yet moved to the output slot, reset is
// asserted asynchronously and released after two local edges. No pointer synchronizers, so an entry is
// visible at the output one edge after it is written instead of after the two-stage Gray-code crossing.
module sync_stream_fifo #(parameter WIDTH=32, parameter LGDEPTH=4)(
    input wire arst,
    input wire wclk, input wire w_valid, output wire w_ready,
    input wire [WIDTH-1:0] w_data, output wire [LGDEPTH:0] w_used,
    input wire rclk, output reg r_valid, input wire r_ready,
    output reg [WIDTH-1:0] r_data
);
    reg [WIDTH-1:0] mem [0:(1<<LGDEPTH)-1];
    reg [LGDEPTH:0] wb, rb;
    (* ASYNC_REG="TRUE" *) reg [1:0] lrst;
    always @(posedge wclk or posedge arst) if(arst)lrst<=3;else lrst<={lrst[0],1'b0};
    assign w_used=wb-rb;
    assign w_ready=(!arst)&&(!lrst[1])&&(w_used<(1<<LGDEPTH));
    wire fetch=(!lrst[1])&&(!arst)&&(!r_valid||r_ready)&&(rb!=wb);
    always @(posedge wclk) if(w_valid&&w_ready)mem[wb[LGDEPTH-1:0]]<=w_data;
    always @(posedge wclk) if(fetch)r_data<=mem[rb[LGDEPTH-1:0]];
    always @(posedge wclk or posedge arst) begin
        if(arst)begin wb<=0;rb<=0;r_valid<=0;end
        else if(lrst[1])begin wb<=0;rb<=0;r_valid<=0;end
        else begin
            if(w_valid&&w_ready)wb<=wb+1'b1;
            if(!r_valid||r_ready)r_valid<=fetch;
            if(fetch)rb<=rb+1'b1;
        end
    end
endmodule

// async_stream_fifo, or sync_stream_fifo when both clocks are the same net.
module stream_fifo_sel #(parameter WIDTH=32, parameter LGDEPTH=4, parameter SAME_CLOCK=0)(
    input wire arst,
    input wire wclk, input wire w_valid, output wire w_ready,
    input wire [WIDTH-1:0] w_data, output wire [LGDEPTH:0] w_used,
    input wire rclk, output wire r_valid, input wire r_ready,
    output wire [WIDTH-1:0] r_data
);
 generate if(SAME_CLOCK)begin:one_clock
  sync_stream_fifo #(.WIDTH(WIDTH),.LGDEPTH(LGDEPTH)) f(arst,wclk,w_valid,w_ready,w_data,w_used,rclk,r_valid,r_ready,r_data);
 end else begin:two_clocks
  async_stream_fifo #(.WIDTH(WIDTH),.LGDEPTH(LGDEPTH)) f(arst,wclk,w_valid,w_ready,w_data,w_used,rclk,r_valid,r_ready,r_data);
 end endgenerate
endmodule
