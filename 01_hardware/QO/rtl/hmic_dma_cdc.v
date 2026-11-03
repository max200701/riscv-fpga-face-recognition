// Logos2 HMIC_S user interface, x32 memory / 256-bit UI. Byte offset -> word
// address. No RREADY, WVALID or B response exists on this vendor interface.
// Read: four ordered ID0 bursts, reserve ALL unreturned beats against FIFO.
// Write: pre-store the complete burst before AW; never depend on producer pace
// after AW. Completion means WREADY accepted every beat, NOT DDR visibility.
// Any protocol/timeout fault latches; coordinated reset including controller
// quiescence is required. Dropping one FIFO endpoint independently is forbidden.
module hmic_dma_cdc #(parameter TIMEOUT_CYCLES=65535)(
 input wire arst,npu_clk,ddr_clk,ddr_init_done,
 input wire rd_valid,output wire rd_ready,input wire[31:0]rd_addr,input wire[4:0]rd_beats,
 output wire r_valid,input wire r_ready,output wire[255:0]r_data,output wire r_last,r_error,
 input wire wr_valid,output wire wr_ready,input wire[31:0]wr_addr,input wire[4:0]wr_beats,
 input wire w_valid,output wire w_ready,input wire[255:0]w_data,
 output wire done_valid,input wire done_ready,output wire done_error,
 output wire fault_npu,
 output wire axi_arvalid,input wire axi_arready,output wire[27:0]axi_araddr,
 output wire[3:0]axi_arlen,axi_aruser_id,output wire axi_aruser_ap,
 input wire axi_rvalid,input wire[255:0]axi_rdata,input wire axi_rlast,input wire[3:0]axi_rid,
 output wire axi_awvalid,input wire axi_awready,output wire[27:0]axi_awaddr,
 output wire[3:0]axi_awlen,axi_awuser_id,output wire axi_awuser_ap,
 output wire[255:0]axi_wdata,output wire[31:0]axi_wstrb,
 input wire axi_wready,input wire[3:0]axi_wusero_id,input wire axi_wusero_last,
 output reg[63:0]read_bytes_ui,write_bytes_ui,credit_stalls_ui
);
 wire rqv,rqr,wqv,wqr,dv,dr,done_space;wire[36:0]rq,wq;wire[255:0]d;
 wire[4:0]unused0,unused1;wire[6:0]duse;wire[2:0]doneuse;
 async_stream_fifo #(.WIDTH(37),.LGDEPTH(4),.OUTPUT_PIPE(1)) read_requests(arst,npu_clk,rd_valid,rd_ready,{rd_addr,rd_beats},unused0,ddr_clk,rqv,rqr,rq);
 async_stream_fifo #(.WIDTH(37),.LGDEPTH(4)) write_requests(arst,npu_clk,wr_valid,wr_ready,{wr_addr,wr_beats},unused1,ddr_clk,wqv,wqr,wq);
 async_stream_fifo #(.WIDTH(256),.LGDEPTH(6)) write_data(arst,npu_clk,w_valid,w_ready,w_data,duse,ddr_clk,dv,dr,d);
 reg fault;(* ASYNC_REG="TRUE" *)reg[1:0]fault_sync,reset_pipe;
 always @(posedge npu_clk or posedge arst)if(arst)fault_sync<=0;else fault_sync<={fault_sync[0],fault};
 assign fault_npu=fault_sync[1];
 always @(posedge ddr_clk or posedge arst)if(arst)reset_pipe<=3;else reset_pipe<={reset_pipe[0],1'b0};
 wire running=!arst&&!reset_pipe[1]&&ddr_init_done&&!fault;
 wire[31:0]ra=rq[36:5];wire[4:0]rn=rq[4:0];
 wire[12:0]rend={1'b0,ra[11:0]}+{3'b0,rn,5'b0};
 wire rbad=(rn==0)||(rn>16)||(ra[4:0]!=0)||(ra[31:30]!=0)||(rend>4096);
 wire rsp_ready;wire[7:0]rsp_used;wire[257:0]rsp_out;
 reg[7:0]reserved;reg[2:0]outstanding;reg[1:0]head,tail;
 reg[4:0]lengths[0:3];reg[4:0]position;
 wire credit=({1'b0,rsp_used}+{1'b0,reserved}+{4'b0,rn}<=9'd127);
 assign axi_arvalid=running&&rqv&&!rbad&&(outstanding<4)&&credit;
 assign axi_araddr=ra[29:2];assign axi_arlen=rn[3:0]-1'b1;
 assign axi_aruser_id=0;assign axi_aruser_ap=0;
 wire take_ar=axi_arvalid&&axi_arready;
 wire reject_r=running&&rqv&&rbad&&(outstanding==0)&&rsp_ready;
 assign rqr=take_ar||reject_r;
 wire incoming=axi_rvalid&&(outstanding!=0)&&!reset_pipe[1]&&!arst;
 wire expected_last=(position+1'b1==lengths[head]);
 wire rerr=(axi_rid!=0)||(axi_rlast!=expected_last);
 wire finish_read=incoming&&(axi_rlast||expected_last);
 async_stream_fifo #(.WIDTH(258),.LGDEPTH(7),.OUTPUT_PIPE(1)) read_data(arst,ddr_clk,
  incoming||reject_r,rsp_ready,reject_r?{2'b11,256'b0}:{rerr,(axi_rlast||expected_last),axi_rdata},rsp_used,
  npu_clk,r_valid,r_ready,rsp_out);
 assign {r_error,r_last,r_data}=rsp_out;
 localparam WI=0,WF=1,WA=2,WS=3,WD=4;
 reg[2:0]ws;reg[31:0]wa;reg[4:0]wn,fill,send;
 reg[255:0]stage[0:31];reg werr;
 reg[1:0]bank_state0,bank_state1;
 reg fill_active,fill_bank,fill_turn,send_bank,send_turn;
 reg[4:0]fill_need;reg[31:0]bank_addr0,bank_addr1;
 reg[4:0]bank_len0,bank_len1;
 wire[1:0]fill_state=fill_turn?bank_state1:bank_state0;
 wire[1:0]send_state=send_turn?bank_state1:bank_state0;
 wire[31:0]new_wa=wq[36:5];wire[4:0]new_wn=wq[4:0];
 wire[12:0]wend={1'b0,new_wa[11:0]}+{3'b0,new_wn,5'b0};
 wire wbad=new_wn==0||new_wn>16||new_wa[4:0]!=0||new_wa[31:30]!=0||wend>4096;
 assign wqr=running&&!fill_active&&(fill_state==0);
 assign dr=running&&fill_active;
 assign axi_awvalid=running&&(ws==WA);
 assign axi_awaddr=wa[29:2];assign axi_awlen=wn[3:0]-1'b1;
 assign axi_awuser_id=1;assign axi_awuser_ap=0;
 assign axi_wdata=stage[{send_bank,send[3:0]}];assign axi_wstrb=32'hffffffff;
 wire take_aw=axi_awvalid&&axi_awready;
 wire take_w=running&&axi_wready&&((ws==WS)||take_aw);
 wire wviolation=take_w&&((axi_wusero_id!=1)||(axi_wusero_last!=(send+1'b1==wn)));
 async_stream_fifo #(.WIDTH(1),.LGDEPTH(2),.OUTPUT_PIPE(1)) completions(arst,ddr_clk,ws==WD,done_space,werr,doneuse,npu_clk,done_valid,done_ready,done_error);
 reg[31:0]read_watch,write_watch;
 integer q;
 always @(posedge ddr_clk or posedge arst)begin
  if(arst)begin
   fault<=0;reserved<=0;outstanding<=0;head<=0;tail<=0;position<=0;
   ws<=WI;wa<=0;wn<=0;fill<=0;send<=0;werr<=0;read_watch<=0;write_watch<=0;
   bank_state0<=0;bank_state1<=0;fill_active<=0;fill_bank<=0;fill_turn<=0;send_bank<=0;send_turn<=0;
   fill_need<=0;bank_addr0<=0;bank_addr1<=0;bank_len0<=0;bank_len1<=0;
   read_bytes_ui<=0;write_bytes_ui<=0;credit_stalls_ui<=0;
   for(q=0;q<4;q=q+1)lengths[q]<=0;
  end else if(!reset_pipe[1])begin
   if(rqv&&!credit)credit_stalls_ui<=credit_stalls_ui+1;
   reserved<=reserved+(take_ar?{3'b0,rn}:8'b0)-(incoming?8'd1:8'b0);
   case({take_ar,finish_read})2'b10:outstanding<=outstanding+1;2'b01:outstanding<=outstanding-1;default:begin end endcase
   if(take_ar)begin lengths[tail]<=rn;tail<=tail+1;end
   if(incoming)begin
    read_bytes_ui<=read_bytes_ui+32;
    if(finish_read)begin position<=0;head<=head+1;end else position<=position+1;
    if(rerr||!rsp_ready)fault<=1;
   end
   if(axi_rvalid&&outstanding==0)fault<=1;
   if(reject_r)fault<=1;
   if(outstanding==0||incoming)read_watch<=0;else read_watch<=read_watch+1;
   if(ws!=WA&&ws!=WS||take_aw||take_w)write_watch<=0;else write_watch<=write_watch+1;
   if(TIMEOUT_CYCLES!=0&&(read_watch>=TIMEOUT_CYCLES||write_watch>=TIMEOUT_CYCLES))fault<=1;
   if(!ddr_init_done&&(outstanding!=0||ws!=WI||fill_active))fault<=1;
   if(wqv&&wqr)begin
    if(wbad)fault<=1;
    else begin
     fill_active<=1;fill_bank<=fill_turn;fill<=0;fill_need<=new_wn;
     if(fill_turn)begin bank_state1<=1;bank_addr1<=new_wa;bank_len1<=new_wn;end
     else begin bank_state0<=1;bank_addr0<=new_wa;bank_len0<=new_wn;end
    end
   end
   if(dv&&dr)begin
    stage[{fill_bank,fill[3:0]}]<=d;fill<=fill+1;
    if(fill+1'b1==fill_need)begin
     fill_active<=0;fill_turn<=!fill_turn;
     if(fill_bank)bank_state1<=2;else bank_state0<=2;
    end
   end
   case(ws)
    WI:if(running&&send_state==2&&done_space)begin
     wa<=send_turn?bank_addr1:bank_addr0;wn<=send_turn?bank_len1:bank_len0;
     send_bank<=send_turn;send<=0;werr<=0;ws<=WA;
     if(send_turn)bank_state1<=3;else bank_state0<=3;
    end
    WA:if(take_aw)ws<=WS;
    WD:if(done_space)ws<=WI;
    default:begin end
   endcase
   if(take_w)begin
    write_bytes_ui<=write_bytes_ui+32;send<=send+1;
    if(wviolation)begin fault<=1;werr<=1;ws<=WD;end
    else if(send+1'b1==wn)begin
     ws<=WD;send_turn<=!send_turn;
     if(send_bank)bank_state1<=0;else bank_state0<=0;
    end
   end
   if(axi_wready&&!(ws==WS||take_aw))fault<=1;
  end
 end
endmodule
