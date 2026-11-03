// two-entry skid buffer. Registered in both directions (s_ready comes from a register,
// m_valid/m_data are registers), full throughput, order preserving. Used to cut long wires between the
// DDR clients (placed next to their accelerators) and the HMIC ownership arbiter (next to the DDR).
module axi_skid #(parameter W=37)(
 input wire clk,rst,
 input wire s_valid,output wire s_ready,input wire[W-1:0]s_data,
 output wire m_valid,input wire m_ready,output wire[W-1:0]m_data
);
 reg v0,v1;reg[W-1:0]d0,d1;
 assign s_ready=!rst&&!v1;assign m_valid=v0;assign m_data=d0;
 wire push=s_valid&&s_ready,pop=v0&&m_ready;
 always @(posedge clk)begin
  if(rst)begin v0<=0;v1<=0;end
  else case({push,pop})
   2'b10:if(!v0)begin v0<=1;d0<=s_data;end else begin v1<=1;d1<=s_data;end
   2'b01:if(v1)begin d0<=d1;v1<=0;end else v0<=0;
   2'b11:d0<=s_data;                          // push implies !v1, pop implies v0: the single entry is replaced
   default:;
  endcase
 end
endmodule
