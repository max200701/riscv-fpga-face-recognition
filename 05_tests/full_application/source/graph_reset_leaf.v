// Local asynchronous assertion, three-edge synchronous release.
// Preserve each leaf: physical mapping must still prove distinct registers.
module graph_reset_leaf(input wire clk,arst,output wire reset);
 (* ASYNC_REG="TRUE" *) reg[2:0] stages /* synthesis syn_preserve=1 */;
 always @(posedge clk or posedge arst)
  if(arst)stages<=3'b111;else stages<={stages[1:0],1'b0};
 assign reset=stages[2];
endmodule
