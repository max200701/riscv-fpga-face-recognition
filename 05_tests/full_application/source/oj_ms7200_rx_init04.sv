// New RX-only sequencer around exact, attributed register constants.
// stream_candidate is only the PUBLIC REFERENCE'S status interpretation;
// measured PCLK/DE/VS dimensions and RGB test-pattern checks remain separate gates.
module oj_ms7200_rx_init04 #(
 parameter integer CLK_HZ=27000000, I2C_HZ=100000,
 parameter integer POWER_STABLE_CYCLES=CLK_HZ/50, RESET_CYCLES=CLK_HZ/50, SETTLE_CYCLES=CLK_HZ/100,
 parameter PCLK_INV=1'b1,
 parameter integer POLL_CYCLES=CLK_HZ/100, MAX_LOCK_POLLS=1000,
 parameter integer TIMEOUT_CYCLES=CLK_HZ/100
)(input wire clk,reset_n,enable,power_stable,
 inout wire scl,sda, output reg receiver_reset_n,
 output reg configured,stream_candidate,fault,
 output reg [7:0] fault_code,output reg [31:0] raw_status,
 output reg [15:0] transactions_ok, output reg [8:0] table_index,
 output reg pclk_config_verified,output reg[7:0]pclk_before,pclk_after);
 `include "oj_ms7200_table.vh"
 localparam HOLD=0, SETTLE=1, ISSUE=2, WAIT_DONE=3, DELAY=4, FAILED=5;
 localparam PROBE_W=0, PROBE_R=1, TABLE=2, EDID=3, POLL=4, SETTING=5,PCLK_R=6,PCLK_W=7,PCLK_CHECK=8;
 reg [2:0]state;reg[3:0]phase;reg[31:0]power_count;reg[7:0]pclk_expected;
 reg [31:0] counter;
 reg [15:0] poll_count;
 reg [7:0] edid_index;
 reg [1:0] status_index;
 reg [2:0] setting_index;
 reg need_setting;
 reg stable_two;
 reg start,read_op;
 reg [15:0] address;
 reg [7:0] write_value;
 wire busy,done;
 wire [2:0] transfer_error;
 wire [7:0] read_value;
 // Initial acquisition still requires state 2. Following verified output and
 // PCLK setup, observed state 3 must not invalidate an established stream.
 // Any loss of bit17 invalidates it; state 3 alone cannot bootstrap/reacquire.
 wire link_qualified=raw_status[17] && (!raw_status[16] || (stream_candidate&&pclk_config_verified));
 wire [23:0] entry=rx_table(table_index);
 wire [23:0] edid_expected=rx_table(9'd38+{1'b0,edid_index});
 wire [23:0] setting=rx_table(9'd304+{6'b0,setting_index});
 oj_i2c_reg16 #(.CLK_HZ(CLK_HZ),.I2C_HZ(I2C_HZ),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) transport(
  .clk(clk),.reset_n(reset_n),.start(start),.read_op(read_op),
  .device_address(7'h2b),.register_address(address),.write_data(write_value),
  .scl(scl),.sda(sda),.busy(busy),.done(done),.error(transfer_error),.read_data(read_value));
 always @(posedge clk) begin
  if(!reset_n) begin
   state<=HOLD;phase<=PROBE_W;counter<=0;receiver_reset_n<=0;
   configured<=0;stream_candidate<=0;fault<=0;fault_code<=0;raw_status<=0;
   table_index<=0;power_count<=0;pclk_config_verified<=0;pclk_before<=0;pclk_after<=0;pclk_expected<=0;edid_index<=0;status_index<=0;setting_index<=0;
   need_setting<=1;stable_two<=0;poll_count<=0;start<=0;read_op<=0;address<=0;write_value<=0;transactions_ok<=0;
  end else begin
   start<=0;
   case(state)
    HOLD: if(enable&&power_stable) begin
     // Require a contiguous digital power qualification, then at least 20ms
     // low reset at default settings. This does not measure analog rail levels.
     if(power_count<POWER_STABLE_CYCLES)begin power_count<=power_count+1'b1;counter<=0;end
     else if(counter>=RESET_CYCLES-1)begin receiver_reset_n<=1;counter<=0;state<=SETTLE;end
     else counter<=counter+1;
    end else begin power_count<=0;counter<=0;end
    SETTLE: if(counter>=SETTLE_CYCLES-1) begin state<=ISSUE;counter<=0;end
            else counter<=counter+1;
    ISSUE: if(!busy) begin
     start<=1;state<=WAIT_DONE;
     case(phase)
      PROBE_W: begin address<=16'h0003;write_value<=8'h5a;read_op<=0;end
      PROBE_R: begin address<=16'h0003;write_value<=0;read_op<=1;end
      TABLE: begin address<=entry[23:8];write_value<=entry[7:0];read_op<=0;end
      EDID: begin address<=16'h0d00+edid_index;write_value<=0;read_op<=1;end
      POLL: begin address<=16'h209c+status_index;write_value<=0;read_op<=1;end
      SETTING: begin address<=setting[23:8];write_value<=setting[7:0];read_op<=0;end
      PCLK_R,PCLK_CHECK:begin address<=16'h1281;write_value<=0;read_op<=1;end
      PCLK_W:begin address<=16'h1281;write_value<=pclk_expected;read_op<=0;end
      default: begin start<=0;fault<=1;fault_code<=8'h23;state<=FAILED;end
     endcase
    end
    WAIT_DONE: if(done) begin
     if(transfer_error!=0) begin
      fault<=1;fault_code<={5'b00001,transfer_error};stream_candidate<=0;state<=FAILED;
     end else begin
      transactions_ok<=transactions_ok+1;state<=ISSUE;
      case(phase)
       PROBE_W: phase<=PROBE_R;
       PROBE_R: if(read_value==8'h5a) begin phase<=TABLE;table_index<=0;end
                else begin fault<=1;fault_code<=8'h20;state<=FAILED;end
       // Board probe confirms EDID reads return zero with register 000c[7]=0.
       // Check all EDID bytes after write 293, before close-window write 294.
       TABLE: if(table_index==299) begin phase<=POLL;end
              else begin
               table_index<=table_index+1;
               if(table_index==293) begin phase<=EDID;edid_index<=0;end
              end
       EDID: if(read_value!=edid_expected[7:0]) begin fault<=1;fault_code<=8'h21;state<=FAILED;end
             else if(edid_index==255) begin configured<=1;phase<=TABLE;status_index<=0;end
             else edid_index<=edid_index+1;
       POLL: begin
        raw_status[status_index*8+:8]<=read_value;
        if(status_index==3) begin
         status_index<=0;
         // Own receiver reset + verified configuration establish this session.
         // No requirement to have sampled an earlier unlocked state: HDMI may
         // already be stable by the end of 256 EDID readbacks. Qualify state 2
         // over TWO consecutive complete status polls before each setting run.
         if(!link_qualified) begin
          need_setting<=1;stable_two<=0;stream_candidate<=0;pclk_config_verified<=0;
         end else if(need_setting) stable_two<=1;
         if(link_qualified && need_setting && stable_two) begin
          phase<=SETTING;setting_index<=0;need_setting<=0;stable_two<=0;poll_count<=0;
         end else if(!stream_candidate && poll_count>=MAX_LOCK_POLLS-1) begin
          fault<=1;fault_code<=8'h22;state<=FAILED;
         end else begin
          if(!stream_candidate) poll_count<=poll_count+1;
          counter<=0;state<=DELAY;
         end
        end else status_index<=status_index+1;
       end
       SETTING: if(setting_index==6)begin phase<=PCLK_R;state<=ISSUE;pclk_config_verified<=0;end
                else setting_index<=setting_index+1;
       PCLK_R:begin
        pclk_before<=read_value;pclk_expected<=(read_value&8'hfb)|(PCLK_INV?8'h04:8'h00);
        phase<=PCLK_W;
       end
       PCLK_W:phase<=PCLK_CHECK;
       PCLK_CHECK:begin
        pclk_after<=read_value;
        if(read_value!=pclk_expected)begin fault<=1;fault_code<=8'h24;stream_candidate<=0;state<=FAILED;end
        else begin pclk_config_verified<=1;stream_candidate<=1;phase<=POLL;status_index<=0;counter<=0;state<=DELAY;end
       end
       default: begin fault<=1;fault_code<=8'h23;state<=FAILED;end
      endcase
     end
    end
    DELAY: if(counter>=POLL_CYCLES-1) begin counter<=0;state<=ISSUE;end
           else counter<=counter+1;
    FAILED: begin start<=0;stream_candidate<=0;end // explicit reset is required; no hidden retries
    default: begin fault<=1;fault_code<=8'h23;state<=FAILED;end
   endcase
   if(state!=HOLD&&!power_stable)begin
    receiver_reset_n<=0;configured<=0;stream_candidate<=0;pclk_config_verified<=0;fault<=1;fault_code<=8'h25;state<=FAILED;start<=0;
   end
  end
 end
endmodule
