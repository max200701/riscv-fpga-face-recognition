// Immutable 64-byte graph records, fetched eight at a time from shared DDR.
// This cache contains instructions/addresses, never computed activations.
// The CPU owns program integrity and lifetime. A global reset invalidates it.
module graph_program_cache(
 input wire clk,rst,cmd_valid,output wire cmd_ready,input wire[31:0]cmd_address,
 output wire rsp_valid,input wire rsp_ready,output reg[511:0]rsp_data,output reg[7:0]rsp_error,
 output wire rd_valid,input wire rd_ready,output wire[31:0]rd_address,output wire[4:0]rd_beats,
 input wire r_valid,output wire r_ready,input wire[255:0]r_data,input wire r_last,r_error,
 output reg[31:0]fills,hits
);
 localparam IDLE=0,REQUEST=1,FILL=2,READ_LO=3,WAIT_LO=4,READ_HI=5,WAIT_HI=6,RESPONSE=7;
 reg[2:0]state;reg cache_valid;reg[31:0]tag,base;reg[3:0]index,beat;reg bad;
 reg[63:0]bank0[0:15] /* synthesis syn_ramstyle = "block_ram" */;
 reg[63:0]bank1[0:15] /* synthesis syn_ramstyle = "block_ram" */;
 reg[63:0]bank2[0:15] /* synthesis syn_ramstyle = "block_ram" */;
 reg[63:0]bank3[0:15] /* synthesis syn_ramstyle = "block_ram" */;
 reg[255:0]q;
 wire[3:0]read_index=state==READ_HI?index+1'b1:index;
 always @(posedge clk)begin
  if(state==FILL&&r_valid)begin
   bank0[beat]<=r_data[63:0];bank1[beat]<=r_data[127:64];bank2[beat]<=r_data[191:128];bank3[beat]<=r_data[255:192];
  end
  if(state==READ_LO||state==READ_HI)q<={bank3[read_index],bank2[read_index],bank1[read_index],bank0[read_index]};
 end
 assign cmd_ready=!rst&&state==IDLE;
 assign rsp_valid=!rst&&state==RESPONSE;
 assign rd_valid=!rst&&state==REQUEST;
 assign rd_address=base;assign rd_beats=16;
 assign r_ready=!rst&&state==FILL;
 always @(posedge clk)begin
  if(rst)begin state<=IDLE;cache_valid<=0;tag<=0;base<=0;index<=0;beat<=0;bad<=0;rsp_data<=0;rsp_error<=0;fills<=0;hits<=0;end
  else case(state)
   IDLE:if(cmd_valid)begin
    rsp_error<=0;index<=cmd_address[8:5];base<={cmd_address[31:9],9'b0};
    if(cmd_address[5:0]!=0||cmd_address>=32'h40000000)begin rsp_error<=1;state<=RESPONSE;end
    else if(cache_valid&&tag==cmd_address[31:9])begin hits<=hits+1'b1;state<=READ_LO;end
    else begin cache_valid<=0;state<=REQUEST;end
   end
   REQUEST:if(rd_ready)begin state<=FILL;beat<=0;bad<=0;fills<=fills+1'b1;end
   FILL:if(r_valid)begin
    bad<=bad||r_error||(r_last!=(beat==15));
    if(r_last||beat==15)begin
     if(bad||r_error||(r_last!=(beat==15)))begin rsp_error<=2;cache_valid<=0;state<=RESPONSE;end
     else begin tag<=base[31:9];cache_valid<=1;state<=READ_LO;end
    end else beat<=beat+1'b1;
   end
   READ_LO:state<=WAIT_LO;
   WAIT_LO:begin rsp_data[255:0]<=q;state<=READ_HI;end
   READ_HI:state<=WAIT_HI;
   WAIT_HI:begin rsp_data[511:256]<=q;state<=RESPONSE;end
   RESPONSE:if(rsp_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
