`timescale 1ns/1ps
module tb;
reg clk=0;always #4 clk=~clk;reg rst=1,rx_valid=0,tx_ready=1,app_running=0,start_allowed=1,memory_write_allowed=1;
reg[7:0]rx_data=0;wire rx_ready,tx_valid;wire[7:0]tx_data;wire[1:0]mode;wire[31:0]iters;
wire fault;reg[31:0]gen=7;reg[7:0]p[0:39],reply[0:23];integer n=0,checks=0;
demo_packet_endpoint #(.RECEIVE_TIMEOUT(20000),.MEMORY_TIMEOUT(20000)) dut(
 .clk(clk),.rst(rst),.rx_valid(rx_valid),.rx_ready(rx_ready),.rx_data(rx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),
 .app_running(app_running),.start_allowed(start_allowed),.memory_drained(1'b1),.rearm_allowed(1'b0),.rearm_ack(1'b0),.result_has_face(1'b0),
 .video_arm_allowed(1'b0),.video_stop_allowed(1'b0),.video_recover_allowed(1'b0),.memory_read_allowed(1'b1),.memory_write_allowed(memory_write_allowed),
 .video_next_generation(32'b0),.video_held_generation(32'b0),.video_status_words(512'b0),.session_generation(gen),
 .status_words(512'b0),.result_words(512'b0),.result_ready(1'b0),.application_mode(mode),.benchmark_iterations(iters),.link_fault(fault),
 .p_rd_ready(1'b0),.p_r_valid(1'b0),.p_r_data(256'b0),.p_r_token(64'b0),.p_r_index(7'b0),.p_r_last(1'b0),.p_r_error(1'b0),
 .p_wr_ready(1'b0),.p_w_ready(1'b0),.p_b_valid(1'b0),.p_b_token(64'b0),.p_b_error(1'b0));
always @(posedge clk)if(tx_valid&&tx_ready)begin reply[n]=tx_data;n=n+1;end
function[31:0]cb(input[31:0]c,input[7:0]b);reg[31:0]x;integer k;begin x=c^b;for(k=0;k<8;k=k+1)x=(x>>1)^(x[0]?32'hedb88320:0);cb=x;end endfunction
task word(input integer off,input[31:0]v);integer j;begin for(j=0;j<4;j=j+1)p[off+j]=v>>(8*j);end endtask
task request(input[31:0]seq,g,m,it,input integer bad,input[7:0]expect_status);
 reg[31:0]c;integer i,waited;begin
 for(i=0;i<40;i=i+1)p[i]=0;word(0,32'h31444246);p[4]=1;p[5]=14;word(8,seq);word(12,g);word(16,16);word(24,m);word(28,it);
 c=32'hffffffff;for(i=0;i<20;i=i+1)c=cb(c,p[i]);for(i=24;i<40;i=i+1)c=cb(c,p[i]);word(20,(~c)^bad);n=0;
 for(i=0;i<40;i=i+1)begin @(negedge clk);rx_valid=1;rx_data=p[i];@(posedge clk);while(!rx_ready)@(posedge clk);end
 @(negedge clk);rx_valid=0;waited=0;while(n<24&&waited<5000)begin @(negedge clk);waited=waited+1;end
 if(n!=24||reply[6]!=expect_status)$fatal(1,"reply seq=%d bytes=%d got=%d want=%d",seq,n,reply[6],expect_status);
 c=32'hffffffff;for(i=0;i<20;i=i+1)c=cb(c,reply[i]);if({reply[23],reply[22],reply[21],reply[20]}!=~c)$fatal(1,"reply CRC");
 repeat(3)@(negedge clk);checks=checks+1;
 end endtask
initial begin
 repeat(3)@(negedge clk);rst=0;request(1,7,1,4000,0,0);if(mode!=1||iters!=4000)$fatal(1,"config");
 request(1,7,1,4000,0,0);if(mode!=1)$fatal(1,"replay");
 request(1,7,2,4000,0,7);if(mode!=1)$fatal(1,"changed replay");
 request(2,6,2,1,0,7);request(3,7,3,1,0,2);request(4,7,1,0,0,2);request(5,7,1,10001,0,2);
 request(6,7,0,1,0,2);request(7,7,2,1,1,1);if(mode!=1||iters!=4000)$fatal(1,"rejection changed config");
 app_running=1;request(8,7,2,1,0,4);app_running=0;memory_write_allowed=0;request(9,7,2,1,0,6);memory_write_allowed=1;
 request(10,7,2,1,0,0);if(mode!=2||iters!=1)$fatal(1,"validation");request(11,7,0,0,0,0);if(mode||iters)$fatal(1,"face restore");
 rst=1;repeat(3)@(negedge clk);if(mode||iters)$fatal(1,"cold reset");
 $display("PW_MODE_ABI_PASS checks=%0d",checks);$finish;
end
initial begin #2000000;$fatal(1,"timeout");end
endmodule
