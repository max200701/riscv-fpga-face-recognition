// CPU delegates a preflighted, immutable fixed-model command table.
// This is a bus master, not another CPU. It fetches every command from shared
// DDR through the existing checked package service and preserves all response
// and posted-completion checks. CPU keeps ownership of activation input life.
module graph_mmio_dma_sequencer(
 input wire clk,rst,valid,write,input wire[7:0]addr,input wire[31:0]wdata,input wire[3:0]wstrb,
 output wire ready,error,output reg[31:0]rdata,output wire active,irq,
 output wire mvalid,mwrite,input wire mready,merror,output reg[11:0]maddr,output reg[31:0]mwdata,input wire[31:0]mrdata,
 output wire fetch_valid,input wire fetch_ready,output wire[31:0]fetch_address,
 input wire fetched_valid,output wire fetched_ready,input wire[511:0]fetched_data,input wire[7:0]fetched_error,
 output wire dq_valid,input wire dq_ready,output wire[31:0]dq_door,output reg[255:0]dq_args,   // c22 direct NPU queue port
 input wire dr_valid,output wire dr_pop,input wire[127:0]dr_data,
 output wire index_set,output wire[31:0]index_value   // c25: command_index side channel
);
 localparam IDLE=0,INDEX=1,PSET=2,POLL=3,PERR=4,PDATA=5,PPOP=6,DECODE=7,NARGS=8,NDOOR=9,NPOLL=10,NHEAD=11,NVAL=12,NPOP=13,
  FETCH=22,FETCHED=23,VADDR=14,VDOOR=15,VPOLL=16,VERR=17,VPOP=18,DIAG=19,NEXT=20,STOP=21,NPUSH=24,NRESP=25;
 reg[4:0]state;reg[31:0]base,count,index,c[0:15],failure,lastvalue,timer;reg[2:0]step;reg half;reg[15:0]tag;reg done;
 reg[31:0]sequence_base,last_sequence,epoch_base;
 // claude_c02 c19: registered sum for the NVAL sequence check (c[10] and sequence_base are stable
 // from DECODE until NVAL, which is several bus transactions later).
 reg[31:0]sequence_expect;always @(posedge clk)sequence_expect<=c[10]+sequence_base;
 wire selected=addr==0||addr==4||addr==8||addr==12||addr==16||addr==20;
 assign ready=!rst;
 assign error=!selected||addr[1:0]!=0||(write&&(wstrb!=15||!(addr==0||addr==8||addr==12||addr==16)))||(write&&state!=IDLE);
 assign active=state!=IDLE;assign irq=done;
 always @*case(addr)
  4:rdata={30'b0,done,state==IDLE};8:rdata=base;12:rdata=count;16:rdata=failure;20:rdata=index;default:rdata=0;
 endcase
 assign fetch_valid=state==FETCH;assign fetch_address=base+(index<<6);assign fetched_ready=state==FETCHED;
 assign mvalid=state!=FETCH&&state!=FETCHED&&state!=IDLE&&state!=DECODE&&state!=NEXT&&state!=STOP&&state!=NPUSH&&state!=NRESP&&state!=INDEX;
 assign index_set=state==INDEX;assign index_value=index;
 // c22: direct queue port
 assign dq_valid=state==NPUSH;assign dq_door={8'b0,tag,c[0][7:0]};assign dr_pop=state==NRESP&&dr_valid;
 wire head_bad=dr_data[31:0]!={8'b0,tag,c[0][7:0]};wire[31:0]rsp_value=dr_data[63:32];
 wire sequence_bad=(c[0]==3||c[0]==4)&&c[10]!=0&&sequence_expect!=rsp_value;
 assign mwrite=state!=POLL&&state!=PERR&&state!=PDATA&&state!=NPOLL&&state!=NHEAD&&state!=NVAL&&state!=VPOLL&&state!=VERR;
 always @*begin
  maddr=0;mwdata=0;
  case(state)
   INDEX:begin maddr=12'h200;mwdata=index;end
   PSET:case(step)
    0:begin maddr=12'h808;mwdata=base+(index<<6)+(half?32:0);end
    1:begin maddr=12'h80c;mwdata=32;end
    2:begin maddr=12'h810;mwdata=0;end
    default:begin maddr=12'h800;mwdata=0;end
   endcase
   POLL:maddr=12'h804;
   PERR:maddr=12'h814;
   PDATA:maddr=12'h820+{step,2'b0};
   PPOP:begin maddr=12'h814;mwdata=1;end
   NARGS:begin
    maddr=12'h020+{step,2'b0};mwdata=c[step+1];
    if(c[0]==4&&step==0)mwdata=c[1]+sequence_base;
    if((c[0]==11&&step==7)||(c[0]==12&&step==6))mwdata=c[step+1]+epoch_base;
   end
   NDOOR:begin maddr=0;mwdata={8'b0,tag,c[0][7:0]};end
   NPOLL:maddr=4;
   NHEAD:maddr=16;
   NVAL:maddr=20;
   NPOP:begin maddr=12;mwdata=1;end
   VADDR:begin maddr=12'h408;mwdata=c[1];end
   VDOOR:maddr=12'h400;
   VPOLL:maddr=12'h404;
   VERR:maddr=12'h414;
   VPOP:begin maddr=12'h414;mwdata=1;end
   DIAG:case(step)
    0:begin maddr=12'h204;mwdata=c[1];end
    1:begin maddr=12'h208;mwdata=c[2];end
    2:begin maddr=12'h20c;mwdata=c[3];end
    default:begin maddr=12'h210;mwdata=c[0];end
   endcase
  endcase
 end
 integer i;
 always @(posedge clk)begin
  if(rst)begin state<=IDLE;base<=0;count<=0;index<=0;failure<=0;lastvalue<=0;step<=0;half<=0;tag<=0;done<=0;timer<=0;sequence_base<=0;last_sequence<=0;epoch_base<=0;for(i=0;i<16;i=i+1)c[i]<=0;end
  else begin
   if(valid&&ready&&write&&!error)case(addr)
    8:base<=wdata;12:count<=wdata;16:begin done<=0;failure<=0;end
    0:begin
     index<=0;failure<=0;done<=0;tag<=0;sequence_base<=last_sequence;epoch_base<=epoch_base+512;
     if(base[5:0]!=0||count==0||count>131072||{1'b0,base}+{9'b0,count[17:0],6'b0}>33'h40000000)begin failure<=1;done<=1;end
     else state<=INDEX;
    end
   endcase
   if(mvalid&&mready)begin
    if(merror)begin failure<=2;state<=STOP;end
    else case(state)
     PSET:if(step==3)state<=POLL;else step<=step+1'b1;
     POLL:if(mrdata[1])state<=PERR;
     PERR:begin if(mrdata!=0)failure<=3;step<=0;state<=mrdata==0?PDATA:PPOP;end
     PDATA:begin c[{half,step}]<=mrdata;if(step==7)state<=PPOP;else step<=step+1'b1;end
     PPOP:if(failure!=0)state<=STOP;else if(!half)begin half<=1;step<=0;state<=PSET;end else state<=DECODE;
     NARGS:if(step==7)state<=NDOOR;else step<=step+1'b1;
     NDOOR:state<=NPOLL;
     NPOLL:if(mrdata[1])state<=NHEAD;
     NHEAD:begin if(mrdata!={8'b0,tag,c[0][7:0]})failure<=4;state<=NVAL;end
     NVAL:begin
      lastvalue<=mrdata;
      if(c[0]==3&&failure==0)last_sequence<=mrdata;
      if((c[0]==3||c[0]==4)&&c[10]!=0&&sequence_expect!=mrdata)failure<=5;
      state<=NPOP;
     end
     NPOP:state<=failure==0?NEXT:STOP;
     VADDR:state<=VDOOR;VDOOR:state<=VPOLL;VPOLL:if(mrdata[1])state<=VERR;
     VERR:begin if(mrdata!=0)failure<={16'b0,8'h10,mrdata[7:0]};state<=VPOP;end
     VPOP:state<=failure==0?NEXT:STOP;
     DIAG:if(step==3)state<=NEXT;else step<=step+1'b1;
    endcase
   end
   if(state==INDEX)begin half<=0;step<=0;state<=FETCH;end   // c25: no bus write
   if(state==NPUSH&&dq_ready)state<=NRESP;
   if(state==NRESP&&dr_valid)begin
    lastvalue<=rsp_value;
    if(c[0]==3&&failure==0&&!head_bad)last_sequence<=rsp_value;
    if(sequence_bad)failure<=5;else if(head_bad)failure<=4;
    state<=(failure==0&&!head_bad&&!sequence_bad)?NEXT:STOP;
   end
   if(state==FETCH&&fetch_ready)state<=FETCHED;
   if(state==FETCHED&&fetched_valid)begin
    if(fetched_error!=0)begin failure<=3;state<=STOP;end
    else begin for(i=0;i<16;i=i+1)c[i]<=fetched_data[i*32+:32];state<=DECODE;end
   end
   if(state==DECODE)begin
    step<=0;
    for(i=0;i<8;i=i+1)dq_args[i*32+:32]<=c[i+1];
    if(c[0]==4)dq_args[31:0]<=c[1]+sequence_base;
    if(c[0]==11)dq_args[255:224]<=c[8]+epoch_base;
    if(c[0]==12)dq_args[223:192]<=c[7]+epoch_base;
    if(c[0]>=1&&c[0]<=12)begin tag<=tag+1'b1;state<=NPUSH;end
    else if(c[0]==32'h100)state<=VADDR;
    else if(c[0]==32'h200||c[0]==32'h201)state<=DIAG;
    else if(c[0]==32'h300&&index<7)state<=NEXT;
    else begin failure<=6;state<=STOP;end
   end
   if(state==NEXT)begin if(index+1==count)begin done<=1;state<=IDLE;end else begin index<=index+1'b1;state<=INDEX;end end
   if(state==STOP)begin done<=1;state<=IDLE;end
   if(state==IDLE||state==INDEX)timer<=0;else timer<=timer+1'b1;
   if(state!=IDLE&&timer==40000000)begin failure<=7;state<=STOP;end
  end
 end
endmodule

// claude_c02 c19: registered request/response slice in front of the accelerator MMIO bus (CPU and DMA
// sequencer masters). The request (addr/data/write) is captured when the master asserts valid and held
// on the bus until the target's ready; the response (rdata/error) returns as a one-cycle registered
// ready. Breaks the combinational master -> target decode -> ready/rdata -> master loop.
// Same transaction order and contents; two cycles of latency per transaction.
module mmio_req_slice(
 input wire clk,rst,
 input wire s_tag,   // master identity (sequencer active): a response is delivered only to the master that issued it
 input wire s_valid,s_write,input wire[11:0]s_addr,input wire[31:0]s_wdata,input wire[3:0]s_wstrb,
 output wire s_ready,s_error,output wire[31:0]s_rdata,
 output wire m_valid,m_write,output wire[11:0]m_addr,output wire[31:0]m_wdata,output wire[3:0]m_wstrb,
 input wire m_ready,m_error,input wire[31:0]m_rdata
);
 reg busy,done,w,err;reg[11:0]a;reg[31:0]d,rd;reg[3:0]st;reg tg;
 assign m_valid=busy;assign m_write=w;assign m_addr=a;assign m_wdata=d;assign m_wstrb=st;
 assign s_ready=done&&tg==s_tag;assign s_error=err;assign s_rdata=rd;
 always @(posedge clk)begin
  if(rst)begin busy<=0;done<=0;w<=0;err<=0;a<=0;d<=0;rd<=0;st<=0;tg<=0;end
  else begin
   done<=0;
   // done blocks a re-capture: the master changes its request on the edge that consumes done.
   if(!busy&&!done&&s_valid)begin busy<=1;w<=s_write;a<=s_addr;d<=s_wdata;st<=s_wstrb;tg<=s_tag;end
   else if(busy&&m_ready)begin busy<=0;done<=1;rd<=m_rdata;err<=m_error;end
  end
 end
endmodule
