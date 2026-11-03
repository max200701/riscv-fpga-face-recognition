// CPU commands are immutable FIFO snapshots. RUN acknowledges acceptance;
// WAIT acknowledges posted completion. Neither means a real DDR PHY fence.
// READ32 uses a separate ordered HMIC read, uncached, only after all RUNs.
// WINDOW_A/B only configure the panel loader, so they wait for the
// loader to be idle (lr), not for compute/posting; LOAD of the next step can then
// overlap the previous RUN (program v3 double-buffers the two operand banks).
// Global reset includes all clock domains and controller quiescence.
module cpu_npu_queue #(parameter AW=12,NATIVE=1,WATCHDOG=1000000,SAME_CLOCK=0)(
 input wire arst,cpu_clk,npu_clk,ddr_clk,ddr_init_done,
 input wire bus_valid,bus_write,input wire[11:0]bus_addr,
 input wire[31:0]bus_wdata,input wire[3:0]bus_wstrb,
 output wire bus_ready,bus_error,output reg[31:0]bus_rdata,output wire irq,
 output wire axi_arvalid,input wire axi_arready,output wire[27:0]axi_araddr,
 output wire[3:0]axi_arlen,axi_aruser_id,output wire axi_aruser_ap,
 input wire axi_rvalid,input wire[255:0]axi_rdata,input wire axi_rlast,input wire[3:0]axi_rid,
 output wire axi_awvalid,input wire axi_awready,output wire[27:0]axi_awaddr,
 output wire[3:0]axi_awlen,axi_awuser_id,output wire axi_awuser_ap,
 output wire[255:0]axi_wdata,output wire[31:0]axi_wstrb,
 input wire axi_wready,input wire[3:0]axi_wusero_id,input wire axi_wusero_last,
 output wire diagnostic_fault,output wire[63:0]diagnostic_macs,
 // direct command push / response pop from the DMA sequencer (cpu_clk side)
 input wire dq_valid,output wire dq_ready,input wire[31:0]dq_door,input wire[255:0]dq_args,
 output wire dr_valid,input wire dr_pop,output wire[127:0]dr_data
);
 localparam PARAM=1,LOAD=2,RUN=3,WAIT_POSTED=4,RELEASE=5,READ32=6,MODEL_PARAM=7,LAYOUT=8,QUANT=9,PARAM_DMA=10,WINDOW_A=11,WINDOW_B=12;
 reg[31:0]arg[0:7];wire[255:0]args;
 genvar g;generate for(g=0;g<8;g=g+1)begin:a assign args[g*32+:32]=arg[g];end endgenerate
 wire door=bus_addr==0,pop=bus_addr==12'h00c;
 wire argument=(bus_addr>=12'h020)&&(bus_addr<12'h040);
 wire readable=(bus_addr==4)||(bus_addr>=12'h010&&bus_addr<12'h020)||argument;
 wire writable=door||pop||argument;
 wire qready,qvalid,qpop,rsp_valid,rsp_ready;wire[287:0]qdata;wire[127:0]rsp_data;
 wire[4:0]q_used,rsp_used;
 wire raw_error=bus_addr[1:0]!=0||(bus_write?(!writable||bus_wstrb!=15):!readable);
 // PG: stable local decode and payload, matching the existing request slice contract.
 reg checked,checked_error,checked_door,checked_pop;
 reg[7:0]arg_write;reg[31:0]checked_data;
 assign bus_error=checked&&checked_error;
 assign bus_ready=!arst&&checked&&(checked_error||!checked_door||qready);
 wire accept=bus_valid&&bus_ready&&!checked_error;
 wire bus_push=accept&&checked_door;
 wire bus_take=accept&&checked_pop;
 always @(posedge cpu_clk or posedge arst)begin
  if(arst)begin checked<=0;checked_error<=0;checked_door<=0;checked_pop<=0;arg_write<=0;checked_data<=0;end
  else if(checked)begin if(!bus_valid||bus_ready)checked<=0;end
  else if(bus_valid)begin
   checked<=1;checked_error<=raw_error;checked_data<=bus_wdata;
   checked_door<=bus_write&&door;checked_pop<=bus_write&&pop;
   arg_write<=bus_write&&argument?(8'b1<<bus_addr[4:2]):8'b0;
  end
 end
 assign dq_ready=qready&&!bus_push;wire dpush=dq_valid&&dq_ready;
 wire push=bus_push||dpush;
 assign dr_valid=rsp_valid;assign dr_data=rsp_data;
 wire take=bus_take||(dr_pop&&rsp_valid&&!bus_take);
 assign irq=rsp_valid;
 always @*begin
  bus_rdata=0;
  case(bus_addr)
   12'h004:bus_rdata={16'b0,3'b0,q_used,6'b0,rsp_valid,qready};
   12'h010:bus_rdata=rsp_data[31:0];12'h014:bus_rdata=rsp_data[63:32];
   12'h018:bus_rdata=rsp_data[95:64];12'h01c:bus_rdata=rsp_data[127:96];
   default:if(argument)bus_rdata=arg[bus_addr[4:2]];
  endcase
 end
 integer i;
 always @(posedge cpu_clk or posedge arst)begin
  if(arst)for(i=0;i<8;i=i+1)arg[i]<=0;
  else if(dpush)for(i=0;i<8;i=i+1)arg[i]<=dq_args[i*32+:32];
  else if(accept)for(i=0;i<8;i=i+1)if(arg_write[i])arg[i]<=checked_data;
 end
 stream_fifo_sel #(.WIDTH(288),.LGDEPTH(4),.SAME_CLOCK(SAME_CLOCK)) commands(   // c25
  arst,cpu_clk,push,qready,dpush?{dq_door,dq_args}:{checked_data,args},q_used,npu_clk,qvalid,qpop,qdata);
 reg response;reg[127:0]result;
 stream_fifo_sel #(.WIDTH(128),.LGDEPTH(4),.SAME_CLOCK(SAME_CLOCK)) responses(   // c25
  arst,npu_clk,response,rsp_ready,result,rsp_used,cpu_clk,rsp_valid,take,rsp_data);
 localparam IDLE=0,EXEC=1,LOAD_WAIT=2,RESP=3,READ_WAIT=4,PARAM_WAIT=5,CHECK_COMMAND=6,DECODE_COMMAND=7,FORMAT_RESPONSE=8;
 reg[3:0]state;reg command_bad;reg[287:0]cmd;reg[31:0]watch,issued,completed;reg[7:0]sticky_fault;
 wire[7:0]op=cmd[263:256];wire[15:0]tag=cmd[279:264];
 wire[31:0]a0=cmd[31:0],a1=cmd[63:32],a2=cmd[95:64],a3=cmd[127:96];
 wire[31:0]a4=cmd[159:128],a5=cmd[191:160],a6=cmd[223:192],a7=cmd[255:224];
 reg[31:0]lb,lp,ls,lc,lrecip;reg[8:0]lm,ln;reg[1:0]lmode;reg[2:0]lop;
 reg[39:0]lden;reg signed[15:0]lzero;reg[4:0]lbits;reg layout_set,quant_set;
 reg[31:0]wepoch,wwepoch;
 reg[15:0]wh,ww,wc,woh,wow,wy,wx;reg[8:0]wm;
 reg[3:0]wkh,wkw,wpy,wpx;reg[1:0]wsy,wsx;reg wwide,wa_set,wb_set;
 reg signed[15:0]wzero;
 // registered two-stage product; the window registers it depends on are written by the
 // previous command's EXEC, >= 3 npu_clk edges before the next CHECK_COMMAND samples it.
 reg[31:0]expected_c;reg[63:0]expected_words;reg[4:0]expected_mtiles;
 always @(posedge npu_clk)begin expected_c<={16'b0,wc}*wkh*wkw;expected_mtiles<=({1'b0,wm}+10'd31)>>5;expected_words<={32'b0,expected_c}*expected_mtiles;end
 wire lr,ldone,rr,cr,cdone,posted,pr,fault,pdlready,pdldone;wire[1:0]banks;wire[3:0]error;
 wire bad_window_a=op==WINDOW_A&&(a0==0||a0>1024||a1==0||a1>1024||a2==0||a2>4096||
   a3==0||a3>1024||a4==0||a4>1024||a5>1||(a5[0]?($signed(a6)< -32'sd2048||$signed(a6)>32'sd2047):($signed(a6)< -32'sd128||$signed(a6)>32'sd127)));
 wire bad_window_b=op==WINDOW_B&&(a0>=woh||a1>=wow||a2==0||a2>256||a3[3:0]==0||a3[3:0]>7||a3[7:4]==0||a3[7:4]>7||a3[31:8]!=0||
   (a4[1:0]!=1&&a4[1:0]!=2)||(a4[3:2]!=1&&a4[3:2]!=2)||a4[31:4]!=0||a5[31:8]!=0||a7!=0||!wa_set);
 reg[9:0]command_groups;
 wire bad_command=|command_groups;
 always @(posedge npu_clk)if(state==DECODE_COMMAND)begin
  command_groups[0]<=(bad_window_a);
  command_groups[1]<=(bad_window_b);
  command_groups[2]<=((op==PARAM&&(a0>255||a2[31]||a3>63)));
  command_groups[3]<=((op==MODEL_PARAM&&(a0>255||a3!=24)));
  command_groups[4]<=(
  (op==LOAD&&(a0>7||(!a0[1]&&a0[2])||(a0[1]&&(a3>2048||a4>2048))||a3==0||a4==0||a3>(1<<AW)||a4>(1<<AW)||!wa_set||!wb_set||a3!=expected_words||a5>3||(!wwide&&a5!=0)||(a5[1]&&(a5[0]||a0[0]))||a6!=0||a7!=0)));
  command_groups[5]<=(
  (op==RUN&&(a0>31||(!a0[3]&&a0[4])||a1==0||a1>65535||a2[3:0]==0||a2[3:0]>8||a2[11:8]==0||a2[11:8]>8||
            (a2&32'hfffff0f0)!=0||a7[31:3]!=0||(a7[2]&&!a7[0])||!a7[2]||!layout_set||!quant_set)));
  command_groups[6]<=((op==RELEASE&&(a0>7||(!a0[1]&&a0[2]))));
  command_groups[7]<=(
  (op==LAYOUT&&(a0>=32'h40000000||a1==0||a1>32'h40000000||a4==0||a4>256||a5==0||a5>256||a6>2||
    (a7!=0&&a7!=4&&a7!=5&&a7!=6&&a7!=7)||{1'b0,a2}+a4>{1'b0,a1}||a3>=32'h40000000||
    (a6==1?a0[0]:a6==2?|(a0[1:0]):1'b0))));
  command_groups[8]<=(
  (op==QUANT&&(a1>255||{a1[7:0],a0}<=40'h1000000||a2==0||(a4!=8&&a4!=12)||
    (a4==12?($signed(a3)< -32'sd2048||$signed(a3)>32'sd2047):($signed(a3)< -32'sd128||$signed(a3)>32'sd127))||a5!=0||a6!=0||a7!=0)));
  command_groups[9]<=(
  (op==PARAM_DMA&&(a0[4:0]!=0||a0[31:30]!=0||a1==0||a1>256||({1'b0,a0}+({1'b0,a1}<<4)>33'h40000000)||
    a2>1||a3!=0||a4!=0||a5!=0||a6!=0||a7!=0)));
 end
 // MO: validate the immutable FIFO snapshot before any engine handshake.
 wire execute=state==EXEC&&!command_bad&&!fault&&sticky_fault==0;
 wire lv=execute&&op==LOAD;
 wire cv=execute&&op==RUN;
 wire pv=execute&&(op==PARAM||op==MODEL_PARAM)&&pr;
 wire rel=execute&&op==RELEASE;
 wire[63:0]cycles,macs,inputwait,resultwait,words,outbytes,tiles,overlap,rbytes,wbytes,credit;
 assign diagnostic_fault=fault;
 assign diagnostic_macs=macs;
 wire nav,nready;wire[27:0]na;wire[3:0]nl,ni;wire nap;
 reg read_active;reg[2:0]read_lane;
 npu_ddr_datapath #(.AW(AW),.PANGO_SIMD(NATIVE),.ROW_GROUPS(4),.TIMEOUT_CYCLES(WATCHDOG)) npu(
  .arst(arst),.npu_clk(npu_clk),.ddr_clk(ddr_clk),.ddr_init_done(ddr_init_done),
  .layout_base(lb),.layout_plane(lp),.layout_spatial(ls),.layout_channel(lc),.layout_m(lm),.layout_n(ln),.layout_mode(lmode),.layout_op(lop),
  .layout_den(lden),.layout_recip(lrecip),.layout_zero(lzero),.layout_bits(lbits),
  .window_epoch(wepoch),.weight_epoch(wwepoch),.window_h(wh),.window_w(ww),.window_c(wc),.window_oh(woh),.window_ow(wow),
  .window_y(wy),.window_x(wx),.window_m(wm),.window_kh(wkh),.window_kw(wkw),.window_sy(wsy),.window_sx(wsx),.window_py(wpy),.window_px(wpx),
  .window_pair(a5[1]),.window_wide(wwide),.window_high(a5[0]),.window_zero(wzero),
  .load_valid(lv),.load_ready(lr),.load_bank(a0[0]),.load_hmode(a0[1]),.load_half(a0[2]),.load_a_addr(a1),.load_b_addr(a2),
  .load_a_words(a3[AW:0]),.load_b_words(a4[AW:0]),.load_done(ldone),
  .release_valid(rel),.release_bank(a0[0]),.release_hmode(a0[1]),.release_half(a0[2]),.release_ready(rr),.bank_ready(banks),
  .cmd_valid(cv),.cmd_bank(a0[0]),.cmd_hmode(a0[3]),.cmd_half(a0[4]),.cmd_first(a0[1]),.cmd_last(a0[2]),.cmd_k(a1[15:0]),.cmd_wide(a7[0]),.cmd_shift8(a7[1]),.cmd_q16(a7[2]),
  .cmd_mtiles(a2[3:0]),.cmd_ntiles(a2[11:8]),.cmd_dest(a3),.cmd_ready(cr),.compute_done(cdone),.posted_done(posted),
  .params_prelu(a2[0]),.params_load_valid(execute&&op==PARAM_DMA),.params_load_ready(pdlready),.params_load_addr(a0),.params_load_count(a1[8:0]),.params_load_done(pdldone),
  .param_valid(pv),.param_index(a0[7:0]),.param_bias(a1),.param_multiplier(a2),.param_post_bias(op==MODEL_PARAM?a4:32'b0),.param_shift(a3[5:0]),.param_ready(pr),
  .zero_point(a4[7:0]),.clamp_min(a5[7:0]),.clamp_max(a6[7:0]),.fault(fault),.local_error(error),
  .axi_arvalid(nav),.axi_arready(nready),.axi_araddr(na),.axi_arlen(nl),.axi_aruser_id(ni),.axi_aruser_ap(nap),
  .axi_rvalid(axi_rvalid&&!read_active),.axi_rdata(axi_rdata),.axi_rlast(axi_rlast),.axi_rid(axi_rid),
  .axi_awvalid(axi_awvalid),.axi_awready(axi_awready),.axi_awaddr(axi_awaddr),.axi_awlen(axi_awlen),
  .axi_awuser_id(axi_awuser_id),.axi_awuser_ap(axi_awuser_ap),.axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),
  .axi_wready(axi_wready),.axi_wusero_id(axi_wusero_id),.axi_wusero_last(axi_wusero_last),
  .cycles(cycles),.mac_cycles(macs),.input_wait_cycles(inputwait),.result_wait_cycles(resultwait),
  .input_words(words),.output_bytes(outbytes),.tiles(tiles),.overlap_cycles(overlap),
  .read_bytes_ui(rbytes),.write_bytes_ui(wbytes),.credit_stalls_ui(credit));
 // READ32 uses its own CDC queues. No multi-bit data is sampled across clocks.
 wire req_ready,req_valid,req_pop,read_return,return_ready,read_space;wire[31:0]read_addr;
 wire[32:0]read_data;wire[2:0]unused0,unused1;
 wire read_launch=execute&&op==READ32&&issued==completed&&a0[31:30]==0&&a0[1:0]==0;
 async_stream_fifo #(.WIDTH(32),.LGDEPTH(2)) cpu_read_request(
  arst,npu_clk,read_launch,req_ready,a0,unused0,ddr_clk,req_valid,req_pop,read_addr);
 wire cpu_ar=req_valid&&!read_active&&read_space&&ddr_init_done&&!arst;
 assign axi_arvalid=cpu_ar||(!req_valid&&!read_active&&nav);
 assign axi_araddr=cpu_ar?{read_addr[29:5],3'b0}:na;
 assign axi_arlen=cpu_ar?4'd0:nl;assign axi_aruser_id=cpu_ar?4'd2:ni;
 assign axi_aruser_ap=cpu_ar?1'b0:nap;
 assign nready=axi_arready&&!req_valid&&!read_active;
 assign req_pop=cpu_ar&&axi_arready;
 wire got_read=read_active&&axi_rvalid;
 async_stream_fifo #(.WIDTH(33),.LGDEPTH(2)) cpu_read_response(
  arst,ddr_clk,got_read,read_space,{(axi_rid!=2||!axi_rlast),axi_rdata[read_lane*32+:32]},unused1,
  npu_clk,read_return,return_ready,read_data);
 assign return_ready=state==READ_WAIT;
 always @(posedge ddr_clk or posedge arst)begin
  if(arst)begin read_active<=0;read_lane<=0;end
  else begin
   if(req_pop)begin read_active<=1;read_lane<=read_addr[4:2];end
   if(got_read)read_active<=0;
  end
 end
 assign qpop=state==IDLE;
 reg[7:0]reply_code_q;reg[31:0]reply_value_q,reply_cycles_q,reply_completed_q;
 // Timestamp/counter snapshots run independently of parameter-ready fanout.
 always @(posedge npu_clk)begin reply_cycles_q<=cycles[31:0];reply_completed_q<=completed;end
 task respond(input[7:0]code,input[31:0]value);
  begin reply_code_q<=code;reply_value_q<=value;state<=FORMAT_RESPONSE;end
 endtask
 always @(posedge npu_clk or posedge arst)begin
  if(arst)begin state<=IDLE;command_bad<=1;cmd<=0;watch<=0;issued<=0;completed<=0;response<=0;result<=0;sticky_fault<=0;lb<=0;lp<=0;ls<=0;lc<=0;lm<=0;ln<=0;lmode<=0;lop<=0;lden<=0;lrecip<=0;lzero<=0;lbits<=0;layout_set<=0;quant_set<=0;wepoch<=0;wwepoch<=0;wh<=0;ww<=0;wc<=0;woh<=0;wow<=0;wy<=0;wx<=0;wm<=0;wkh<=0;wkw<=0;wpy<=0;wpx<=0;wsy<=0;wsx<=0;wwide<=0;wzero<=0;wa_set<=0;wb_set<=0;end
  else begin
   if(posted)completed<=completed+1;
   if(state==IDLE)begin
    watch<=0;
    if(qvalid)begin cmd<=qdata;command_bad<=1;state<=DECODE_COMMAND;end
   end else if(state==FORMAT_RESPONSE)begin
    result<={reply_cycles_q,reply_completed_q,reply_value_q,reply_code_q,tag,op};
    response<=1;state<=RESP;
   end else if(state==RESP)begin
    if(response&&rsp_ready)begin response<=0;state<=IDLE;end
   end else if(sticky_fault!=0)respond(sticky_fault,0);
   else if(fault)respond({4'h1,error},0);
   else if(watch>=WATCHDOG)begin sticky_fault<=8'hfe;respond(8'hfe,0);end
   else begin
    watch<=watch+1;
    case(state)
     DECODE_COMMAND:state<=CHECK_COMMAND;
     CHECK_COMMAND:begin command_bad<=bad_command;state<=EXEC;end
     EXEC:if(command_bad)respond(8'hf0,0);else case(op)
      WINDOW_A:if(lr)begin
       wh<=a0[15:0];ww<=a1[15:0];wc<=a2[15:0];woh<=a3[15:0];wow<=a4[15:0];wwide<=a5[0];wzero<=a6[15:0];wepoch<=a7;
       wa_set<=1;wb_set<=0;respond(0,0);
      end
      WINDOW_B:if(lr)begin
       wy<=a0[15:0];wx<=a1[15:0];wm<=a2[8:0];wkh<=a3[3:0];wkw<=a3[7:4];wsy<=a4[1:0];wsx<=a4[3:2];wpy<=a5[3:0];wpx<=a5[7:4];wwepoch<=a6;wb_set<=1;respond(0,0);
      end
      PARAM,MODEL_PARAM:if(pr)respond(0,0);
      PARAM_DMA:if(pdlready)state<=PARAM_WAIT;
      LAYOUT:if(pr&&issued==completed)begin lb<=a0;lp<=a1;ls<=a2;lc<=a3;lm<=a4[8:0];ln<=a5[8:0];lmode<=a6[1:0];lop<=a7[2:0];layout_set<=1;respond(0,0);end
      QUANT:if(pr&&issued==completed)begin lden<={a1[7:0],a0};lrecip<=a2;lzero<=a3[15:0];lbits<=a4[4:0];quant_set<=1;respond(0,0);end
      LOAD:if(lr)state<=LOAD_WAIT;
      RUN:if(cr)begin issued<=issued+1;respond(0,issued+1);end
      WAIT_POSTED:if(completed==a0)respond(0,completed);
      RELEASE:if(rr)respond(0,0);
      READ32:if(a0[31:30]!=0||a0[1:0]!=0)respond(8'hf1,0);
             else if(read_launch&&req_ready)state<=READ_WAIT;
      default:respond(8'hff,0);
     endcase
     LOAD_WAIT:if(ldone)respond(0,0);
     PARAM_WAIT:if(pdldone)respond(0,0);
     READ_WAIT:if(read_return)begin
      if(read_data[32])sticky_fault<=8'hf2;
      respond(read_data[32]?8'hf2:8'h00,read_data[31:0]);
     end
     default:respond(8'hfd,0);
    endcase
   end
  end
 end
endmodule
