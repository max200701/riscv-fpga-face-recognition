// Release write completion adapter. Earlier beats may enter local storage;
// the upstream final WREADY is withheld until the matching full HMIC burst
// completion. Source LAST/data stay held while that beat is buffered once.
// This is a transport completion, not a readback verification or PHY proof.
module demo_hmic_client(
 input wire clk,rst,enabled,output reg fault,output wire drained,
 input wire c_arvalid,output wire c_arready,input wire[27:0]c_araddr,
 input wire[3:0]c_arlen,c_arid,output wire c_rvalid,output wire[255:0]c_rdata,
 output wire[3:0]c_rid,output wire c_rlast,
 input wire c_awvalid,output wire c_awready,input wire[27:0]c_awaddr,
 input wire[3:0]c_awlen,c_awid,input wire[255:0]c_wdata,input wire[31:0]c_wstrb,
 output wire c_wready,output wire[3:0]c_wid,output wire c_wlast,
 output wire app_rd_valid,input wire app_rd_ready,output wire[31:0]app_rd_addr,
 output wire[6:0]app_rd_beats,output wire[63:0]app_rd_token,output wire[2:0]app_rd_owner,
 input wire app_r_valid,output wire app_r_ready,input wire[255:0]app_r_data,
 input wire[63:0]app_r_token,input wire[6:0]app_r_index,input wire app_r_last,app_r_error,
 output wire app_wr_valid,input wire app_wr_ready,output wire[31:0]app_wr_addr,
 output wire[6:0]app_wr_beats,output wire[63:0]app_wr_token,output wire[2:0]app_wr_owner,
 output wire app_w_valid,input wire app_w_ready,output wire[255:0]app_w_data,
 output wire[31:0]app_w_strb,output wire app_w_last,
 input wire app_b_valid,output wire app_b_ready,input wire[63:0]app_b_token,input wire app_b_error
);
 localparam IDLE=0,READ=1,WRITE=2,VERIFY=3;
 reg[1:0]state;reg[31:0]serial;reg serial_available;reg[63:0]token;reg[3:0]id;reg[4:0]count,index;
 wire[31:0]read_address={2'b0,c_araddr,2'b0},write_address={2'b0,c_awaddr,2'b0};
 wire[12:0]read_end={1'b0,read_address[11:0]}+(({9'b0,c_arlen}+13'd1)<<5);
 wire[12:0]write_end={1'b0,write_address[11:0]}+(({9'b0,c_awlen}+13'd1)<<5);
 wire read_ok=read_address[4:0]==0&&read_end<=4096;
 wire write_ok=write_address[4:0]==0&&write_end<=4096;
 wire idle=state==IDLE&&!rst&&enabled&&!fault&&serial_available;
 assign app_rd_valid=idle&&c_arvalid&&read_ok;
 assign c_arready=idle&&read_ok&&app_rd_ready;
 assign app_rd_addr=read_address;assign app_rd_beats={3'b0,c_arlen}+7'd1;
 assign app_rd_token={32'd1,serial+32'd1};assign app_rd_owner=3'd1;
 assign app_wr_valid=idle&&!c_arvalid&&c_awvalid&&write_ok;
 assign c_awready=idle&&!c_arvalid&&write_ok&&app_wr_ready;
 assign app_wr_addr=write_address;assign app_wr_beats={3'b0,c_awlen}+7'd1;
 assign app_wr_token={32'd1,serial+32'd1};assign app_wr_owner=3'd1;
 assign app_r_ready=!rst&&state==READ;
 assign c_rvalid=app_r_valid&&app_r_ready&&!fault&&!app_r_error&&app_r_token==token&&app_r_index=={2'b0,index}&&app_r_last==(index+1==count);
 assign c_rdata=app_r_data;assign c_rid=id;assign c_rlast=app_r_last;
 assign app_w_valid=!rst&&state==WRITE;
 wire final_w=index+1==count;
 assign c_wready=(app_w_valid&&app_w_ready&&!final_w)||
   (!rst&&!fault&&state==VERIFY&&app_b_valid&&!app_b_error&&app_b_token==token);
 assign c_wid=id;assign c_wlast=index+1==count;
 assign app_w_data=c_wdata;assign app_w_strb=c_wstrb;assign app_w_last=c_wlast;
 assign app_b_ready=!rst&&state==VERIFY;
 assign drained=state==IDLE&&!fault;
 always @(posedge clk)begin
  if(rst)begin state<=IDLE;serial<=0;serial_available<=1;token<=0;id<=0;count<=0;index<=0;fault<=0;end
  else begin
   if(enabled&&state==IDLE&&((c_arvalid&&!read_ok)||(c_awvalid&&!write_ok)||!serial_available))fault<=1;
   if(app_r_valid&&state!=READ)fault<=1;
   if(app_b_valid&&state!=VERIFY)fault<=1;
   case(state)
    IDLE:begin
     if(app_rd_valid&&app_rd_ready)begin state<=READ;serial<=serial+1;serial_available<=serial!=32'hfffffffe;token<=app_rd_token;id<=c_arid;count<={1'b0,c_arlen}+5'd1;index<=0;end
     else if(app_wr_valid&&app_wr_ready)begin state<=WRITE;serial<=serial+1;serial_available<=serial!=32'hfffffffe;token<=app_wr_token;id<=c_awid;count<={1'b0,c_awlen}+5'd1;index<=0;end
    end
    READ:if(app_r_valid&&app_r_ready)begin
     if(app_r_error||app_r_token!=token||app_r_index!={2'b0,index}||app_r_last!=(index+1==count))fault<=1;
     if(index+1==count)state<=IDLE;else index<=index+1;
    end
    WRITE:if(app_w_valid&&app_w_ready)begin if(index+1==count)state<=VERIFY;else index<=index+1;end
    VERIFY:if(app_b_valid&&app_b_ready)begin if(app_b_error||app_b_token!=token)fault<=1;state<=IDLE;end
   endcase
  end
 end
endmodule
