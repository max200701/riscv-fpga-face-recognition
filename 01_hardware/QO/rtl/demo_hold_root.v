// PJ: local asynchronous assertion, synchronous release/owner hold.
// No global cold_rst OR is broadcast past this local root to mailbox RS pins.
module demo_hold_root(input wire clk,cold_rst,hold_next,output wire reset);
 (* syn_preserve=1 *) reg hold_q;
 always @(posedge clk or posedge cold_rst)
  if(cold_rst)hold_q<=1'b1;else hold_q<=hold_next;
 assign reset=hold_q;
endmodule
