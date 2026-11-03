// Four single-read coefficient banks, indexed by the incoming tile-major
// stream. Independent elastic input stage aligns Q16 data and PReLU slopes.
// A parameter transaction invalidates old coefficients before writing new ones.
module prelu_parameters4(
 input wire clk,rst,start,input wire[3:0]ntiles,
 // macro-panel valid M/N; only valid rows x valid 4-channel groups arrive.
 input wire[3:0]mtiles,input wire[8:0]cfg_m,cfg_n,
 input wire param_begin,param_valid,input wire[7:0]param_index,input wire signed[31:0]param_value,
 input wire in_valid,output wire in_ready,input wire[127:0]in_data,input wire[31:0]in_meta,
 output reg out_valid,input wire out_ready,output reg[127:0]out_data,output wire[127:0]out_rhs,
 output reg[31:0]out_meta,output wire coefficients_valid
);
 reg[7:0]word_count;reg[3:0]ni,nt,mi,mt;reg[255:0]valid;   // word_count = {spatial, channel group}
 wire[9:0]m_left={1'b0,cfg_m}-{1'b0,mi,5'b0},n_left={1'b0,cfg_n}-{1'b0,ni,5'b0};
 wire[5:0]vm=m_left>32?6'd32:m_left[5:0],vn=n_left>32?6'd32:n_left[5:0];
 wire[3:0]groups=(vn+6'd3)>>2;
 wire row_end={1'b0,word_count[2:0]}+1'b1==groups;
 wire tile_end=row_end&&{1'b0,word_count[7:3]}+1'b1==vm;
 reg[3:0]valid_q;
 wire advance=!out_valid||out_ready;
 assign in_ready=advance;assign coefficients_valid=&valid_q;
 wire[5:0]index={ni[2:0],word_count[2:0]};
 genvar g;generate for(g=0;g<4;g=g+1)begin:BANK
  // QM: explicit independent 18K banks. Avoid the PDS2025 inferred
  // paired-byte-write RAM transform observed to duplicate even slopes on board.
  // Byte enables are constant; bank ownership is the write clock-enable.
  // Preserve the original one-edge synchronous read and elastic hold behavior.
  wire [17:0] qa,qb;
  wire bank_write=param_valid&&(param_index[1:0]==g);
  GTP_DRM18K_E1 #(.GRS_EN("FALSE"),.DATA_WIDTH_A(32),.DATA_WIDTH_B(32),
   .WRITE_MODE_A("NORMAL_WRITE"),.WRITE_MODE_B("NORMAL_WRITE"),
   .DOA_REG(0),.DOB_REG(0),.RAM_MODE("SIMPLE_DUAL_PORT")) coefficients_ram(
   .CLKA(clk),.CLKB(clk),.CEA(bank_write),.CEB(advance&&in_valid),
   .WEA(1'b1),.WEB(1'b0),.ORCEA(1'b1),.ORCEB(1'b1),
   .RSTA(1'b0),.RSTB(1'b0),.ADDRA_HOLD(1'b0),.ADDRB_HOLD(1'b0),
   .ADDRA({3'b000,param_index[7:2],5'b00000}),.ADDRB({3'b000,index,5'b00000}),
   .BWEA(4'b1111),.BWEB(2'b00),
   .DIA({1'b0,param_value[15:8],1'b0,param_value[7:0]}),
   .DIB({1'b0,param_value[31:24],1'b0,param_value[23:16]}),.DOA(qa),.DOB(qb));
  assign out_rhs[g*32+:32]={qb[16:9],qb[7:0],qa[16:9],qa[7:0]};
 end endgenerate
 always @(posedge clk)begin
  if(rst)begin valid<=0;valid_q<=0;out_valid<=0;word_count<=0;ni<=0;nt<=0;mi<=0;mt<=0;out_data<=0;out_meta<=0;end
  else begin
   if(param_begin)valid<=0;else if(param_valid)valid[param_index]<=1;
   if(start)begin word_count<=0;ni<=0;nt<=ntiles;mi<=0;mt<=mtiles;end
   if(advance)begin
    out_valid<=in_valid;
    if(in_valid)begin
     out_data<=in_data;out_meta<=in_meta;valid_q<=valid[{index,2'b00}+:4];
     if(tile_end)begin word_count<=0;if(ni+1==nt)begin ni<=0;mi<=mi+1'b1;end else ni<=ni+1'b1;end
     else if(row_end)word_count<={word_count[7:3]+1'b1,3'b0};
     else word_count<=word_count+1'b1;
    end
   end
  end
 end
endmodule
