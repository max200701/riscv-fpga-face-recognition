module graph_vector_bridge(
 input wire arst,cpu_clk,npu_clk,bus_valid,bus_write,input wire[11:0]bus_addr,
 input wire[31:0]bus_wdata,input wire[3:0]bus_wstrb,
 output wire bus_ready,bus_error,output reg[31:0]bus_rdata,output wire irq,
 output wire rd_valid,input wire rd_ready,output wire[31:0]rd_addr,output wire[4:0]rd_beats,
 input wire r_valid,output wire r_ready,input wire[255:0]r_data,input wire r_last,r_error,
 output wire out_valid,input wire out_ready,output wire[31:0]out_addr,out_strb,out_tag,
 output wire[255:0]out_data,output wire out_last,input wire posted_valid,output wire posted_ready,input wire[31:0]posted_tag,
 output wire[63:0]diagnostic_elements
);
 reg[31:0]address;wire[5:0]offset=bus_addr[5:0];wire selected=bus_addr[11:6]==6'h10;
 wire req_space,req_valid,req_ready,rv,rr,sv;wire[31:0]req_addr;wire[135:0]response;
 wire[7:0]error;wire[63:0]elements,cycles;
 assign diagnostic_elements=elements;
 assign bus_error=!selected||offset[1:0]!=0||(bus_write?(bus_wstrb!=15||(offset!=0&&offset!=8&&offset!=20)):
     (offset!=4&&offset!=20&&offset!=32&&offset!=36&&offset!=40&&offset!=44));
 assign bus_ready=!arst&&(bus_error||!bus_write||offset!=0||req_space);
 assign irq=sv;
 always @*begin
  bus_rdata=0;
  case(offset)
   4:bus_rdata={30'b0,sv,req_space};20:bus_rdata={24'b0,response[7:0]};
   32:bus_rdata=response[39:8];36:bus_rdata=response[71:40];40:bus_rdata=response[103:72];44:bus_rdata=response[135:104];
  endcase
 end
 always @(posedge cpu_clk or posedge arst)begin
  if(arst)address<=0;
  else if(bus_valid&&bus_ready&&bus_write&&!bus_error&&offset==8)address<=bus_wdata;
 end
 package_mailbox #(.WIDTH(32)) requests(arst,cpu_clk,bus_valid&&bus_ready&&bus_write&&!bus_error&&offset==0,req_space,address,npu_clk,req_valid,req_ready,req_addr);
 graph_vector_engine engine(npu_clk,arst,req_valid,req_ready,req_addr,rv,rr,error,
  rd_valid,rd_ready,rd_addr,rd_beats,r_valid,r_ready,r_data,r_last,r_error,
  out_valid,out_ready,out_addr,out_strb,out_tag,out_data,out_last,posted_valid,posted_ready,posted_tag,elements,cycles);
 package_mailbox #(.WIDTH(136)) responses(arst,npu_clk,rv,rr,{cycles,elements,error},cpu_clk,sv,bus_valid&&bus_ready&&bus_write&&!bus_error&&offset==20,response);
endmodule
