`timescale 1ns/1ps
module tb;
reg clk=0;always #4 clk=~clk;reg rst=1,toggle=0;reg[1:0]mode=0;reg[31:0]kind=0,a=0,b=0;reg[5:0]page=0;
wire[511:0]words;wire ready,committed,fault,has_face;integer i,checks=0;
demo_result_store dut(.clk(clk),.rst(rst),.application_mode(mode),.mark_toggle(toggle),.mark_kind(kind),.mark_a(a),.mark_b(b),.page(page),.words(words),.ready(ready),.committed(committed),.fault(fault),.has_face(has_face));
task reset(input[1:0]m);begin rst=1;repeat(4)@(negedge clk);mode=m;toggle=0;rst=0;repeat(4)@(negedge clk);end endtask
task mark(input[31:0]aa,bb);begin @(negedge clk);a=aa;b=bb;kind=32'h201;toggle=!toggle;repeat(5)@(negedge clk);end endtask
task metadata(input[31:0]magic,flags);integer j;begin for(j=0;j<16;j=j+1)mark(32'ha0000000+j,j==0?magic:j==1?1:j==3?flags:0);end endtask
task check(input expected);begin repeat(4)@(negedge clk);if(expected?(!committed||fault||!ready):(!fault||committed))$fatal(1,"result mode %d expected %d",mode,expected);checks=checks+1;end endtask
initial begin
 reset(0);metadata(32'h31445246,0);mark(32'hfffffff7,1);check(1);
 reset(1);metadata(32'h314b4d43,2);mark(32'hfffffff7,1);check(1);page=1;#1;if(ready)$fatal(1,"benchmark embedding exposed");page=0;
 reset(2);metadata(32'h314b4d43,14);mark(32'hfffffff7,1);check(1);
 reset(0);metadata(32'h314b4d43,2);mark(32'hfffffff7,1);check(0);
 reset(1);metadata(32'h31445246,0);mark(32'hfffffff7,1);check(0);
 reset(1);metadata(32'h314b4d43,1);mark(32'hfffffff7,1);check(0);
 reset(1);mark(32'h90000000,7);metadata(32'h314b4d43,2);mark(32'hfffffff7,1);check(0);
 reset(0);for(i=0;i<512;i=i+1)mark(32'h90000000+i,i);metadata(32'h31445246,1);mark(32'hfffffff7,1);check(1);
 $display("PW_RESULT_ABI_PASS checks=%0d",checks);$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
