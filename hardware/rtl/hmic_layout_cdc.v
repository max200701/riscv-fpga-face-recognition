// Masked NCHW stream -> HMIC_S. All address/data/mask/tag bits cross atomically.
// Two UI-domain banks gather complete <=16-beat, <=4 KiB bursts before AW.
// HMIC has no WVALID or B response. posted_valid acknowledges WREADY acceptance,
// NOT physical DDR readback verification. In the release board integration the
// final WREADY is end-to-end HMIC completion, not local FIFO acceptance.
// A shared-controller reset must quiesce DDR first.
module hmic_layout_cdc #(parameter TIMEOUT_CYCLES=65535,GATHER_IDLE=16)(
 input wire arst,npu_clk,ddr_clk,ddr_init_done,
 input wire rd_valid,output wire rd_ready,input wire[31:0]rd_addr,input wire[4:0]rd_beats,
 output wire r_valid,input wire r_ready,output wire[255:0]r_data,output wire r_last,r_error,
 input wire in_valid,output wire in_ready,input wire[31:0]in_addr,in_strb,in_tag,
 input wire[255:0]in_data,input wire in_last,
 output wire posted_valid,input wire posted_ready,output wire[31:0]posted_tag,
 output wire fault_npu,
 output wire axi_arvalid,input wire axi_arready,output wire[27:0]axi_araddr,
 output wire[3:0]axi_arlen,axi_aruser_id,output wire axi_aruser_ap,
 input wire axi_rvalid,input wire[255:0]axi_rdata,input wire axi_rlast,input wire[3:0]axi_rid,
 output wire axi_awvalid,input wire axi_awready,output wire[27:0]axi_awaddr,
 output wire[3:0]axi_awlen,axi_awuser_id,output wire axi_awuser_ap,
 output wire[255:0]axi_wdata,output wire[31:0]axi_wstrb,
 input wire axi_wready,input wire[3:0]axi_wusero_id,input wire axi_wusero_last,
 output reg[63:0]read_bytes_ui,write_bytes_ui,useful_write_bytes_ui,credit_stalls_ui,
 output reg[63:0]write_bursts_ui,full_bursts_ui,idle_flushes_ui
);
 wire rqv,rqr,dv,dr,done_space;wire[36:0]rq;wire[352:0]d;
 wire[4:0]unused0;wire[6:0]duse;wire[4:0]doneuse;
 joint_async_fifo #(.WIDTH(37),.LGDEPTH(4),.OUTPUT_PIPE(1)) read_requests(arst,npu_clk,rd_valid,rd_ready,{rd_addr,rd_beats},unused0,ddr_clk,rqv,rqr,rq);
 wire input_space;
 joint_async_fifo #(.WIDTH(353),.LGDEPTH(6)) write_stream(arst,npu_clk,in_valid&&!fault_npu,input_space,
  {in_tag,in_last,in_addr,in_strb,in_data},duse,ddr_clk,dv,dr,d);
 assign in_ready=input_space&&!fault_npu;
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
 joint_async_fifo #(.WIDTH(258),.LGDEPTH(7),.OUTPUT_PIPE(1)) read_data(arst,ddr_clk,
  incoming||reject_r,rsp_ready,reject_r?{2'b11,256'b0}:{rerr,(axi_rlast||expected_last),axi_rdata},rsp_used,
  npu_clk,r_valid,r_ready,rsp_out);
 assign {r_error,r_last,r_data}=rsp_out;

 localparam WI=0,WA=1,WS=2,REPORT=3;
 reg[1:0]ws;reg[31:0]wa,active_tag;reg[4:0]wn,send;
 reg active_last;
 reg[287:0]stage[0:31] /* synthesis syn_ramstyle="block_ram" */;
 reg[287:0]read_word;
 reg[1:0]full;
 reg fill_bank,send_bank,send_turn;
 reg[4:0]fill_count,bank_len[0:1];reg[31:0]bank_addr[0:1],bank_tag[0:1];
 reg[1:0]bank_last;
 reg[31:0]gather_watch;reg tile_open;reg[31:0]tile_tag;
 wire[31:0]da=d[319:288],ds=d[287:256],dt=d[352:321];wire dl=d[320];
 wire dbad=da[4:0]!=0||da[31:30]!=0||ds==0||(tile_open&&dt!=tile_tag);
 wire compatible=fill_count==0||
  (da==bank_addr[fill_bank]+{22'b0,fill_count,5'b0}&&da[31:12]==bank_addr[fill_bank][31:12]);
 wire close_gap=running&&!full[fill_bank]&&fill_count!=0&&dv&&!compatible;
 wire close_idle=running&&!full[fill_bank]&&fill_count!=0&&!dv&&gather_watch>=GATHER_IDLE;
 assign dr=running&&!full[fill_bank]&&compatible;
 wire take_stream=dv&&dr;
 wire write_stage=take_stream&&!dbad;
 wire start_send=running&&ws==WI&&full[send_turn]&&done_space;
 assign axi_awvalid=running&&(ws==WA);
 assign axi_awaddr=wa[29:2];assign axi_awlen=wn[3:0]-1'b1;
 assign axi_awuser_id=1;assign axi_awuser_ap=0;
 assign {axi_wstrb,axi_wdata}=read_word;
 wire take_aw=axi_awvalid&&axi_awready;
 wire take_w=running&&axi_wready&&((ws==WS)||take_aw);
 wire wviolation=take_w&&((axi_wusero_id!=1)||(axi_wusero_last!=(send+1'b1==wn)));
 wire prefetch=start_send||(take_w&&send+1'b1<wn);
 wire[4:0]read_index=start_send?{send_turn,4'b0}:{send_bank,send[3:0]+4'd1};
 // Synchronous read, next word fetched only when the current word is accepted.
 // Data is primed one cycle before AW, including AW+first-W same-cycle service.
 always @(posedge ddr_clk)begin
  if(write_stage)stage[{fill_bank,fill_count[3:0]}]<=d[287:0];
  if(prefetch)read_word<=stage[read_index];
 end
 joint_async_fifo #(.WIDTH(32),.LGDEPTH(4),.OUTPUT_PIPE(1)) completions(arst,ddr_clk,ws==REPORT&&!fault,done_space,active_tag,doneuse,
  npu_clk,posted_valid,posted_ready,posted_tag);
 function[5:0]popcount(input[31:0]mask);
  integer b;begin popcount=0;for(b=0;b<32;b=b+1)popcount=popcount+mask[b];end
 endfunction
 reg[31:0]read_watch,write_watch;
 integer q;
 always @(posedge ddr_clk or posedge arst)begin
  if(arst)begin
   fault<=0;reserved<=0;outstanding<=0;head<=0;tail<=0;position<=0;
   ws<=WI;wa<=0;wn<=0;send<=0;read_watch<=0;write_watch<=0;active_tag<=0;active_last<=0;
   full<=0;fill_bank<=0;send_bank<=0;send_turn<=0;fill_count<=0;
   bank_last<=0;gather_watch<=0;tile_open<=0;tile_tag<=0;
   read_bytes_ui<=0;write_bytes_ui<=0;useful_write_bytes_ui<=0;credit_stalls_ui<=0;
   write_bursts_ui<=0;full_bursts_ui<=0;idle_flushes_ui<=0;
   for(q=0;q<4;q=q+1)lengths[q]<=0;
   for(q=0;q<2;q=q+1)begin bank_addr[q]<=0;bank_len[q]<=0;bank_tag[q]<=0;end
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
   if((ws!=WA&&ws!=WS)||take_aw||take_w)write_watch<=0;else write_watch<=write_watch+1;
   if(TIMEOUT_CYCLES!=0&&(read_watch>=TIMEOUT_CYCLES||write_watch>=TIMEOUT_CYCLES))fault<=1;
   if(!ddr_init_done&&(outstanding!=0||ws!=WI||fill_count!=0||full!=0||tile_open))fault<=1;
   if(fill_count==0||dv||full[fill_bank])gather_watch<=0;else gather_watch<=gather_watch+1;
   if(close_gap||close_idle)begin
    full[fill_bank]<=1;bank_len[fill_bank]<=fill_count;bank_last[fill_bank]<=0;
    fill_count<=0;fill_bank<=!fill_bank;gather_watch<=0;
    if(close_idle)idle_flushes_ui<=idle_flushes_ui+1;
   end
   if(take_stream)begin
    if(dbad)fault<=1;
    else begin
     tile_open<=!dl;tile_tag<=dt;
     if(fill_count==0)begin bank_addr[fill_bank]<=da;bank_tag[fill_bank]<=dt;end
     if(dl||fill_count==15||da[11:5]==127)begin
      full[fill_bank]<=1;bank_len[fill_bank]<=fill_count+1'b1;bank_last[fill_bank]<=dl;
      fill_count<=0;fill_bank<=!fill_bank;
     end else fill_count<=fill_count+1'b1;
    end
   end
   if(start_send)begin
    wa<=bank_addr[send_turn];wn<=bank_len[send_turn];active_tag<=bank_tag[send_turn];active_last<=bank_last[send_turn];
    send_bank<=send_turn;send<=0;ws<=WA;
   end
   if(take_aw)begin
    ws<=WS;write_bursts_ui<=write_bursts_ui+1;
    if(wn==16)full_bursts_ui<=full_bursts_ui+1;
   end
   if(ws==REPORT&&done_space&&!fault)ws<=WI;
   if(take_w)begin
    write_bytes_ui<=write_bytes_ui+32;useful_write_bytes_ui<=useful_write_bytes_ui+popcount(axi_wstrb);send<=send+1'b1;
    if(wviolation)fault<=1;
    else if(send+1'b1==wn)begin
     full[send_bank]<=0;send_turn<=!send_turn;ws<=active_last?REPORT:WI;
    end
   end
   if(axi_wready&&!(ws==WS||take_aw))fault<=1;
  end
 end
endmodule
