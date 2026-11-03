`timescale 1ns/1ps
module rv32_core # (parameter LOCAL_FORMATTED_LOAD=0, TARGET_PAIR_FETCH=0, LATE_ALU=1, YOUNG_MEMORY=1, YOUNG_MULDIV=1, DUAL_ENABLE=1, PAIR_FETCH=0, parameter RESET_PC = 32'h00000000,
    parameter MEM_RESPONSE_FORWARD = 1, parameter PREDICT_ENABLE = 1, parameter MACHINE_ENABLE = 0, parameter M_ENABLE = 0, parameter FENCEI_ENABLE = 0) (
    input wire clk, rst_n,
    input wire irq_external,irq_timer,irq_software,
    output wire i_valid, output wire [31:0] i_addr,
    output wire [31:0] i_pair_addr,output wire [31:0] i_lookahead_addr,
    input wire i_ready, input wire [31:0] i_rdata, input wire i_error,
    output wire d_valid, d_write, output wire [31:0] d_addr, d_wdata,
    output wire [3:0] d_wstrb, output wire[31:0] d_lookahead_addr,
    output wire d_prepare_valid,d_prepare_write,
    output wire[31:0]d_prepare_addr,output wire[3:0]d_prepare_wstrb,
    input wire i_pair_valid, input wire [31:0] i_rdata1,
    output reg retire1_valid, output reg [31:0] retire1_pc,retire1_insn,
    output reg [4:0] retire1_rd, output reg [31:0] retire1_data,retire1_next_pc,
    input wire d_ready, input wire [31:0] d_rdata, input wire d_error,
    output wire[2:0]d_prepare_size,
    input wire local_load_valid,input wire[31:0]local_load_data,local_raw_load_data,
    output reg halted, output reg [31:0] trap_cause, trap_pc, trap_value,
    output reg retire_valid, output reg [31:0] retire_pc, retire_insn,
    output reg [4:0] retire_rd, output reg [31:0] retire_data, retire_next_pc,
    output reg [63:0] cycle_count, instret_count,
    output reg [63:0] stall_count, flush_count, forward_count,
    output wire if_stage_valid, ex_stage_valid, wb_stage_valid,
    output wire pipeline_stall, pipeline_flush, instruction_fence
);
    // S08: F0/F1 fetch, F2 decode, D RF/pair, O operand select, X execute,
    // M memory/redirect qualification, W architectural retirement.
    // Initial bus wrapper is inherited; this does NOT claim a 200MHz implementation.
    localparam K_ALU=0,K_BRANCH=1,K_JAL=2,K_JALR=3,K_LOAD=4,K_STORE=5,K_MD=6,K_CSR=7,K_FENCE=8,K_CLMUL=9;
    // Packed item layout explicitly lowered to 363 bits for ADS.

    wire[63:0]cl_product;
    localparam IW=363;
    reg [362:0] f20,f21,d0,d1,o0,o1,x0,x1,m0,m1,w0,w1;
    // Two parity banks, one write per bank; no full-queue shift network.
    reg [IW-1:0] queue_even[0:7],queue_odd[0:7];reg[4:0]queue_count;
    reg[3:0]queue_space_q;wire[4:0]queue_next_count;
    reg[11:0]x_csr_sel0_q,x_csr_sel1_q;
    reg[3:0]qhead,qtail;wire[3:0]qhead_next=qhead+1'b1,qtail_next=qtail+1'b1;
    reg [362:0] qhead0,qhead1,dx0,dx1,ox0,ox1,xm0,xm1,mw0,mw1,mf1,wc1;
    reg [31:0] regs[0:31];
    // Low 32 bits are identical for signed/unsigned MUL. One physical
    // pipeline serves either lane; existing pairing forbids two complex owners.
    reg[31:0]mul00_q;reg[15:0]mul01_q,mul10_q;
    // Exact three-input modular reduction, avoiding two serial APM adders.
    wire[15:0]mul_sum=mul00_q[31:16]^mul01_q^mul10_q;
    wire[15:0]mul_carry=((mul00_q[31:16]&mul01_q)|(mul00_q[31:16]&mul10_q)|(mul01_q&mul10_q))<<1;
    wire[15:0]mul_upper=mul_sum+mul_carry;
    wire[31:0]mul_low_result={mul_upper,mul00_q[15:0]};
    wire[31:0]mul_a=(x0[345:342]==K_MD && x0[322:320]==0) ? x0[191:160] : x1[191:160];
    wire[31:0]mul_b=(x0[345:342]==K_MD && x0[322:320]==0) ? x0[159:128] : x1[159:128];
    reg [31:0] csr_mtvec,csr_mscratch,csr_mepc,csr_mcause,csr_mtval,csr_mstatus,csr_mie;
    reg trap_pending;reg req_valid,req_kill,redirect_pending;reg redirect;reg[31:0]redirect_target;
    reg [31:0] req_pc,next_fetch_pc,redirect_pc;
    reg [255:0] btb_valid;
    reg [21:0] btb_tag[0:255] /* synthesis syn_ramstyle="lut_ram" */;
    reg [31:0] btb_target[0:255] /* synthesis syn_ramstyle="lut_ram" */;
    reg [1:0] btb_count[0:255] /* synthesis syn_ramstyle="lut_ram" */;
    reg btb_sequential[0:255] /* synthesis syn_ramstyle="lut_ram" */;
    reg train_v,train_taken,train_control;
    reg [31:0] train_pc,train_target;
    wire [31:0] req_pc1=req_pc+4;
    // AR: prediction and instruction RAM are sampled on the same edge.
    // Explicit write-through matches the original post-edge predictor training.
    reg[31:0]pred0 /* synthesis syn_preserve=1 */;
    reg[31:0]pred1 /* synthesis syn_preserve=1 */;
    reg pred0_seq /* synthesis syn_preserve=1 */;
    reg pred1_seq /* synthesis syn_preserve=1 */;
    reg[31:0]prediction_tag;
    wire[31:0]predict_request_addr;
    wire predict_capture;
    function automatic[32:0]predict_ahead(input[31:0]pc);
      reg valid,sequential;reg[21:0]tag;reg[31:0]target;reg[1:0]count;
      begin
        valid=btb_valid[pc[9:2]];tag=btb_tag[pc[9:2]];
        target=btb_target[pc[9:2]];count=btb_count[pc[9:2]];sequential=btb_sequential[pc[9:2]];
        if(train_v && train_pc[9:2]==pc[9:2])begin
          valid=train_control;tag=train_pc[31:10];target=train_target;sequential=train_target==train_pc+32'd4;
          if(!btb_valid[pc[9:2]] || btb_tag[pc[9:2]]!=train_pc[31:10])count=train_taken ? 2 : 1;
          else if(train_taken)begin if(count!=3)count=count+1'b1;end
          else if(count!=0)count=count-1'b1;
        end
        if(instruction_fence)valid=0;
        predict_ahead=PREDICT_ENABLE && valid && tag==pc[31:10] && count[1] ? {sequential,target} : {1'b1,pc+32'd4};
      end
    endfunction
    always @(posedge clk)begin
      if(!rst_n)begin pred0<=RESET_PC+4;pred1<=RESET_PC+8;pred0_seq<=1;pred1_seq<=1;prediction_tag<=RESET_PC;end
      else if(predict_capture)begin
        {pred0_seq,pred0}<=predict_ahead(predict_request_addr);
        {pred1_seq,pred1}<=predict_ahead(predict_request_addr+4);
        prediction_tag<=predict_request_addr;
      end
    end
    wire fetched_pair=PAIR_FETCH && i_pair_valid && pred0_seq && !i_error;
    wire [31:0] fetch_next=fetched_pair ? pred1 : pred0;
    assign i_valid=rst_n && req_valid && !halted;
    assign i_addr=req_pc; assign i_pair_addr=req_pc1;
    // The full-cycle TCM samples the next address on the same edge that accepts
    // the current tagged response. Cache wrapper leaves this port unconnected.

    function automatic [362:0] decode(input [31:0] pc,insn,pred,input fault);
      reg [362:0] t; reg[6:0] op,f7; reg[2:0] f;
      begin
        t=363'b0;t[362]=1;t[319:288]=pc;t[287:256]=insn;t[255:224]=pred;t[63:32]=pc+4;
        t[337:333]=insn[19:15];t[332:328]=insn[24:20];t[327:323]=insn[11:7];t[322:320]=insn[14:12];
        t[358]=fault;t[31:0]=fault ? 1 : 2;
        t[223:192]={{20{insn[31]}},insn[31:20]};op=insn[6:0];f7=insn[31:25];f=insn[14:12];
        case(f)
          0:t[341:338]=(op==7'h33 && f7==7'h20) ? 1 : 0;
          1:t[341:338]=2;2:t[341:338]=3;3:t[341:338]=4;4:t[341:338]=5;
          5:t[341:338]=insn[30] ? 7 : 6;6:t[341:338]=8;7:t[341:338]=9;
        endcase
        case(op)
          7'h37,7'h17:begin t[361]=1;t[223:192]={insn[31:12],12'b0};t[341:338]=0;end
          7'h13:begin t[361]=1;t[360]=1;
            if((f==1 && f7!=0)||(f==5 && f7!=0 && f7!=7'h20))t[358]=1;end
          7'h33:begin t[361]=1;t[360]=1;t[359]=1;
            if(f7==1 && M_ENABLE)t[345:342]=K_MD;
            else if(f7==7'h05 && (f==1 || f==2 || f==3))t[345:342]=K_CLMUL;
            else if(!(f7==0 || (f7==7'h20 && (f==0 || f==5))))t[358]=1;end
          7'h03:begin t[345:342]=K_LOAD;t[361]=1;t[360]=1;
            if(!(f==0 || f==1 || f==2 || f==4 || f==5))t[358]=1;end
          7'h23:begin t[345:342]=K_STORE;t[360]=1;t[359]=1;
            t[223:192]={{20{insn[31]}},insn[31:25],insn[11:7]};if(f>2)t[358]=1;end
          7'h63:begin t[345:342]=K_BRANCH;t[360]=1;t[359]=1;
            t[223:192]={{19{insn[31]}},insn[31],insn[7],insn[30:25],insn[11:8],1'b0};
            if(f==2 || f==3)t[358]=1;end
          7'h6f:begin t[345:342]=K_JAL;t[361]=1;
            t[223:192]={{11{insn[31]}},insn[31],insn[19:12],insn[20],insn[30:21],1'b0};end
          7'h67:begin t[345:342]=K_JALR;t[361]=1;t[360]=1;if(f!=0)t[358]=1;end
          7'h73:begin t[345:342]=K_CSR;t[361]=f!=0;t[360]=f!=0 && !f[2];
            if(f==0)begin t[358]=1;t[31:0]=insn==32'h00100073 ? 3 : 11;end
            if(f==4)t[358]=1;end
          7'h0f:begin t[345:342]=K_FENCE;if(f>1)t[358]=1;end
          default:t[358]=1;
        endcase
        t[352]=pred==pc+4;t[353]=pred!=pc+4;
        // Branch target and equality are prepared at the next queue-write boundary.
        decode=t;
      end
    endfunction
    function automatic [362:0] prepare_front(input [362:0] t);
      reg [362:0] r;
      begin
        r=t;
        if(t[345:342]==K_BRANCH || t[345:342]==K_JAL)begin
          r[95:64]=t[319:288]+t[223:192];r[351]=t[255:224]==t[319:288]+t[223:192];
          if(t[345:342]==K_JAL)r[353]=t[255:224]!=t[319:288]+t[223:192];
        end
        prepare_front=r;
      end
    endfunction
    // AN: independent arithmetic/compare/shifter cones, explicit result OR.
    // Keep the completed adder net so a one-bit SLT select cannot be absorbed
    // into the adder carry input (observed AM mapped comparator->adder chain).
    function automatic [31:0] alu_value(input[31:0] a,b,input[3:0] op);
      reg[31:0] addsub_result /* synthesis syn_keep=1 */;
      reg[31:0] shift_left_result /* synthesis syn_keep=1 */;
      reg[31:0] shift_right_result /* synthesis syn_keep=1 */;
      reg lt_unsigned,lt_signed;
      begin
        addsub_result=a+(b^{32{op==1}})+(op==1);
        lt_unsigned=a<b;
        lt_signed=(a[31]^b[31]) ? a[31] : lt_unsigned;
        shift_left_result=a<<b[4:0];
        shift_right_result=$signed({(op==7)&&a[31],a})>>>b[4:0];
        alu_value=({32{op==0 || op==1}}&addsub_result)|
          ({32{op==2}}&shift_left_result)|
          {31'b0,((op==3)&&lt_signed)||((op==4)&&lt_unsigned)}|
          ({32{op==5}}&(a^b))|
          ({32{op==6 || op==7}}&shift_right_result)|
          ({32{op==8}}&(a|b))|({32{op==9}}&(a&b))|
          ({32{op==10}}&{{24{a[7]}},a[7:0]})|
          ({32{op==11}}&{{16{a[15]}},a[15:0]})|
          ({32{op==12}}&{32{a[0]}})|
          ({32{op==13}}&{24'b0,a[7:0]})|
          ({32{op==14}}&{16'b0,a[15:0]})|
          ({32{op==15}}&{31'b0,a[0]});
      end
    endfunction
    // BZ: bypass loops only contain add/sub/boolean/constant extensions.
    // Variable shifts and comparisons execute in X, never in a late feedback ALU.
    function automatic simple_late(input[3:0] op);
      begin simple_late=(op==0 || op==1 || op==5 || op==8 || op==9 || op>=10);end
    endfunction
    function automatic[31:0] late_alu_value(input[31:0] a,b,input[3:0] op);
      reg[31:0]sum_result /* synthesis syn_keep=1 */;
      reg[31:0]adjusted_b;
      reg[16:0]sum_lo /* synthesis syn_keep=1 */;
      reg[15:0]sum_hi0 /* synthesis syn_keep=1 */;
      reg[15:0]sum_hi1 /* synthesis syn_keep=1 */;
      begin
        // Exact modular 32-bit add/sub. Two upper alternatives run in parallel;
        // the lower carry selects one, replacing the long 32-bit ripple chain.
        adjusted_b=b^{32{op==1}};
        sum_lo={1'b0,a[15:0]}+{1'b0,adjusted_b[15:0]}+(op==1);
        sum_hi0=a[31:16]+adjusted_b[31:16];
        sum_hi1=a[31:16]+adjusted_b[31:16]+16'd1;
        sum_result={sum_lo[16] ? sum_hi1 : sum_hi0,sum_lo[15:0]};
        late_alu_value=({32{op==0 || op==1}}&sum_result)|({32{op==5}}&(a^b))|
          ({32{op==8}}&(a|b))|({32{op==9}}&(a&b))|
          ({32{op==10}}&{{24{a[7]}},a[7:0]})|({32{op==11}}&{{16{a[15]}},a[15:0]})|
          ({32{op==12}}&{32{a[0]}})|({32{op==13}}&{24'b0,a[7:0]})|
          ({32{op==14}}&{16'b0,a[15:0]})|({32{op==15}}&{31'b0,a[0]});
      end
    endfunction
    // CA: decode the CSR address at O/X, but read its live architectural
    // value in X exactly as before. Counter sampling time is unchanged.
    function automatic[11:0] csr_decode(input[11:0] a);
      begin csr_decode=0;case(a)
        12'h300:csr_decode[0]=1;12'h301:csr_decode[1]=1;
        12'h304:csr_decode[2]=1;12'h305:csr_decode[3]=1;
        12'h340:csr_decode[4]=1;12'h341:csr_decode[5]=1;
        12'h342:csr_decode[6]=1;12'h343:csr_decode[7]=1;
        12'hc00,12'hb00:csr_decode[8]=1;12'hc80,12'hb80:csr_decode[9]=1;
        12'hc02,12'hb02:csr_decode[10]=1;12'hc82,12'hb82:csr_decode[11]=1;
        default:csr_decode=0;
      endcase end
    endfunction
    function automatic[31:0] csr_selected(input[11:0] sel,input[63:0] cyc,ins,
      input[31:0] tv,sc,ep,ca,va,st,ie);
      begin csr_selected=({32{sel[0]}}&st)|({32{sel[1]}}&32'h40001100)|
        ({32{sel[2]}}&ie)|({32{sel[3]}}&tv)|({32{sel[4]}}&sc)|
        ({32{sel[5]}}&ep)|({32{sel[6]}}&ca)|({32{sel[7]}}&va)|
        ({32{sel[8]}}&cyc[31:0])|({32{sel[9]}}&cyc[63:32])|
        ({32{sel[10]}}&ins[31:0])|({32{sel[11]}}&ins[63:32]);end
    endfunction
    function automatic [31:0] csr_value(input[11:0] a,input[63:0] cycle_count,instret_count,input[31:0] csr_mtvec,csr_mscratch,csr_mepc,csr_mcause,csr_mtval,csr_mstatus,csr_mie);
      begin case(a)
        12'h300:csr_value=csr_mstatus;12'h301:csr_value=32'h40001100;
        12'h304:csr_value=csr_mie;12'h305:csr_value=csr_mtvec;
        12'h340:csr_value=csr_mscratch;12'h341:csr_value=csr_mepc;
        12'h342:csr_value=csr_mcause;12'h343:csr_value=csr_mtval;
        12'hc00,12'hb00:csr_value=cycle_count[31:0];12'hc80,12'hb80:csr_value=cycle_count[63:32];
        12'hc02,12'hb02:csr_value=instret_count[31:0];12'hc82,12'hb82:csr_value=instret_count[63:32];
        default:csr_value=0;
      endcase end
    endfunction
    function automatic [362:0] execute(input [362:0] t,input[31:0] csr_read);
      reg [362:0] r;reg[31:0] a,b;reg take;
      begin r=t;r[63:32]=t[319:288]+4;take=0;
        a=t[262:256]==7'h37 ? 0 : t[262:256]==7'h17 ? t[319:288] : t[191:160];
        b=t[359] ? t[159:128] : t[223:192];
        case(t[345:342])
          K_ALU:r[127:96]=alu_value(a,b,t[341:338]);
          K_LOAD,K_STORE:begin r[95:64]=t[191:160]+t[223:192];
            if(((t[322:320]==1 || t[322:320]==5) && r[64])||(t[322:320]==2 && r[65:64]!=0))begin
              r[358]=1;r[31:0]=t[345:342]==K_STORE ? 6 : 4;end
          end
          K_BRANCH:begin
            case(t[322:320])
              0:take=t[191:160]==t[159:128];1:take=t[191:160]!=t[159:128];
              4:take=$signed(t[191:160])<$signed(t[159:128]);5:take=$signed(t[191:160])>=$signed(t[159:128]);
              6:take=t[191:160]<t[159:128];7:take=t[191:160]>=t[159:128];default:take=0;
            endcase
            if(take)r[63:32]=t[95:64];
            r[353]=take ? !t[351] : !t[352];
          end
          K_JAL:begin r[127:96]=t[319:288]+4;r[63:32]=t[95:64];end
          K_JALR:begin r[127:96]=t[319:288]+4;r[63:32]=(t[191:160]+t[223:192])&32'hfffffffe;r[353]=r[63:32]!=t[255:224];end
          K_CSR:r[127:96]=csr_read;
          default:begin end
        endcase
        if(r[33:32]!=0)begin r[358]=1;r[31:0]=0;end
        execute=r;
      end
    endfunction
    function automatic hit(input [362:0] p,input[4:0] r);
      hit=p[362] && p[361] && p[327:323]!=0 && p[327:323]==r;
    endfunction
    function automatic [31:0] preselected(input[1:0] sel,input[31:0] old,v0,v1);
      preselected=({32{sel==2}}&v1)|({32{sel==1}}&v0)|({32{sel==0}}&old);
    endfunction
    function automatic depends(input [362:0] p,input [362:0] t);
      depends=(t[360] && hit(p,t[337:333])) || (t[359] && hit(p,t[332:328]));
    endfunction
    function automatic branch_taken(input[31:0] a,b,input[2:0] f);
      begin case(f)
       0:branch_taken=a==b;1:branch_taken=a!=b;
       4:branch_taken=$signed(a)<$signed(b);5:branch_taken=$signed(a)>=$signed(b);
       6:branch_taken=a<b;7:branch_taken=a>=b;default:branch_taken=0;
      endcase end
    endfunction
    function automatic is_control(input [362:0] t);
      is_control=t[345:342]==K_BRANCH || t[345:342]==K_JAL || t[345:342]==K_JALR;
    endfunction
    function automatic is_complex(input [362:0] t);
      is_complex=t[345:342]==K_LOAD || t[345:342]==K_STORE || t[345:342]==K_MD || t[345:342]==K_CLMUL;
    endfunction
    function automatic [31:0] read_rf(input[4:0] r,input[31:0] stored,input [362:0] c0,c1);
      read_rf=r==0 ? 0 : hit(c1,r) ? c1[127:96] : hit(c0,r) ? c0[127:96] : stored;
    endfunction

    // AM: local M-stage transaction qualification captured with the data.
    // Late branches now wait in O and resolve in X; W data cannot cancel LSU.
    reg m_fence_q;reg m_memory0_q,m_memory1_q,m_squash_q,m_fault_q;
    wire m_mem0=m0[362] && m_memory0_q;
    wire m_mem1=m1[362] && m_memory1_q;
    wire m_mem=m_mem0 || m_mem1;
    wire squash_younger=m0[362] && m_squash_q;
    wire squash_memory=squash_younger && m_mem1;
    // AO: select the sole LSU owner at the X/M register boundary.
    // Memory address/data/size/write no longer mux on the M memory-owner bit.
    reg[31:0]mem_addr,mem_data;reg[2:0]mem_f3;reg mem_write_q;
    wire x_mem1=xm1[362] && (xm1[345:342]==K_LOAD || xm1[345:342]==K_STORE);
    // AP: complete immutable bus attributes alongside X/M payload.
    // SoC decodes this snapshot once; M completion never redecodes a wide address.
    wire[2:0] prepare_f3=x_mem1 ? xm1[322:320] : xm0[322:320];
    assign d_prepare_size=prepare_f3;
    assign d_prepare_addr=x_mem1 ? xm1[95:64] : xm0[95:64];
    assign d_prepare_write=x_mem1 ? xm1[345:342]==K_STORE : xm0[345:342]==K_STORE;
    assign d_prepare_wstrb=prepare_f3==0 ? 4'b0001<<d_prepare_addr[1:0] :
      prepare_f3==1 ? 4'b0011<<d_prepare_addr[1:0] : 4'b1111;
    assign d_valid=rst_n && !halted && !redirect && m_mem && !squash_memory && !m_fault_q;
    assign d_addr=mem_addr;
    assign d_write=mem_write_q;
    assign d_wdata=mem_data<<(mem_addr[1:0]*8);
    assign d_wstrb=mem_f3==0 ? 4'b0001<<mem_addr[1:0] : mem_f3==1 ? 4'b0011<<mem_addr[1:0] : 4'b1111;
    wire x_fire,m_fire,m_error;
    // BX: address/format qualification is captured with the same X/M LSU
    // payload. Each returned byte only crosses one local select and the OR merge.
    // No additional read cycle, no fictitious memory completion.
    reg[3:0]ld_byte_q,ld_signbyte_q;
    reg[1:0]ld_half_q,ld_signhalf_q;
    reg ld_word_q;
    wire[1:0]ld_off=d_prepare_addr[1:0];
    always @(posedge clk)begin
      if(x_fire)begin
        ld_byte_q<=(prepare_f3==0 || prepare_f3==4) ? (4'b0001<<ld_off) : 4'b0;
        ld_signbyte_q<=prepare_f3==0 ? (4'b0001<<ld_off) : 4'b0;
        ld_half_q<=(prepare_f3==1 || prepare_f3==5) ? (2'b01<<ld_off[1]) : 2'b0;
        ld_signhalf_q<=prepare_f3==1 ? (2'b01<<ld_off[1]) : 2'b0;
        ld_word_q<=prepare_f3==2;
      end
    end
    wire[7:0]ld_byte=({8{ld_byte_q[0]}}&d_rdata[7:0])|({8{ld_byte_q[1]}}&d_rdata[15:8])|
      ({8{ld_byte_q[2]}}&d_rdata[23:16])|({8{ld_byte_q[3]}}&d_rdata[31:24]);
    wire[15:0]ld_half=({16{ld_half_q[0]}}&d_rdata[15:0])|({16{ld_half_q[1]}}&d_rdata[31:16]);
    wire ld_s8=|(ld_signbyte_q & {d_rdata[31],d_rdata[23],d_rdata[15],d_rdata[7]});
    wire ld_s16=|(ld_signhalf_q & {d_rdata[31],d_rdata[15]});
    wire[31:0]slow_load_data={24'b0,ld_byte}|{16'b0,ld_half}|({32{ld_word_q}}&d_rdata)|
      {{24{ld_s8}},8'b0}|{{16{ld_s16}},16'b0};
    // CB: local TCM formatting and peripheral load formatting merge only here.
    // The SoC removes TCM from the peripheral data mux. No extra load latency.
    wire[31:0]load_data=slow_load_data | (LOCAL_FORMATTED_LOAD ? local_load_data : 32'b0);
`ifndef SYNTHESIS
    wire[31:0]reference_raw=LOCAL_FORMATTED_LOAD && local_load_valid ? local_raw_load_data : d_rdata;
    wire [31:0] shifted=reference_raw>>(mem_addr[1:0]*8);
    reg [31:0] load_reference;
    always @*case(mem_f3)
      0:load_reference={{24{shifted[7]}},shifted[7:0]};1:load_reference={{16{shifted[15]}},shifted[15:0]};
      2:load_reference=shifted;4:load_reference={24'b0,shifted[7:0]};5:load_reference={16'b0,shifted[15:0]};default:load_reference=0;
    endcase

    always @(posedge clk)if(rst_n && m_fire && m_mem && !m_error && !squash_memory && !mem_write_q)
      if(load_data!==load_reference)$fatal(1,"BX decoded load lanes differ from original alignment/sign semantics");
`endif
    wire m_can=!m0[362] || !m_mem || squash_memory || d_ready || m_fault_q;
    assign m_fire=m0[362] && m_can && !halted && !redirect;
    assign m_error=m0[358] || (m1[362] && m1[358] && !squash_younger) || (m_mem && !squash_memory && d_ready && d_error);
    wire [31:0] actual_next=mw1[362] ? mw1[63:32] : mw0[63:32];
    wire [31:0] predicted_next=mw1[362] ? m1[255:224] : m0[255:224];
    wire redirect_now=m_fire && !m_error && (mw0[353] || (mw1[362] && mw1[353]));
    wire stop_now=m_fire && m_error;
    // Serial FENCE has no younger lane and no memory transaction. Do not
    // feed arbitrary memory completion/branch cancellation into its qualification.
    assign instruction_fence=m_fence_q && !halted && !redirect;
    assign pipeline_flush=redirect;
    always @*begin
      mw0=m0;mw1=m1;mw1[350]=m_mem0 && m0[345:342]==K_LOAD && m1[357] && m1[345:342]==K_ALU;
      if(m0[354])begin
        mw0[191:160]=preselected(m0[349:348],m0[191:160],w0[127:96],w1[127:96]);mw0[159:128]=preselected(m0[347:346],m0[159:128],w0[127:96],w1[127:96]);
        if(m0[345:342]==K_BRANCH)begin
          mw0[63:32]=branch_taken(mw0[191:160],mw0[159:128],m0[322:320]) ? m0[95:64] : m0[319:288]+4;
          mw0[353]=branch_taken(mw0[191:160],mw0[159:128],m0[322:320]) ? !m0[351] : !m0[352];
        end else begin
        mw0[127:96]=late_alu_value(mw0[262:256]==7'h37 ? 0 : mw0[262:256]==7'h17 ? mw0[319:288] : mw0[191:160],mw0[359] ? mw0[159:128] : mw0[223:192],mw0[341:338]);
        end
      end
      if(m1[354])begin
        mw1[191:160]=preselected(m1[349:348],m1[191:160],w0[127:96],w1[127:96]);mw1[159:128]=preselected(m1[347:346],m1[159:128],w0[127:96],w1[127:96]);
        if(m1[345:342]==K_BRANCH)begin
          mw1[63:32]=branch_taken(mw1[191:160],mw1[159:128],m1[322:320]) ? m1[95:64] : m1[319:288]+4;
          mw1[353]=branch_taken(mw1[191:160],mw1[159:128],m1[322:320]) ? !m1[351] : !m1[352];
        end else begin
        mw1[127:96]=late_alu_value(mw1[262:256]==7'h37 ? 0 : mw1[262:256]==7'h17 ? mw1[319:288] : mw1[191:160],mw1[359] ? mw1[159:128] : mw1[223:192],mw1[341:338]);
        end
      end
      if(m0[345:342]==K_MD && m0[322:320]==0)mw0[127:96]=mul_low_result;
      if(m1[345:342]==K_MD && m1[322:320]==0)mw1[127:96]=mul_low_result;
      if(m0[345:342]==K_CLMUL)mw0[127:96]=cl_result(cl_product,m0[322:320]);
      if(m1[345:342]==K_CLMUL)mw1[127:96]=cl_result(cl_product,m1[322:320]);
      if(m_mem0 && m0[345:342]==K_LOAD)mw0[127:96]=load_data;
      if(m_mem1 && m1[345:342]==K_LOAD)mw1[127:96]=load_data;
      if(m1[357] && m1[345:342]==K_ALU && !m_mem0)begin
        mw1[127:96]=late_alu_value(m1[356] ? m0[127:96] : m1[191:160],
          m1[359] ? (m1[355] ? m0[127:96] : m1[159:128]) : m1[223:192],m1[341:338]);
      end
      // A load-dependent branch is never an intra-pair late operation. Keep
      // its nonexistent RAM->branch cone out of the synthesized graph explicitly.
      if(m1[357] && m1[345:342]==K_BRANCH)begin
        mw1[63:32]=branch_taken(m1[356] ? m0[127:96] : m1[191:160],m1[355] ? m0[127:96] : m1[159:128],m1[322:320]) ? m1[95:64] : m1[319:288]+4;
        mw1[353]=branch_taken(m1[356] ? m0[127:96] : m1[191:160],m1[355] ? m0[127:96] : m1[159:128],m1[322:320]) ? !m1[351] : !m1[352];
      end
      // A younger load uses only the existing LSU. A wrong older control suppresses
      // request, younger exception and retirement; lookahead TCM reads are side-effect-free.
      if(m_squash_q || (m0[354] && m0[345:342]==K_BRANCH && mw0[353]))mw1[362]=0;
    end

    // Speculative operand forwarding need not wait for older branch outcome.
    // Actual younger retirement still uses qualified mw1.valid. Registered
    // redirect suppresses all younger memory and commit on the following edge.
    always @*begin mf1=mw1;mf1[362]=m1[362];end
    always @*begin
      wc1=w1;
      if(w1[362] && w1[350])wc1[127:96]=late_alu_value(w1[356] ? w0[127:96] : w1[191:160],
        w1[359] ? (w1[355] ? w0[127:96] : w1[159:128]) : w1[223:192],w1[341:338]);
    end

    // Standard Zbc: shared one-operation/cycle X/M polynomial multiplier.
    // First stage: eight independent four-bit partial polynomials (35 bits).
    // Second stage: balanced XOR of aligned partials and the architectural slice.
    // Data banks have no reset tree; only a valid X/M owner can consume them.
    wire[31:0]cl_a=x0[345:342]==K_CLMUL ? x0[191:160] : x1[191:160];
    wire[31:0]cl_b=x0[345:342]==K_CLMUL ? x0[159:128] : x1[159:128];
    reg[34:0]cl_q[0:7];genvar clg;
    generate for(clg=0;clg<8;clg=clg+1)begin:cl_group
      always @(posedge clk)if(rst_n && x_fire && (x0[345:342]==K_CLMUL || (x1[362] && x1[345:342]==K_CLMUL)))
        cl_q[clg]<=({35{cl_b[4*clg]}}&{3'b0,cl_a}) ^ ({35{cl_b[4*clg+1]}}&{2'b0,cl_a,1'b0}) ^
                    ({35{cl_b[4*clg+2]}}&{1'b0,cl_a,2'b0}) ^ ({35{cl_b[4*clg+3]}}&{cl_a,3'b0});
    end endgenerate
    assign cl_product=({29'b0,cl_q[0]}<<0)^({29'b0,cl_q[1]}<<4)^({29'b0,cl_q[2]}<<8)^({29'b0,cl_q[3]}<<12)^
                        ({29'b0,cl_q[4]}<<16)^({29'b0,cl_q[5]}<<20)^({29'b0,cl_q[6]}<<24)^({29'b0,cl_q[7]}<<28);
    function automatic[31:0]cl_result(input[63:0]product,input[2:0]f);
      begin case(f)1:cl_result=product[31:0];2:cl_result=product[62:31];3:cl_result=product[63:32];default:cl_result=0;endcase end
    endfunction
    wire md_done,md_busy;wire[31:0]md_result;
    reg md_launched,md_held;reg[31:0]md_saved;
    reg x_long_md_q,x_block0_q,x_block1_q,x_latewb_q;
    wire x_md=x_long_md_q;
    wire x_md1=x1[362] && x1[345:342]==K_MD;
    wire md_start=x_md && !md_launched && !redirect && !halted;
    rv32_muldiv multiply_divide(.clk(clk),.rst_n(rst_n && !redirect),.start(md_start),
      .op(x_md1 ? x1[322:320] : x0[322:320]),.a(x_md1 ? x1[191:160] : x0[191:160]),.b(x_md1 ? x1[159:128] : x0[159:128]),
      .busy(md_busy),.done(md_done),.result(md_result));
    wire x_can=!x0[362] || (m_can && (!x_md || md_done || md_held));
    assign x_fire=x0[362] && x_can && !redirect && !halted;
    assign d_prepare_valid=x_fire;
    // Only a side-effect-free TCM read is speculative. Stores/MMIO still complete in M.
    assign d_lookahead_addr=x_fire && (xm0[345:342]==K_LOAD || xm0[345:342]==K_STORE) ? xm0[95:64] :
      x_fire && xm1[362] && (xm1[345:342]==K_LOAD || xm1[345:342]==K_STORE) ? xm1[95:64] : mem_addr;
    always @*begin
      xm0=execute(x0,csr_selected(x_csr_sel0_q,cycle_count,instret_count,csr_mtvec,csr_mscratch,csr_mepc,csr_mcause,csr_mtval,csr_mstatus,csr_mie));xm1=execute(x1,csr_selected(x_csr_sel1_q,cycle_count,instret_count,csr_mtvec,csr_mscratch,csr_mepc,csr_mcause,csr_mtval,csr_mstatus,csr_mie));
      if(x0[354])begin
        xm0[191:160]=select_operand(x0[337:333],x0[191:160],w0,wc1,363'b0,363'b0);
        xm0[159:128]=select_operand(x0[332:328],x0[159:128],w0,wc1,363'b0,363'b0);
      end
      if(x1[354])begin
        xm1[191:160]=select_operand(x1[337:333],x1[191:160],w0,wc1,363'b0,363'b0);
        xm1[159:128]=select_operand(x1[332:328],x1[159:128],w0,wc1,363'b0,363'b0);
      end
      xm0[349:348]=hit(m1,x0[337:333]) ? 2 : hit(m0,x0[337:333]) ? 1 : 0;
      xm0[347:346]=hit(m1,x0[332:328]) ? 2 : hit(m0,x0[332:328]) ? 1 : 0;
      xm1[349:348]=hit(m1,x1[337:333]) ? 2 : hit(m0,x1[337:333]) ? 1 : 0;
      xm1[347:346]=hit(m1,x1[332:328]) ? 2 : hit(m0,x1[332:328]) ? 1 : 0;
      if(x0[345:342]==K_MD)xm0[127:96]=md_held ? md_saved : md_result;
      if(x1[345:342]==K_MD)xm1[127:96]=md_held ? md_saved : md_result;
    end
    function automatic [31:0] select_operand(input[4:0] r,input[31:0] old,input [362:0] p0,p1,c0,c1);
      reg h0,h1,h2,h3;
      begin
        h0=hit(p1,r);h1=hit(p0,r)&&!h0;h2=hit(c1,r)&&!h0&&!h1;h3=hit(c0,r)&&!h0&&!h1&&!h2;
        select_operand=({32{h0}}&p1[127:96])|({32{h1}}&p0[127:96])|({32{h2}}&c1[127:96])|({32{h3}}&c0[127:96])|
          ({32{r!=0&&!h0&&!h1&&!h2&&!h3}}&old);
      end
    endfunction
    function automatic [31:0] select_all(input[4:0] r,input[31:0] old,input [362:0] x0,x1,m0,m1,w0,w1);
      reg h0,h1,h2,h3,h4,h5;
      begin
        h0=hit(x1,r);h1=hit(x0,r)&&!h0;h2=hit(m1,r)&&!h0&&!h1;h3=hit(m0,r)&&!h0&&!h1&&!h2;
        h4=hit(w1,r)&&!h0&&!h1&&!h2&&!h3;h5=hit(w0,r)&&!h0&&!h1&&!h2&&!h3&&!h4;
        select_all=({32{h0}}&x1[127:96])|({32{h1}}&x0[127:96])|({32{h2}}&m1[127:96])|({32{h3}}&m0[127:96])|
          ({32{h4}}&w1[127:96])|({32{h5}}&w0[127:96])|({32{r!=0&&!h0&&!h1&&!h2&&!h3&&!h4&&!h5}}&old);
      end
    endfunction
    wire blocked_x0=x_block0_q;
    wire blocked_x1=x_block1_q;
    wire dep0=(blocked_x0 && depends(x0,o0)) || (blocked_x1 && depends(x1,o0));
    wire dep1=o1[362] && ((blocked_x0 && depends(x0,o1)) || (blocked_x1 && depends(x1,o1)));
    wire blocked_late_wb=x_latewb_q;
    wire defer0=dep0 && !(blocked_late_wb && depends(x1,o0)) && ((o0[345:342]==K_ALU && simple_late(o0[341:338])) || (o0[345:342]==K_BRANCH && !o0[358] && o0[65:64]==0 &&
      (!o1[362] || (o1[345:342]==K_ALU && !o1[358])))) && !(o1[362] && o1[357]);
    wire defer1=dep1 && !(blocked_late_wb && depends(x1,o1)) && ((o1[345:342]==K_ALU && simple_late(o1[341:338])) || (o1[345:342]==K_BRANCH && !o1[358] && o1[65:64]==0)) && !o1[357];
    wire o_hazard=(dep0 && !defer0) || (dep1 && !defer1) ||
      (m1[362] && mw1[350] && (depends(m1,o0) || (o1[362] && depends(m1,o1))));
    wire o_can=!o0[362] || (x_can && !o_hazard && m_can);
    wire o_fire=o0[362] && o_can && !redirect && !halted;
    // General RV32IM micro-op fusion, independent of program PC or values.
    // Both architectural instructions still retire, including the first shift's
    // intermediate result. The younger extension runs in parallel from the
    // older shift's original forwarded operand, avoiding a dependent M ALU.
    wire fuse_extend=o0[362] && o1[362] && o1[357] && !o0[358] && !o1[358] &&
      o0[262:256]==7'h13 && o1[262:256]==7'h13 &&
      o0[322:320]==1 && o1[322:320]==5 &&
      o0[196:192]==o1[196:192] &&
      (o0[196:192]==24 || o0[196:192]==16 || o0[196:192]==31);
    always @*begin
      ox0=o0;ox1=o1;ox0[354]=defer0;ox1[354]=defer1;
      ox0[191:160]=select_all(o0[337:333],o0[191:160],xm0,xm1,mw0,mf1,w0,wc1);
      ox0[159:128]=select_all(o0[332:328],o0[159:128],xm0,xm1,mw0,mf1,w0,wc1);
      ox1[191:160]=select_all(o1[337:333],o1[191:160],xm0,xm1,mw0,mf1,w0,wc1);
      ox1[159:128]=select_all(o1[332:328],o1[159:128],xm0,xm1,mw0,mf1,w0,wc1);
      if(fuse_extend)begin
        ox1[357]=0;ox1[354]=0;
        ox1[191:160]=ox0[191:160];
        case(o0[196:192])
          24:ox1[341:338]=o1[286] ? 10 : 13;
          16:ox1[341:338]=o1[286] ? 11 : 14;
          default:ox1[341:338]=o1[286] ? 12 : 15;
        endcase
      end
    end
    wire d_hazard=1'b0;
    wire y_hazard=1'b0;
    wire raw_a=d0[361] && d0[327:323]!=0 && d1[360] && d1[337:333]==d0[327:323];
    wire raw_b=d0[361] && d0[327:323]!=0 && d1[359] && d1[332:328]==d0[327:323];
    wire raw=raw_a||raw_b;
    wire decoded_fuse_extend=d0[345:342]==K_ALU && d1[345:342]==K_ALU &&
      d0[262:256]==7'h13 && d1[262:256]==7'h13 &&
      d0[322:320]==1 && d1[322:320]==5 && d0[196:192]==d1[196:192] &&
      (d0[196:192]==24 || d0[196:192]==16 || d0[196:192]==31);
    wire late_ok=LATE_ALU && (d0[345:342]==K_ALU || d0[345:342]==K_LOAD || d0[345:342]==K_JAL) && ((d1[345:342]==K_ALU && (simple_late(d1[341:338]) || decoded_fuse_extend)) || (d0[345:342]==K_ALU && d1[345:342]==K_BRANCH));
    wire serial=d0[345:342]==K_CSR || d0[345:342]==K_FENCE;
    wire backend_empty=!o0[362] && !x0[362] && !m0[362] && !w0[362];
    wire issue=d0[362] && o_can && !d_hazard && (!serial || backend_empty) && !redirect && !halted;
    wire pair_issue=issue && DUAL_ENABLE && d1[362] && !d0[358] && !d1[358] && !y_hazard &&
      (!is_control(d0) || ((d0[345:342]==K_BRANCH || d0[345:342]==K_JAL) && (d1[345:342]==K_ALU || d1[345:342]==K_LOAD))) && !serial && d1[345:342]!=K_CSR && d1[345:342]!=K_FENCE &&
      d1[319:288]==(is_control(d0) ? d0[255:224] : d0[319:288]+4) && (!raw || late_ok) && !(is_complex(d0) && is_complex(d1));
    always @*begin
      dx0=d0;dx1=d1;dx0[191:160]=read_rf(d0[337:333],regs[d0[337:333]],w0,wc1);dx0[159:128]=read_rf(d0[332:328],regs[d0[332:328]],w0,wc1);
      dx1[191:160]=read_rf(d1[337:333],regs[d1[337:333]],w0,wc1);dx1[159:128]=read_rf(d1[332:328],regs[d1[332:328]],w0,wc1);dx1[362]=pair_issue;
      dx1[357]=raw && pair_issue;dx1[356]=raw_a;dx1[355]=raw_b;
    end
    wire[2:0] d_count=d0[362] ? (d1[362] ? 2 : 1) : 0;
    wire[2:0] dispatched=issue ? (pair_issue ? 2 : 1) : 0;
    wire[2:0] remain=d_count-dispatched;
    wire[4:0] qtake=queue_count<(2-remain) ? queue_count : 2-remain;
    wire[4:0] qleft=queue_count-qtake;
    wire[2:0] f2_count=f20[362] ? (f21[362] ? 2 : 1) : 0;
    // BF: frontend only spends registered free FIFO capacity. The same-cycle
    // backend dequeue cannot drive the wide queue write-enable network.
    // A full FIFO may refill one cycle later; capacity and ordering are unchanged.
    wire enqueue=f20[362] && (f21[362] ? queue_space_q[2] : queue_space_q[3]);
    wire f2_room=!f20[362] || enqueue;
    // Reserve from registered occupancy, never from same-cycle backend issue.
    // At most two returning instructions fit even if dispatch stalls completely.
    wire launch_room=!f20[362] ? queue_space_q[2] : f21[362] ? queue_space_q[0] : queue_space_q[1];
    assign queue_next_count=qleft+(enqueue ? f2_count : 0);
    // This port only reads side-effect-free instruction TCM. On a fault the
    // response is discarded by the unchanged req/tag/retirement qualification.
    // Keep immediate exception/younger-load suppression off this address bus.
    assign i_lookahead_addr=(redirect || instruction_fence) ? (redirect ? redirect_target : m0[63:32]) : !req_valid && launch_room ? (redirect_pending ? redirect_pc : next_fetch_pc) : req_valid && i_ready && !req_kill && !redirect_pending && !redirect && launch_room ? fetch_next : req_pc;
    // BV: separate request data preparation from queue admission. A new
    // prediction is captured only with the matching actual next request.
    // No queue-count or launch_room signal enters either predictor RAM address.
    assign predict_request_addr=(redirect || instruction_fence) ?
      (redirect ? redirect_target : m0[63:32]) : !req_valid ?
      (redirect_pending ? redirect_pc : next_fetch_pc) : fetch_next;
    assign predict_capture=(redirect || instruction_fence) ||
      (launch_room && (!req_valid || (i_ready && !req_kill && !redirect_pending && !redirect)));
`ifndef SYNTHESIS
    always @(posedge clk)if(rst_n && predict_capture && predict_request_addr!==i_lookahead_addr)
      $fatal(1,"BV captured predictor request differs from actual instruction address");
`endif
    assign if_stage_valid=req_valid;assign ex_stage_valid=x0[362];assign wb_stage_valid=w0[362];
    assign pipeline_stall=d0[362] && !issue;
    wire q0_valid=d0[362];
    always @*begin
      qhead0=qhead[0] ? queue_odd[qhead[3:1]] : queue_even[qhead[3:1]];
      qhead1=qhead_next[0] ? queue_odd[qhead_next[3:1]] : queue_even[qhead_next[3:1]];
    end

    always @(posedge clk)begin
      if(!rst_n)begin x_csr_sel0_q<=0;x_csr_sel1_q<=0;end
      else if(!halted && x_can)begin
        x_csr_sel0_q<=csr_decode(ox0[287:276]);
        x_csr_sel1_q<=csr_decode(ox1[287:276]);
      end
    end
`ifndef SYNTHESIS
    always @(posedge clk)if(rst_n && !halted)begin
      if(queue_space_q!=={queue_count<=15,queue_count<=14,queue_count<=13,queue_count<=12})$fatal(1,"CA queue capacity snapshot mismatch");
      if(enqueue!==(f20[362] && queue_count+f2_count<=16))$fatal(1,"CA enqueue changed");
      if(launch_room!==(queue_count+f2_count<=14))$fatal(1,"CA launch admission changed");
      if(x0[362] && x_csr_sel0_q!==csr_decode(x0[287:276]))$fatal(1,"CA CSR lane0 snapshot mismatch");
      if(x1[362] && x_csr_sel1_q!==csr_decode(x1[287:276]))$fatal(1,"CA CSR lane1 snapshot mismatch");
    end
`endif
    // BF: control classes are decoded with their O/X or X/M owner payload,
    // not reconstructed from kind bits along the backwards readiness chain.
    always @(posedge clk)begin
      if(!rst_n)begin x_long_md_q<=0;x_block0_q<=0;x_block1_q<=0;x_latewb_q<=0;m_fence_q<=0;end
      else if(!halted)begin
        if(x_can)begin
          x_long_md_q<=o_fire && ((ox0[345:342]==K_MD && ox0[322:320]!=0) || (ox1[362] && ox1[345:342]==K_MD && ox1[322:320]!=0));
          x_block0_q<=ox0[345:342]==K_LOAD || (ox0[345:342]==K_MD && ox0[322:320]==0) || ox0[345:342]==K_CLMUL || ox0[354];
          x_block1_q<=ox1[345:342]==K_LOAD || (ox1[345:342]==K_MD && ox1[322:320]==0) || ox1[345:342]==K_CLMUL || ox1[357] || ox1[354];
          x_latewb_q<=o_fire && ox0[345:342]==K_LOAD && ox1[362] && ox1[357];
        end
        if(m_can)m_fence_q<=x_fire && !xm0[358] && xm0[345:342]==K_FENCE && xm0[322:320]==1;
        if(stop_now)m_fence_q<=0;
        if(redirect || instruction_fence)begin x_long_md_q<=0;x_latewb_q<=0;m_fence_q<=0;end
      end
    end
    always @(posedge clk)begin
      if(!rst_n)begin mul00_q<=0;mul01_q<=0;mul10_q<=0;end
      else if(x_fire && ((x0[345:342]==K_MD && x0[322:320]==0) || (x1[362] && x1[345:342]==K_MD && x1[322:320]==0)))begin
        mul00_q<=mul_a[15:0]*mul_b[15:0];
        mul01_q<=mul_a[15:0]*mul_b[31:16];
        mul10_q<=mul_a[31:16]*mul_b[15:0];
      end
    end
    always @(posedge clk)begin
      if(!rst_n)begin m_memory0_q<=0;m_memory1_q<=0;m_squash_q<=0;m_fault_q<=0;end
      else if(!halted)begin
        if(m_can)begin
          m_memory0_q<=x_fire && (xm0[345:342]==K_LOAD || xm0[345:342]==K_STORE);
          m_memory1_q<=x_fire && xm1[362] && (xm1[345:342]==K_LOAD || xm1[345:342]==K_STORE);
          m_squash_q<=x_fire && is_control(xm0) && !xm0[354] && xm0[353];
          m_fault_q<=x_fire && (xm0[358] || (xm1[362] && xm1[358]));
        end
        if(redirect || instruction_fence)begin
          m_memory0_q<=0;m_memory1_q<=0;m_squash_q<=0;m_fault_q<=0;
        end
      end
    end
    always @(posedge clk)begin
      if(!rst_n)begin mem_addr<=0;mem_data<=0;mem_f3<=0;mem_write_q<=0;end
      else if(x_fire)begin
        mem_addr<=x_mem1 ? xm1[95:64] : xm0[95:64];
        mem_data<=x_mem1 ? xm1[159:128] : xm0[159:128];
        mem_f3<=x_mem1 ? xm1[322:320] : xm0[322:320];
        mem_write_q<=x_mem1 ? xm1[345:342]==K_STORE : xm0[345:342]==K_STORE;
      end
    end
    integer k;
    always @(posedge clk)begin
      if(!rst_n)begin
        f20<=363'b0;f21<=363'b0;d0<=363'b0;d1<=363'b0;o0<=363'b0;o1<=363'b0;x0<=363'b0;x1<=363'b0;m0<=363'b0;m1<=363'b0;w0<=363'b0;w1<=363'b0;
        qhead<=0;qtail<=0;queue_count<=0;queue_space_q<=4'b1111;
        redirect<=0;redirect_target<=RESET_PC;req_valid<=0;req_kill<=0;req_pc<=RESET_PC;next_fetch_pc<=RESET_PC;redirect_pending<=0;redirect_pc<=0;
        btb_valid<=0;train_v<=0;train_pc<=0;train_target<=0;train_taken<=0;train_control<=0;
        for(k=0;k<32;k=k+1)regs[k]<=0;
        halted<=0;trap_pending<=0;trap_cause<=0;trap_pc<=0;trap_value<=0;
        retire_valid<=0;retire1_valid<=0;retire_pc<=0;retire_insn<=0;retire_rd<=0;retire_data<=0;retire_next_pc<=0;
        retire1_pc<=0;retire1_insn<=0;retire1_rd<=0;retire1_data<=0;retire1_next_pc<=0;
        cycle_count<=0;instret_count<=0;stall_count<=0;flush_count<=0;forward_count<=0;
        md_launched<=0;md_held<=0;md_saved<=0;
        csr_mtvec<=0;csr_mscratch<=0;csr_mepc<=0;csr_mcause<=0;csr_mtval<=0;csr_mstatus<=0;csr_mie<=0;
      end else if(!halted)begin
        redirect<=redirect_now;redirect_target<=actual_next;
        // CB: only redirect validates this snapshot. Capturing the payload every
        // edge removes late branch resolution from 32 target clock-enables.
        cycle_count<=cycle_count+1;stall_count<=stall_count+pipeline_stall;flush_count<=flush_count+redirect;
        retire_valid<=w0[362];retire1_valid<=w1[362];
        retire_pc<=w0[319:288];retire_insn<=w0[287:256];retire_rd<=w0[361] ? w0[327:323] : 0;retire_data<=w0[361] && w0[327:323]!=0 ? w0[127:96] : 0;retire_next_pc<=w0[63:32];
        retire1_pc<=w1[319:288];retire1_insn<=w1[287:256];retire1_rd<=w1[361] ? w1[327:323] : 0;retire1_data<=w1[361] && w1[327:323]!=0 ? wc1[127:96] : 0;retire1_next_pc<=w1[63:32];
        instret_count<=instret_count+(w0[362] ? (w1[362] ? 2 : 1) : 0);
        if(w0[362] && w0[361] && w0[327:323]!=0)regs[w0[327:323]]<=w0[127:96];
        if(w1[362] && w1[361] && w1[327:323]!=0)regs[w1[327:323]]<=wc1[127:96];
        if(w0[362] && w0[345:342]==K_CSR && (w0[321:320]==1 || w0[337:333]!=0))begin
          case(w0[287:276])
            12'h300:csr_mstatus<=csr_new(w0);12'h304:csr_mie<=csr_new(w0);12'h305:csr_mtvec<=csr_new(w0);
            12'h340:csr_mscratch<=csr_new(w0);12'h341:csr_mepc<=csr_new(w0);
            12'h342:csr_mcause<=csr_new(w0);12'h343:csr_mtval<=csr_new(w0);default:begin end
          endcase
        end
        w0[362]<=0;w1[362]<=0;
        if(m_fire)begin
          if(!m_error)begin w0<=mw0;w1<=mw1;end
          else begin
            // A younger fault cannot erase a completed older instruction.
            // Drain the existing W boundary before reporting halted. Both M
            // valids are cleared below, so no younger memory request is issued
            // during this single drain edge. Normal instructions add no cycle.
            trap_pending<=1;
            if(!m0[358] && !(m_mem0 && d_ready && d_error))w0<=mw0;
            trap_pc<=m0[358] || m_mem0 ? m0[319:288] : m1[319:288];
            trap_cause<=m0[358] ? m0[31:0] : m1[362] && m1[358] ? m1[31:0] : d_write ? 7 : 5;trap_value<=mem_addr;
          end
        end
        train_v<=0;
        if(m_fire && !m_error && (is_control(m0) || (m1[362] && is_control(m1)) || mw0[353]))begin
          train_v<=1;train_pc<=m1[362] && is_control(m1) ? m1[319:288] : m0[319:288];
          train_control<=is_control(m0)||(m1[362] && is_control(m1));
          train_taken<=m1[362] && is_control(m1) ? mw1[63:32]!=m1[319:288]+4 : mw0[63:32]!=m0[319:288]+4;
          train_target<=m1[362] && is_control(m1) ? (m1[345:342]==K_BRANCH ? m1[95:64] : mw1[63:32]) : (m0[345:342]==K_BRANCH ? m0[95:64] : mw0[63:32]);
        end
        if(train_v)begin
          btb_valid[train_pc[9:2]]<=train_control;
          btb_tag[train_pc[9:2]]<=train_pc[31:10];btb_target[train_pc[9:2]]<=train_target;btb_sequential[train_pc[9:2]]<=train_target==train_pc+32'd4;
          if(!btb_valid[train_pc[9:2]] || btb_tag[train_pc[9:2]]!=train_pc[31:10])btb_count[train_pc[9:2]]<=train_taken ? 2 : 1;
          else if(train_taken)begin if(btb_count[train_pc[9:2]]!=3)btb_count[train_pc[9:2]]<=btb_count[train_pc[9:2]]+1'b1;end
          else if(btb_count[train_pc[9:2]]!=0)btb_count[train_pc[9:2]]<=btb_count[train_pc[9:2]]-1'b1;
        end
        if(instruction_fence)btb_valid<=0;
        if(md_start)md_launched<=1;
        if(md_done)begin md_held<=1;md_saved<=md_result;end
        if(m_can)begin m0[362]<=0;m1[362]<=0;if(x_fire)begin m0<=xm0;m1<=xm1;end end
        if(x_can)begin x0[362]<=0;x1[362]<=0;if(o_fire)begin x0<=ox0;x1<=ox1;end end
        if(x_fire)begin md_launched<=0;md_held<=0;end
        if(o_can)begin o0[362]<=0;o1[362]<=0;if(issue)begin o0<=dx0;o1<=dx1;end end
        // Deferred operations may wait beside a multi-cycle multiply/divide.
        // Retiring producers must be retained until the eventual X/M handoff.
        if(x0[362] && !x_fire)begin
          if(x0[354])begin
            if(hit(w1,x0[337:333]))x0[191:160]<=wc1[127:96];else if(hit(w0,x0[337:333]))x0[191:160]<=w0[127:96];
            if(hit(w1,x0[332:328]))x0[159:128]<=wc1[127:96];else if(hit(w0,x0[332:328]))x0[159:128]<=w0[127:96];
          end
          if(x1[354])begin
            if(hit(w1,x1[337:333]))x1[191:160]<=wc1[127:96];else if(hit(w0,x1[337:333]))x1[191:160]<=w0[127:96];
            if(hit(w1,x1[332:328]))x1[159:128]<=wc1[127:96];else if(hit(w0,x1[332:328]))x1[159:128]<=w0[127:96];
          end
        end
        // RF read snapshots already in O must track a committing older value while held.
        if(o0[362] && !o_fire)begin
          if(hit(w1,o0[337:333]))o0[191:160]<=wc1[127:96];else if(hit(w0,o0[337:333]))o0[191:160]<=w0[127:96];
          if(hit(w1,o0[332:328]))o0[159:128]<=wc1[127:96];else if(hit(w0,o0[332:328]))o0[159:128]<=w0[127:96];
          if(hit(w1,o1[337:333]))o1[191:160]<=wc1[127:96];else if(hit(w0,o1[337:333]))o1[191:160]<=w0[127:96];
          if(hit(w1,o1[332:328]))o1[159:128]<=wc1[127:96];else if(hit(w0,o1[332:328]))o1[159:128]<=w0[127:96];
        end
        if(remain==0)begin
          d0<=qhead0;d0[362]<=qtake!=0;d1<=qhead1;d1[362]<=qtake==2;
        end else if(remain==1)begin
          if(dispatched==1)d0<=d1;
          d1<=qhead0;d1[362]<=qtake!=0;
        end
        qhead<=qhead+qtake;
        queue_count<=queue_next_count;
        queue_space_q<={queue_next_count<=15,queue_next_count<=14,queue_next_count<=13,queue_next_count<=12};
        if(enqueue)begin
          qtail<=qtail+f2_count;
          if(qtail[0])begin
            queue_odd[qtail[3:1]]<=prepare_front(f20);
            if(f21[362])queue_even[qtail_next[3:1]]<=prepare_front(f21);
          end else begin
            queue_even[qtail[3:1]]<=prepare_front(f20);
            if(f21[362])queue_odd[qtail_next[3:1]]<=prepare_front(f21);
          end
          f20[362]<=0;f21[362]<=0;
        end
        if(req_valid && i_ready)begin
          req_valid<=0;req_kill<=0;
          if(!req_kill && !redirect_pending && !redirect)begin
            f20<=decode(req_pc,i_rdata,pred0,i_error);
            f21<=decode(req_pc1,i_rdata1,pred1,1'b0);f21[362]<=fetched_pair;
            next_fetch_pc<=fetch_next;
            if(launch_room)begin req_valid<=1;req_pc<=fetch_next;end
          end
        end
        if(!req_valid && launch_room)begin
          req_valid<=1;req_pc<=redirect_pending ? redirect_pc : next_fetch_pc;
          req_kill<=0;redirect_pending<=0;
        end
        if(trap_pending)halted<=1;
        if(stop_now)begin m0[362]<=0;m1[362]<=0;end
        if(redirect || instruction_fence)begin
          f20[362]<=0;f21[362]<=0;d0[362]<=0;d1[362]<=0;o0[362]<=0;o1[362]<=0;x0[362]<=0;x1[362]<=0;
          m0[362]<=0;m1[362]<=0;queue_count<=0;queue_space_q<=4'b1111;qhead<=0;qtail<=0;md_launched<=0;md_held<=0;
          redirect_pending<=1;redirect_pc<=redirect ? redirect_target : actual_next;next_fetch_pc<=redirect ? redirect_target : actual_next;
          // TCM has no outstanding external transaction; discard speculative read tags.
          req_valid<=1;req_pc<=redirect ? redirect_target : actual_next;redirect_pending<=0;req_kill<=0;
        end
      end else begin retire_valid<=0;retire1_valid<=0;end
    end
    function automatic [31:0] csr_new(input [362:0] t);
      reg[31:0] src;
      begin src=t[322] ? {27'b0,t[337:333]} : t[191:160];
        case(t[321:320])1:csr_new=src;2:csr_new=t[127:96]|src;3:csr_new=t[127:96]&~src;default:csr_new=t[127:96];endcase
      end
    endfunction
`ifndef SYNTHESIS
    always @(posedge clk)if(rst_n && !halted)begin
      if(x_md!==(x0[362] && ((x0[345:342]==K_MD && x0[322:320]!=0) || (x1[362] && x1[345:342]==K_MD && x1[322:320]!=0))))$fatal(1,"BF long MD metadata");
      if(x0[362] && blocked_x0!==(x0[345:342]==K_LOAD || (x0[345:342]==K_MD && x0[322:320]==0) || x0[345:342]==K_CLMUL || x0[354]))$fatal(1,"BF blocked0 metadata");
      if(x1[362] && blocked_x1!==(x1[345:342]==K_LOAD || (x1[345:342]==K_MD && x1[322:320]==0) || x1[345:342]==K_CLMUL || x1[357] || x1[354]))$fatal(1,"BF blocked1 metadata");
      if(m_fire && m0[362] && m0[354] &&
        preselected(m0[349:348],m0[191:160],w0[127:96],w1[127:96])!==select_operand(m0[337:333],m0[191:160],w0,w1,363'b0,363'b0))$fatal(1,"S10AA preselected operand mismatch m0[191:160]");
      if(m_fire && m0[362] && m0[354] &&
        preselected(m0[347:346],m0[159:128],w0[127:96],w1[127:96])!==select_operand(m0[332:328],m0[159:128],w0,w1,363'b0,363'b0))$fatal(1,"S10AA preselected operand mismatch m0[159:128]");
      if(m_fire && m1[362] && m1[354] &&
        preselected(m1[349:348],m1[191:160],w0[127:96],w1[127:96])!==select_operand(m1[337:333],m1[191:160],w0,w1,363'b0,363'b0))$fatal(1,"S10AA preselected operand mismatch m1[191:160]");
      if(m_fire && m1[362] && m1[354] &&
        preselected(m1[347:346],m1[159:128],w0[127:96],w1[127:96])!==select_operand(m1[332:328],m1[159:128],w0,w1,363'b0,363'b0))$fatal(1,"S10AA preselected operand mismatch m1[159:128]");
      if(m_fire && m0[362] && m0[345:342]==K_MD && m0[322:320]==0 && mw0[127:96]!==(m0[191:160]*m0[159:128]))$fatal(1,"S10AE MUL value mismatch lane0");
      if(m_fire && m1[362] && m1[345:342]==K_MD && m1[322:320]==0 && mw1[127:96]!==(m1[191:160]*m1[159:128]))$fatal(1,"S10AE MUL value mismatch lane1");
      if(squash_memory && d_valid)$fatal(1,"S10AC wrong-path memory request");
      if(squash_younger && mw1[362])$fatal(1,"S10AC wrong-path younger retirement");
      if(instruction_fence!==(m_fire && !m_error && m0[345:342]==K_FENCE && m0[322:320]==1))$fatal(1,"S10AI fence equivalence");
      if(instruction_fence && m1[362])$fatal(1,"S10AI serial fence younger lane");
      if(mul_upper!==((mul00_q[31:16]+mul01_q+mul10_q)&16'hffff))$fatal(1,"S10AK CSA equivalence");
      if(m0[362] && m0[354] && m0[345:342]!=K_ALU && m0[345:342]!=K_BRANCH)$fatal(1,"AQ deferred operation lane0");
      if(m1[362] && m1[354] && m1[345:342]!=K_ALU && m1[345:342]!=K_BRANCH)$fatal(1,"AQ deferred operation lane1");
      if(m0[362] && m_squash_q!==(is_control(m0)&&!m0[354]&&m0[353]))$fatal(1,"AM squash qualification");
      if(m0[362] && m_fault_q!==(m0[358]||(m1[362]&&m1[358])))$fatal(1,"AM fault qualification");
      if(m0[362] && m_mem && mem_addr!==(m_mem1 ? m1[95:64] : m0[95:64]))$fatal(1,"AO LSU address owner");
      if(m0[362] && m_mem && mem_data!==(m_mem1 ? m1[159:128] : m0[159:128]))$fatal(1,"AO LSU store owner");
      if(m0[362] && m0[354] && m0[345:342]==K_BRANCH &&
        (m_mem || m0[358] || m0[65:64]!=0 || (m1[362] && (m1[345:342]!=K_ALU || m1[358]))))$fatal(1,"AQ unsafe deferred older branch");
      if(m0[354] && m0[345:342]==K_BRANCH && mw0[353] && mw1[362])$fatal(1,"AQ late younger retirement");
      if(req_valid && i_ready && !redirect && !stop_now && prediction_tag!==req_pc)$fatal(1,"AR predictor/instruction tag mismatch");
      if(req_valid && i_ready && !redirect && !stop_now && pred0_seq!==(pred0==req_pc1))$fatal(1,"AT sequential prediction mismatch");
      if(o_fire && fuse_extend && ox0[354])$fatal(1,"BB fused base operand not ready");
      if(x0[362] && x1[362] && x1[341:338]>=10)begin
        if(xm1[127:96]!==alu_value(alu_value(x0[191:160],x0[223:192],2),x1[223:192],x1[286]?7:6))
          $fatal(1,"BB fused result versus two RV32 shifts");
      end
      if(queue_count>16)$fatal(1,"S08 queue overflow");
      if(req_valid && i_ready && !req_kill && !redirect_pending && !redirect && !stop_now && !f2_room)$fatal(1,"S08 unreserved fetch response");
      if(w1[362] && w1[350] && ((m0[362] && m0[354] && depends(w1,m0)) || (m1[362] && m1[354] && depends(w1,m1))))$fatal(1,"S10 deferred WB cascade forbidden");
      if(m0[354] && m1[362] && m1[357])$fatal(1,"S08 deferred ALU cascade forbidden");
      if(m_mem0 && m_mem1)$fatal(1,"S08 two LSU owners");
      if(w1[362] && !w0[362])$fatal(1,"S08 orphan retirement");
    end
`endif
`ifndef SYNTHESIS
    always @(posedge clk)if(rst_n && !halted)begin
      if(m_fire && m0[354] && m0[345:342]==K_ALU && !simple_late(m0[341:338]))$fatal(1,"BZ unsupported late M0 ALU");
      if(m_fire && m1[362] && (m1[354] || m1[357]) && m1[345:342]==K_ALU && !simple_late(m1[341:338]))$fatal(1,"BZ unsupported late M1 ALU");
      if(w1[362] && w1[350] && !simple_late(w1[341:338]))$fatal(1,"BZ unsupported late W1 ALU");
    end
`endif

endmodule
