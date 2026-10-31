`timescale 1ns/1ps
// Three-stage in-order RV32I core:
//   IF      - one outstanding request plus a four-entry instruction queue
//   EX      - decode, forwarding, ALU, branch resolution and address generation
//   MEM/WB  - hold data-bus requests, detect access errors and retire in order
// A bus transaction completes only on valid && ready at a rising edge.
module rv32_core # (parameter TARGET_PAIR_FETCH=0, LATE_ALU=1, YOUNG_MEMORY=1, YOUNG_MULDIV=1, DUAL_ENABLE=1, PAIR_FETCH=0, parameter RESET_PC = 32'h00000000,
    parameter MEM_RESPONSE_FORWARD = 1, parameter PREDICT_ENABLE = 1, parameter MACHINE_ENABLE = 0, parameter M_ENABLE = 0, parameter FENCEI_ENABLE = 0) (
    input wire clk, rst_n,
    input wire irq_external,irq_timer,irq_software,
    output wire i_valid, output wire [31:0] i_addr,
    output wire [31:0] i_pair_addr,
    input wire i_ready, input wire [31:0] i_rdata, input wire i_error,
    output wire d_valid, d_write, output wire [31:0] d_addr, d_wdata,
    output wire [3:0] d_wstrb,
    input wire i_pair_valid, input wire [31:0] i_rdata1,
    output reg retire1_valid, output reg [31:0] retire1_pc,retire1_insn,
    output reg [4:0] retire1_rd, output reg [31:0] retire1_data,retire1_next_pc,
    input wire d_ready, input wire [31:0] d_rdata, input wire d_error,
    output reg halted, output reg [31:0] trap_cause, trap_pc, trap_value,
    output reg retire_valid, output reg [31:0] retire_pc, retire_insn,
    output reg [4:0] retire_rd, output reg [31:0] retire_data, retire_next_pc,
    output reg [63:0] cycle_count, instret_count,
    output reg [63:0] stall_count, flush_count, forward_count,
    output wire if_stage_valid, ex_stage_valid, wb_stage_valid,
    output wire pipeline_stall, pipeline_flush, instruction_fence
);
    reg req_valid, req_kill, redirect_valid, fetch_blocked;
    reg [31:0] req_pc, next_fetch_pc, redirect_pc;

    // Four entries reserve space for the full outstanding fetch response.
    reg [160:0] queue[0:3]; reg [2:0] queue_count; reg req_pair;
    wire q0_valid=queue_count!=0,q1_valid=queue_count>1;
    wire [31:0] q0_pc,q0_insn,q0_pred_next,q0_cause,q0_tval;
    wire [31:0] q1_pc,q1_insn,q1_pred_next,q1_cause,q1_tval;
    wire q0_fault,q1_fault;
    assign {q0_fault,q0_pc,q0_insn,q0_pred_next,q0_cause,q0_tval}=queue[0];
    assign {q1_fault,q1_pc,q1_insn,q1_pred_next,q1_cause,q1_tval}=queue[1];
    reg wb_late_alu, wb_late_a, wb_late_b;
    reg [31:0] wb_late_other_a, wb_late_other_b;
    reg wb_young_complex; // LSU/M result belongs to the younger retirement slot.
    reg wb1_valid; reg [31:0] wb1_pc,wb1_insn,wb1_data,wb1_next;
    reg [4:0] wb1_rd;
    reg wb_valid, wb_fault, wb_mem, wb_store, wb_write_rd;
    reg wb_csr,wb_csr_write,wb_mret,wb_md;
    reg [11:0] wb_csr_addr;
    reg [31:0] wb_csr_data;
    reg csr_mie_global,csr_mpie;
    reg [31:0] csr_mtvec,csr_mscratch,csr_mepc,csr_mcause,csr_mtval,csr_mie,csr_inhibit;
    reg [31:0] wb_pc, wb_insn, wb_result, wb_next_pc;
    reg [31:0] wb_addr, wb_wdata, wb_cause, wb_tval;
    reg [4:0] wb_rd;
    reg [3:0] wb_wstrb;
    reg [2:0] wb_f3;

    wire [6:0] opcode = q0_insn[6:0];
    wire [2:0] f3 = q0_insn[14:12];
    wire [6:0] f7 = q0_insn[31:25];
    wire [4:0] rs1 = q0_insn[19:15];
    wire [4:0] rs2 = q0_insn[24:20];
    wire [4:0] rd = q0_insn[11:7];
    wire [31:0] imm_i = {{20{q0_insn[31]}},q0_insn[31:20]};
    wire [31:0] imm_s = {{20{q0_insn[31]}},q0_insn[31:25],q0_insn[11:7]};
    wire [31:0] imm_b = {{19{q0_insn[31]}},q0_insn[31],q0_insn[7],q0_insn[30:25],q0_insn[11:8],1'b0};
    wire [31:0] imm_j = {{11{q0_insn[31]}},q0_insn[31],q0_insn[19:12],q0_insn[20],q0_insn[30:21],1'b0};

    wire [31:0] shifted_load = d_rdata >> (wb_addr[1:0]*8);
    reg [31:0] wb_load_result;
    always @* begin
        case(wb_f3)
            0: wb_load_result={{24{shifted_load[7]}},shifted_load[7:0]};
            1: wb_load_result={{16{shifted_load[15]}},shifted_load[15:0]};
            2: wb_load_result=shifted_load;
            4: wb_load_result={24'b0,shifted_load[7:0]};
            5: wb_load_result={16'b0,shifted_load[15:0]};
            default: wb_load_result=0;
        endcase
    end
    wire md_done,md_busy;wire [31:0] md_result;
    wire [31:0] complex_result=wb_md ? md_result : wb_load_result;
    wire [31:0] wb_commit_data = wb_young_complex ? wb_result :
      wb_md ? md_result : wb_mem && !wb_store ? wb_load_result : wb_result;
    wire [31:0] late_result;
    rv32_simple_lane completion_alu(.pc(wb1_pc),.insn(wb1_insn),
      .a(wb_late_a ? complex_result : wb_late_other_a),
      .b(wb_late_b ? complex_result : wb_late_other_b),
      .legal(),.write_rd(),.result(late_result),.next_pc(),.control(),.taken(),.target());
    wire [31:0] wb1_commit_data=wb_late_alu ? late_result : wb_young_complex && (wb_md || !wb_store) ? complex_result : wb1_data;
    wire wb_mem_error = wb_valid && wb_mem && d_ready && d_error;
    wire wb_success = wb_valid && !wb_fault && (wb_md ? md_done : !wb_mem || (d_ready && !d_error));
    // A fault in slot 1 cannot roll back an older, successful slot 0 operation.
    // wb_mem_error is asserted once: on a delayed trap we latch wb_fault and
    // clear wb_mem. This prevents repeated older writes/retirement while the
    // outstanding instruction request drains before entering the trap.
    wire wb_old_commit=wb_success || (wb_young_complex && wb_mem_error);
    wire wb_trap_pending = wb_valid && (wb_fault || wb_mem_error);
    // Drain an already issued younger fetch before halting so the request stays stable.
    wire trap_halt_now = wb_trap_pending && (!req_valid || i_ready);
    // On a successful memory response, forward the returned/extended value and
    // replace MEM/WB with the next EX instruction on the same edge. Errors must
    // block EX (including younger stores and redirects), preserving precise traps.
    // Setting the parameter to zero retains the v0.5.1 timing/performance baseline.
    wire wb_slot_available = !wb_valid || (!wb_mem && !wb_fault && !wb_md) ||
                             (MEM_RESPONSE_FORWARD && wb_success);

    reg ex_legal, ex_write_rd, ex_mem, ex_store, ex_take_branch, ex_fault;
    reg ex_csr,ex_mret,ex_md;
    reg [31:0] ex_result, ex_next_pc, ex_addr, ex_cause, ex_tval, ex_store_data;
    reg [3:0] ex_wstrb;
    wire ex_fire;
    wire [31:0] rf_a, rf_b,rf_c,rf_d;
    wire rf_we = rst_n && !halted && wb_old_commit && wb_write_rd && wb_rd!=0;
    rv32_dual_regfile rf(.clk(clk),.rst_n(rst_n),.rs1(rs1),.rs2(rs2),
                    .rs3(q1_insn[19:15]),.rs4(q1_insn[24:20]),.c(rf_c),.d(rf_d),
                    .rd1(wb1_rd),.we1(rst_n && !halted && wb_success && wb1_valid),.wd1(wb1_commit_data),
                    .rd(wb_rd),.we(rf_we),.wd(wb_commit_data),.a(rf_a),.b(rf_b));
    wire wb_forwardable = wb_valid && !wb_fault && wb_write_rd && wb_rd!=0 &&
                          ((!wb_mem && !wb_md) || (MEM_RESPONSE_FORWARD && wb_success));
    wire forward_a = q0_valid && wb_forwardable && wb_rd==rs1;
    wire forward_b = q0_valid && wb_forwardable && wb_rd==rs2;
    wire wb1_forwardable=wb1_valid && wb_success && wb1_rd!=0;
    wire f1_a=wb1_forwardable && wb1_rd==rs1;
    wire f1_b=wb1_forwardable && wb1_rd==rs2;
    wire [31:0] ex_a = f1_a ? wb1_commit_data : forward_a ? wb_commit_data : rf_a;
    wire [31:0] ex_b = f1_b ? wb1_commit_data : forward_b ? wb_commit_data : rf_b;

    wire [4:0] y_rs1=q1_insn[19:15],y_rs2=q1_insn[24:20],y_rd=q1_insn[11:7];
    wire [6:0] y_op=q1_insn[6:0];
    wire y_use_a=y_op!=7'h37 && y_op!=7'h17 && y_op!=7'h6f;
    wire y_use_b=y_op==7'h33 || y_op==7'h63 || y_op==7'h23;
    wire raw_a=ex_write_rd && rd!=0 && y_use_a && y_rs1==rd;
    wire raw_b=ex_write_rd && rd!=0 && y_use_b && y_rs2==rd;
    wire old_link=opcode==7'h6f || opcode==7'h67;
    wire old_alu=opcode==7'h37 || opcode==7'h17 || opcode==7'h13 || (opcode==7'h33 && !ex_md);
    wire [31:0] y_a=raw_a && (old_alu || old_link) ? ex_result :
      wb1_forwardable && wb1_rd==y_rs1 ? wb1_commit_data :
      wb_forwardable && wb_rd==y_rs1 ? wb_commit_data : rf_c;
    wire [31:0] y_b=raw_b && (old_alu || old_link) ? ex_result :
      wb1_forwardable && wb1_rd==y_rs2 ? wb1_commit_data :
      wb_forwardable && wb_rd==y_rs2 ? wb_commit_data : rf_d;
    wire y_simple_legal,y_simple_write,y_taken,y_control;
    wire [2:0] y_f3=q1_insn[14:12];
    wire y_mem=YOUNG_MEMORY && (y_op==7'h03 || y_op==7'h23);
    wire y_store=y_op==7'h23;
    wire y_md=YOUNG_MULDIV && M_ENABLE && y_op==7'h33 && q1_insn[31:25]==1;
    wire [31:0] y_imm=y_store ? {{20{q1_insn[31]}},q1_insn[31:25],q1_insn[11:7]} :
      {{20{q1_insn[31]}},q1_insn[31:20]};
    wire [31:0] y_addr=y_a+y_imm;
    wire y_mem_legal=(y_f3==0 || y_f3==1 || y_f3==2 || (!y_store && (y_f3==4 || y_f3==5))) &&
      !(((y_f3==1 || y_f3==5) && y_addr[0]) || (y_f3==2 && y_addr[1:0]!=0));
    wire [3:0] y_wstrb=y_f3==0 ? 4'b0001 << y_addr[1:0] :
      y_f3==1 ? 4'b0011 << y_addr[1:0] : 4'b1111;
    wire [31:0] y_wdata=y_b << (y_addr[1:0]*8);
    wire y_legal=y_simple_legal || (y_mem && y_mem_legal) || y_md;
    wire y_write=y_simple_write || (y_mem && !y_store) || y_md;
    wire [31:0] y_result,y_next,y_target;
    rv32_simple_lane younger(.pc(q1_pc),.insn(q1_insn),.a(y_a),.b(y_b),
      .legal(y_simple_legal),.write_rd(y_simple_write),.result(y_result),.next_pc(y_next),
      .control(y_control),.taken(y_taken),.target(y_target));
    // A control instruction may pair only with its resolved architectural
    // successor already in the queue. Link-register data can bypass to lane 1.
    // A wrong predicted successor is never executed in the younger slot.
    // At most one instruction per bundle owns LSU/M. A younger complex operation
    // pairs only behind a simple non-faulting older instruction. Misalignment and
    // illegal encodings fall back to the full slot-0 decoder for precise traps.
    // A delayed lane has no control flow, memory, CSR or exception side effects.
    // Access errors on the older operation suppress both retirement slots.
    wire late_eligible=LATE_ALU && (ex_md || (ex_mem && !ex_store)) &&
      (raw_a || raw_b) && y_simple_legal && !y_control && !y_mem && !y_md;
    wire pair_fire=DUAL_ENABLE && ex_fire && !ex_fault && q1_valid && !q1_fault &&
      (old_alu || ex_mem || ex_md || opcode==7'h63 || old_link) && ex_next_pc==q1_pc &&
      y_legal && y_next[1:0]==0 && (!(raw_a || raw_b) || old_alu || old_link || late_eligible) &&
      (!(y_mem || y_md) || (!ex_mem && !ex_md));
    wire pair_complex=pair_fire && (y_mem || y_md);
    wire [31:0] bundle_next=pair_fire ? y_next : ex_next_pc;
    wire [31:0] bundle_pred=pair_fire ? q1_pred_next : q0_pred_next;

    reg [3:0] alu_op;
    reg [31:0] alu_b;
    wire [31:0] alu_y;
    rv32_alu alu(.a(ex_a),.b(alu_b),.op(alu_op),.y(alu_y));
    always @* begin
        alu_b = (opcode == 7'h13) ? imm_i : ex_b;
        alu_op = 0;
        case(f3)
            0: alu_op = (opcode == 7'h33 && f7 == 7'h20) ? 1 : 0;
            1: alu_op = 2;
            2: alu_op = 3;
            3: alu_op = 4;
            4: alu_op = 5;
            5: alu_op = q0_insn[30] ? 7 : 6;
            6: alu_op = 8;
            7: alu_op = 9;
        endcase
    end

    wire [11:0] csr_addr=q0_insn[31:20];
    wire [31:0] csr_mip={20'b0,irq_external,3'b0,irq_timer,3'b0,irq_software,3'b0};
    wire [31:0] enabled_irqs=csr_mip & csr_mie;
    wire irq_pending=MACHINE_ENABLE && csr_mie_global && (|enabled_irqs);
    wire [31:0] irq_cause=enabled_irqs[11] ? 32'h8000000b : enabled_irqs[3] ? 32'h80000003 : 32'h80000007;
    wire irq_take=irq_pending && !wb_valid && (!req_valid || i_ready) && !halted;
    wire [31:0] irq_epc=q0_valid ? q0_pc : redirect_valid ? redirect_pc :
      (req_valid && !req_kill) ? req_pc : next_fetch_pc;
    wire machine_event=MACHINE_ENABLE && (trap_halt_now || irq_take);
    wire [31:0] event_cause=irq_take ? irq_cause : wb_fault ? wb_cause : wb_store ? 7 : 5;
    wire [31:0] event_epc=irq_take ? irq_epc : wb_young_complex ? wb1_pc : wb_pc;
    wire [31:0] event_value=irq_take ? 0 : wb_fault ? wb_tval : wb_addr;
    wire [31:0] trap_target={csr_mtvec[31:2],2'b0}+
       ((irq_take && csr_mtvec[1:0]==1) ? {25'b0,irq_cause[4:0],2'b0} : 32'b0);
    reg csr_exists;
    reg [31:0] csr_read;
    always @* begin
      csr_exists=1;csr_read=0;
      case(csr_addr)
        12'h300:csr_read=32'h1800 | {24'b0,csr_mpie,3'b0,csr_mie_global,3'b0};
        12'h301:csr_read=M_ENABLE ? 32'h40001100 : 32'h40000100; // RV32I, M-mode only, fixed ISA
        12'h304:csr_read=csr_mie;
        12'h305:csr_read=csr_mtvec;
        12'h306,12'h310:csr_read=0;
        12'h320:csr_read=csr_inhibit;
        12'h340:csr_read=csr_mscratch;
        12'h341:csr_read=csr_mepc;
        12'h342:csr_read=csr_mcause;
        12'h343:csr_read=csr_mtval;
        12'h344:csr_read=csr_mip;
        12'hb00,12'hc00:csr_read=cycle_count[31:0];
        12'hb80,12'hc80:csr_read=cycle_count[63:32];
        12'hb02,12'hc02:csr_read=instret_count[31:0];
        12'hb82,12'hc82:csr_read=instret_count[63:32];
        12'hf11,12'hf12,12'hf13,12'hf14:csr_read=0;
        default:csr_exists=0;
      endcase
    end
    wire [31:0] csr_operand=f3[2] ? {27'b0,rs1} : ex_a;
    wire csr_write_intent=f3[1:0]==1 || rs1!=0;
    wire [31:0] csr_new_value=f3[1:0]==1 ? csr_operand :
      f3[1:0]==2 ? csr_read | csr_operand : csr_read & ~csr_operand;
    wire csr_commit=wb_success && wb_csr && wb_csr_write;
    always @(posedge clk) begin
      if(!rst_n)begin
        csr_mie_global<=0;csr_mpie<=0;csr_mtvec<=0;csr_mscratch<=0;
        csr_mepc<=0;csr_mcause<=0;csr_mtval<=0;csr_mie<=0;csr_inhibit<=0;
      end else if(MACHINE_ENABLE)begin
        if(machine_event)begin
          csr_mepc<=event_epc & 32'hfffffffc;csr_mcause<=event_cause;csr_mtval<=event_value;
          csr_mpie<=csr_mie_global;csr_mie_global<=0;
        end else if(wb_success && wb_mret)begin csr_mie_global<=csr_mpie;csr_mpie<=1;end
        else if(csr_commit)case(wb_csr_addr)
          12'h300:begin csr_mie_global<=wb_csr_data[3];csr_mpie<=wb_csr_data[7];end
          12'h304:csr_mie<=wb_csr_data & 32'h888;
          12'h305:csr_mtvec<={wb_csr_data[31:2],1'b0,wb_csr_data[1:0]==1};
          12'h320:csr_inhibit<=wb_csr_data & 5;
          12'h340:csr_mscratch<=wb_csr_data;
          12'h341:csr_mepc<=wb_csr_data & 32'hfffffffc;
          12'h342:csr_mcause<=wb_csr_data;
          12'h343:csr_mtval<=wb_csr_data;
          default:begin end // fixed WARL CSRs and read-only pending interrupt bits
        endcase
      end
    end

    wire ex_fence=FENCEI_ENABLE && opcode==7'h0f && f3==1 && !q0_fault;
    wire fence_drain=q0_valid && ex_fence;
    always @* begin
        ex_csr=0;ex_mret=0;ex_md=0;ex_legal=1; ex_write_rd=0; ex_mem=0; ex_store=0; ex_take_branch=0;
        ex_result=0; ex_next_pc=q0_pc+4; ex_addr=0; ex_wstrb=0; ex_store_data=0;
        ex_fault=q0_fault; ex_cause=q0_cause; ex_tval=q0_tval;
        if(!q0_fault) begin
            case(opcode)
                7'h37: begin ex_write_rd=1; ex_result={q0_insn[31:12],12'b0}; end
                7'h17: begin ex_write_rd=1; ex_result=q0_pc+{q0_insn[31:12],12'b0}; end
                7'h6f: begin ex_write_rd=1; ex_result=q0_pc+4; ex_next_pc=q0_pc+imm_j; end
                7'h67: begin
                    ex_legal=(f3==0); ex_write_rd=1; ex_result=q0_pc+4;
                    ex_next_pc=(ex_a+imm_i)&32'hfffffffe;
                end
                7'h63: begin
                    case(f3)
                        0: ex_take_branch=(ex_a==ex_b);
                        1: ex_take_branch=(ex_a!=ex_b);
                        4: ex_take_branch=($signed(ex_a)<$signed(ex_b));
                        5: ex_take_branch=($signed(ex_a)>=$signed(ex_b));
                        6: ex_take_branch=(ex_a<ex_b);
                        7: ex_take_branch=(ex_a>=ex_b);
                        default: ex_legal=0;
                    endcase
                    if(ex_take_branch) ex_next_pc=q0_pc+imm_b;
                end
                7'h13: begin
                    ex_write_rd=1; ex_result=alu_y;
                    if(f3==1) ex_legal=(f7==0);
                    if(f3==5) ex_legal=(f7==0 || f7==7'h20);
                end
                7'h33: begin
                    ex_write_rd=1; ex_result=alu_y;
                    ex_legal=(f7==0 || (f7==7'h20 && (f3==0 || f3==5)) || (M_ENABLE && f7==1));
                    ex_md=M_ENABLE && f7==1;
                end
                7'h03: begin
                    ex_mem=1; ex_write_rd=1; ex_addr=ex_a+imm_i;
                    ex_legal=(f3==0 || f3==1 || f3==2 || f3==4 || f3==5);
                end
                7'h23: begin
                    ex_mem=1; ex_store=1; ex_addr=ex_a+imm_s;
                    case(f3)
                        0: ex_wstrb=4'b0001 << ex_addr[1:0];
                        1: ex_wstrb=4'b0011 << ex_addr[1:0];
                        2: ex_wstrb=4'b1111;
                        default: ex_legal=0;
                    endcase
                    ex_store_data=ex_b << (ex_addr[1:0]*8);
                end
                7'h0f: ex_legal=(f3==0 || (FENCEI_ENABLE && f3==1));
                7'h73: begin
                    if(MACHINE_ENABLE && f3!=0)begin
                      ex_csr=1;ex_write_rd=1;ex_result=csr_read;
                      ex_legal=f3!=4 && csr_exists && !(csr_addr[11:10]==3 && csr_write_intent);
                    end else if(MACHINE_ENABLE && q0_insn==32'h30200073)begin
                      ex_mret=1;ex_next_pc=csr_mepc;
                    end else if(MACHINE_ENABLE && q0_insn==32'h10500073)begin
                      // WFI is permitted to resume as a NOP; interrupt checks remain active.
                    end else begin
                    ex_fault=1;
                    if(q0_insn==32'h00000073) begin ex_cause=11; ex_tval=0; end
                    else if(q0_insn==32'h00100073) begin ex_cause=3; ex_tval=q0_pc; end
                    else ex_legal=0;
                    end
                end
                default: ex_legal=0;
            endcase
            if(!ex_legal) begin ex_fault=1; ex_cause=2; ex_tval=q0_insn; end
            else if(ex_mem && (((f3==1 || f3==5) && ex_addr[0]) ||
                               (f3==2 && ex_addr[1:0]!=0))) begin
                ex_fault=1; ex_cause=ex_store ? 6 : 4; ex_tval=ex_addr;
            end else if(ex_next_pc[1:0]!=0) begin
                ex_fault=1; ex_cause=0; ex_tval=ex_next_pc;
            end
        end
    end

    assign ex_fire = rst_n && !halted && q0_valid && wb_slot_available && !irq_pending &&
       !(ex_fence && (wb_valid || req_valid)) &&
       !(MACHINE_ENABLE && wb_valid && (wb_csr || wb_mret || opcode==7'h73));
    // Tagged 128-entry BTB, one training port; younger control wins collisions.
    // Prediction is attached to the fetch response and travels with its queue
    // entry; EX compares the actual successor even for predicted-taken/not-taken.
    reg [127:0] btb_valid;
    reg [22:0] btb_tag[0:127];
    reg [31:0] btb_target[0:127];
    reg [1:0] btb_counter[0:127];
    wire bp_young=pair_fire && y_control;
    wire [6:0] bp_read=req_pc[8:2],bp_write=bp_young ? q1_pc[8:2] : q0_pc[8:2];
    wire [31:0] bp_pc=bp_young ? q1_pc : q0_pc;
    wire [6:0] bp_opcode=bp_young ? y_op : opcode;
    wire fetched_control=i_rdata[6:0]==7'h63 || i_rdata[6:0]==7'h67 || i_rdata[6:0]==7'h6f;
    wire [31:0] predicted_next=PREDICT_ENABLE && !i_error && fetched_control &&
      btb_valid[bp_read] && btb_tag[bp_read]==req_pc[31:9] && btb_counter[bp_read][1] ?
      btb_target[bp_read] : req_pc+4;
    wire resolved_control=bp_young ? y_control : opcode==7'h63 || opcode==7'h67 || opcode==7'h6f;
    wire resolved_taken=bp_young ? y_taken : opcode!=7'h63 || ex_take_branch;
    wire [31:0] resolved_target=bp_young ? y_target : opcode==7'h63 ? q0_pc+imm_b : ex_next_pc;
    always @(posedge clk) begin
      if(!rst_n || instruction_fence)btb_valid<=0;
      else if(PREDICT_ENABLE && ex_fire && !ex_fault && resolved_control)begin
        btb_valid[bp_write]<=1;btb_tag[bp_write]<=bp_pc[31:9];btb_target[bp_write]<=resolved_target;
        if(bp_opcode!=7'h63)btb_counter[bp_write]<=3;
        else if(!btb_valid[bp_write] || btb_tag[bp_write]!=bp_pc[31:9])
          btb_counter[bp_write]<=resolved_taken ? 2 : 1;
        else if(resolved_taken)begin
          if(btb_counter[bp_write]!=3)btb_counter[bp_write]<=btb_counter[bp_write]+1'b1;
        end else if(btb_counter[bp_write]!=0)btb_counter[bp_write]<=btb_counter[bp_write]-1'b1;
      end
    end

    generate if(M_ENABLE)begin: multiply_divide
      rv32_muldiv unit(.clk(clk),.rst_n(rst_n),.start(ex_fire && !ex_fault && (ex_md || (pair_fire && y_md))),
        .op(ex_md ? f3 : y_f3),.a(ex_md ? ex_a : y_a),.b(ex_md ? ex_b : y_b),.done(md_done),.busy(md_busy),.result(md_result));
    end else begin: no_m
      assign md_done=0;assign md_busy=0;assign md_result=0;
    end endgenerate
    assign instruction_fence=ex_fire && ex_fence && !ex_fault;
    wire ex_redirect = ex_fire && !ex_fault && (ex_fence || bundle_next!=bundle_pred);
    assign pipeline_flush = ex_fire && (ex_fault || ex_redirect);
    assign pipeline_stall = rst_n && !halted && q0_valid && !wb_slot_available;
    assign if_stage_valid = req_valid;
    assign ex_stage_valid = q0_valid;
    assign wb_stage_valid = wb_valid;

    assign i_valid = rst_n && req_valid;
    assign i_addr = req_pc;
    // Decode/alignment faults never reach the external data bus.
    assign d_valid = rst_n && !halted && wb_valid && wb_mem && !wb_fault;
    assign d_write = wb_store;
    assign d_addr = wb_addr;
    assign d_wdata = wb_wdata;
    assign d_wstrb = wb_wstrb;

    wire fetch_response=req_valid && i_ready;
    wire fetch_push=fetch_response && !req_kill;
    // Optional second read follows the first word's predicted architectural
    // successor. It is a cache-only speculative lookup, not another bus request.
    // Primary request and data do not depend on i_pair_addr, avoiding feedback.
    // This address is speculative before first-word decode; the existing
    // push_pair equality check still requires it to match predicted_next.
    // A stale BTB entry for a noncontrol first word only loses the pair, and
    // never substitutes a wrong architectural successor or launches a refill.
    wire [31:0] early_pair_addr=PREDICT_ENABLE && btb_valid[bp_read] &&
      btb_tag[bp_read]==req_pc[31:9] && btb_counter[bp_read][1] ?
      btb_target[bp_read] : req_pc+4;
    assign i_pair_addr=TARGET_PAIR_FETCH ? early_pair_addr : req_pc+4;
    wire [31:0] req_pc1=i_pair_addr;
    wire [6:0] bp_read1=req_pc1[8:2];
    wire control1=i_rdata1[6:0]==7'h63 || i_rdata1[6:0]==7'h67 || i_rdata1[6:0]==7'h6f;
    wire [31:0] predicted_next1=PREDICT_ENABLE && control1 && btb_valid[bp_read1] &&
      btb_tag[bp_read1]==req_pc1[31:9] && btb_counter[bp_read1][1] ? btb_target[bp_read1] : req_pc1+4;
    wire push_pair=PAIR_FETCH && req_pair && i_pair_valid && !i_error &&
      req_pc1[1:0]==0 && predicted_next==req_pc1;
    wire [31:0] fetch_next=push_pair ? predicted_next1 : predicted_next;
    wire [2:0] pop_count=ex_fire ? (pair_fire ? 2 : 1) : 0;
    wire [2:0] push_count=fetch_push ? (push_pair ? 2 : 1) : 0;
    wire [2:0] kept_count=queue_count-pop_count;
    wire [2:0] normal_post_count=kept_count+push_count;
    integer qi;
    always @(posedge clk) begin
      if(!rst_n)begin
        queue_count<=RESET_PC[1:0]!=0;
        for(qi=0;qi<4;qi=qi+1)queue[qi]<=0;
        queue[0]<={1'b1,RESET_PC,32'b0,RESET_PC+32'd4,32'b0,RESET_PC};
      end else if(machine_event || wb_trap_pending || pipeline_flush)queue_count<=0;
      else begin
        queue_count<=normal_post_count;
        for(qi=0;qi<4;qi=qi+1)begin
          if(qi<kept_count)queue[qi]<=queue[qi+pop_count];
          if(fetch_push && qi==kept_count)queue[qi]<={i_error,req_pc,i_rdata,predicted_next,32'd1,req_pc};
          if(fetch_push && push_pair && qi==kept_count+1)queue[qi]<={1'b0,req_pc1,i_rdata1,predicted_next1,32'd1,req_pc1};
        end
      end
    end
    // The request's pair reservation is held through arbitrary backend stalls.
    always @(posedge clk)begin
      if(!rst_n)begin
        req_valid<=0;req_kill<=0;redirect_valid<=0;req_pair<=0;
        req_pc<=RESET_PC;next_fetch_pc<=RESET_PC;redirect_pc<=0;
        fetch_blocked<=RESET_PC[1:0]!=0;
      end else if(machine_event)begin
        fetch_blocked<=0;redirect_valid<=0;req_kill<=0;
        req_valid<=1;req_pair<=1;req_pc<=trap_target;next_fetch_pc<=trap_target+4;
      end else if(wb_trap_pending)begin
        fetch_blocked<=1;redirect_valid<=0;
        if(req_valid && !i_ready)req_kill<=1;
        else begin req_valid<=0;req_kill<=0;end
      end else if(pipeline_flush)begin
        if(ex_redirect)begin
          fetch_blocked<=0;next_fetch_pc<=bundle_next+4;
          if(req_valid && !i_ready)begin req_kill<=1;redirect_valid<=1;redirect_pc<=bundle_next;end
          else begin req_valid<=1;req_pair<=1;req_kill<=0;req_pc<=bundle_next;redirect_valid<=0;end
        end else begin
          fetch_blocked<=1;redirect_valid<=0;
          if(req_valid && !i_ready)req_kill<=1;else begin req_valid<=0;req_kill<=0;end
        end
      end else if(req_valid)begin
        if(i_ready)begin
          if(req_kill)begin
            req_kill<=0;
            if(redirect_valid)begin
              req_valid<=1;req_pair<=1;req_pc<=redirect_pc;next_fetch_pc<=redirect_pc+4;redirect_valid<=0;
            end else req_valid<=0;
          end else if(!fetch_blocked && !fence_drain && normal_post_count<4)begin
            req_valid<=1;req_pair<=normal_post_count<=2;req_pc<=fetch_next;next_fetch_pc<=fetch_next+4;
          end else begin req_valid<=0;next_fetch_pc<=fetch_next;end
        end
      end else if(!fetch_blocked && !fence_drain && normal_post_count<4)begin
        req_valid<=1;req_pair<=normal_post_count<=2;req_pc<=next_fetch_pc;next_fetch_pc<=next_fetch_pc+4;
      end
    end

    always @(posedge clk) begin
        if(!rst_n) begin
            wb_late_alu<=0;wb_late_a<=0;wb_late_b<=0;
            wb_late_other_a<=0;wb_late_other_b<=0;
            wb_young_complex<=0;wb1_valid<=0;wb1_pc<=0;wb1_insn<=0;wb1_data<=0;wb1_next<=0;wb1_rd<=0;
            retire1_valid<=0;retire1_pc<=0;retire1_insn<=0;retire1_data<=0;retire1_next_pc<=0;retire1_rd<=0;
            wb_md<=0;wb_csr<=0;wb_csr_write<=0;wb_csr_addr<=0;wb_csr_data<=0;wb_mret<=0;
            wb_valid<=0; wb_fault<=0; wb_mem<=0; wb_store<=0; wb_write_rd<=0;
            wb_pc<=0; wb_insn<=0; wb_result<=0; wb_next_pc<=0;
            wb_addr<=0; wb_wdata<=0; wb_cause<=0; wb_tval<=0;
            wb_rd<=0; wb_wstrb<=0; wb_f3<=0;
            halted<=0; trap_cause<=0; trap_pc<=0; trap_value<=0;
            retire_valid<=0; retire_pc<=0; retire_insn<=0; retire_rd<=0;
            retire_data<=0; retire_next_pc<=0;
            cycle_count<=0; instret_count<=0; stall_count<=0;
            flush_count<=0; forward_count<=0;
        end else begin
            retire_valid<=0;retire1_valid<=0;
            if(!halted) begin
                if(!MACHINE_ENABLE || !csr_inhibit[0])cycle_count<=cycle_count+1;
                if(pipeline_stall) stall_count<=stall_count+1;
                if(pipeline_flush) flush_count<=flush_count+1;
                if(ex_fire && (forward_a || forward_b)) forward_count<=forward_count+1;

                // Retirement is in program order even when the younger memory
                // response faults on the same edge as trap entry.
                if(wb_old_commit)begin
                    retire_valid<=1;retire_pc<=wb_pc;retire_insn<=wb_insn;
                    retire_rd<=wb_write_rd ? wb_rd : 0;
                    retire_data<=wb_write_rd && wb_rd!=0 ? wb_commit_data : 0;
                    retire_next_pc<=wb_next_pc;
                    retire1_valid<=wb_success && wb1_valid;
                    retire1_pc<=wb1_pc;retire1_insn<=wb1_insn;retire1_rd<=wb1_rd;
                    retire1_data<=wb1_rd!=0 ? wb1_commit_data : 0;retire1_next_pc<=wb1_next;
                    if(!MACHINE_ENABLE || !csr_inhibit[2])
                      instret_count<=instret_count+((wb_success && wb1_valid) ? 2 : 1);
                end
                if(trap_halt_now || irq_take) begin
                    halted<=!MACHINE_ENABLE;trap_pc<=event_epc;
                    trap_cause<=event_cause;trap_value<=event_value;
                    wb_valid<=0;
                end else begin
                    if(wb_mem_error) begin
                        wb_fault<=1; wb_mem<=0;
                        wb_cause<=wb_store ? 7 : 5; wb_tval<=wb_addr;
                    end else if(wb_success) begin
                        wb_valid<=0;
                    end

                    if(csr_commit && MACHINE_ENABLE)case(wb_csr_addr)
                      12'hb00:cycle_count<={cycle_count[63:32],wb_csr_data};
                      12'hb80:cycle_count<={wb_csr_data,cycle_count[31:0]};
                      12'hb02:instret_count<={instret_count[63:32],wb_csr_data};
                      12'hb82:instret_count<={wb_csr_data,instret_count[31:0]};
                    endcase
                    if(ex_fire) begin
                        wb_late_alu<=pair_fire && late_eligible;
                        wb_late_a<=raw_a;wb_late_b<=raw_b;
                        wb_late_other_a<=y_a;wb_late_other_b<=y_b;
                        wb_young_complex<=pair_complex;
                        wb1_valid<=pair_fire;wb1_pc<=q1_pc;wb1_insn<=q1_insn;
                        wb1_rd<=y_write ? y_rd : 0;wb1_data<=y_result;wb1_next<=y_next;
                        wb_md<=ex_md || (pair_fire && y_md);wb_csr<=ex_csr;wb_csr_write<=csr_write_intent;wb_csr_addr<=csr_addr;
                        wb_csr_data<=csr_new_value;wb_mret<=ex_mret;
                        wb_valid<=1; wb_fault<=ex_fault; wb_mem<=ex_mem || (pair_fire && y_mem);
                        wb_store<=pair_complex ? y_store : ex_store; wb_write_rd<=ex_write_rd && !ex_store;
                        wb_pc<=q0_pc; wb_insn<=q0_insn; wb_result<=ex_result;
                        wb_next_pc<=ex_next_pc; wb_addr<=pair_complex ? y_addr : ex_addr;
                        wb_wdata<=pair_complex ? y_wdata : ex_store_data; wb_wstrb<=pair_complex ? y_wstrb : ex_wstrb; wb_f3<=pair_complex ? y_f3 : f3;
                        wb_rd<=rd; wb_cause<=ex_cause; wb_tval<=ex_tval;
                    end
                end
            end
        end
    end
endmodule

// Candidate-only architectural register file: reads precede two ordered writes.
module rv32_dual_regfile(
 input wire clk,rst_n,input wire [4:0] rs1,rs2,rs3,rs4,rd,rd1,
 input wire we,we1,input wire [31:0] wd,wd1,
 output wire [31:0] a,b,c,d);
 reg [31:0] regs[0:31]; integer ri;
 assign a=rs1==0 ? 0 : regs[rs1];assign b=rs2==0 ? 0 : regs[rs2];
 assign c=rs3==0 ? 0 : regs[rs3];assign d=rs4==0 ? 0 : regs[rs4];
 always @(posedge clk)begin
   if(!rst_n)for(ri=0;ri<32;ri=ri+1)regs[ri]<=0;
   else begin
     if(we && rd!=0)regs[rd]<=wd;
     if(we1 && rd1!=0)regs[rd1]<=wd1;
   end
 end
endmodule

// No memory/CSR/exception side effects. Unsupported encodings fall back to lane 0.
module rv32_simple_lane(input wire [31:0] pc,insn,a,b,
 output reg legal,write_rd,control,taken,
 output reg [31:0] result,next_pc,target);
 wire [6:0] op=insn[6:0],f7=insn[31:25];wire [2:0] f3=insn[14:12];
 wire [31:0] imm={{20{insn[31]}},insn[31:20]};
 wire [31:0] ib={{19{insn[31]}},insn[31],insn[7],insn[30:25],insn[11:8],1'b0};
 wire [31:0] ij={{11{insn[31]}},insn[31],insn[19:12],insn[20],insn[30:21],1'b0};
 reg [3:0] fn;wire [31:0] y;
 rv32_alu alu1(.a(a),.b(op==7'h13 ? imm : b),.op(fn),.y(y));
 always @* begin
   case(f3)
     0:fn=(op==7'h33 && f7==7'h20) ? 1 : 0;
     1:fn=2;2:fn=3;3:fn=4;4:fn=5;5:fn=insn[30] ? 7 : 6;6:fn=8;7:fn=9;
   endcase
 end
 always @* begin
   legal=1;write_rd=1;control=0;taken=0;result=y;next_pc=pc+4;target=pc+4;
   case(op)
     7'h37:result={insn[31:12],12'b0};
     7'h17:result=pc+{insn[31:12],12'b0};
     7'h13:begin
       if(f3==1)legal=f7==0;
       if(f3==5)legal=f7==0 || f7==7'h20;
     end
     7'h33:legal=f7==0 || (f7==7'h20 && (f3==0 || f3==5));
     7'h6f:begin control=1;taken=1;result=pc+4;target=pc+ij;next_pc=target;end
     7'h67:begin legal=f3==0;control=1;taken=1;result=pc+4;target=(a+imm)&32'hfffffffe;next_pc=target;end
     7'h63:begin
       write_rd=0;control=1;target=pc+ib;
       case(f3)
         0:taken=a==b;1:taken=a!=b;4:taken=$signed(a)<$signed(b);5:taken=$signed(a)>=$signed(b);
         6:taken=a<b;7:taken=a>=b;default:legal=0;
       endcase
       if(taken)next_pc=target;
     end
     default:begin legal=0;write_rd=0;end
   endcase
 end
endmodule
