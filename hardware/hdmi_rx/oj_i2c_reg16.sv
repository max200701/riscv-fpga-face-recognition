// RX candidate: new strict open-drain I2C transport, not the public driver.
// One 16-bit-address / 8-bit-value transaction. No hidden retries.
module oj_i2c_reg16 #(
 parameter integer CLK_HZ=27000000, I2C_HZ=100000,
 parameter integer TIMEOUT_CYCLES=270000
)(input wire clk, reset_n, start, read_op,
 input wire [6:0] device_address, input wire [15:0] register_address,
 input wire [7:0] write_data,
 inout wire scl, sda,
 output reg busy, done, output reg [2:0] error,
 output reg [7:0] read_data);
 localparam integer HALF=(CLK_HZ/(I2C_HZ*2)<2)?2:CLK_HZ/(I2C_HZ*2);
 localparam IDLE=0, FREE=1, START=2, TL=3, TH=4, AL=5, AH=6,
 RL=7, RH=8, RS=9, DL=10, DH=11, NL=12, NH=13,
 SL=14, SH=15, SE=16, ENDING=17;
 reg [4:0] state;
 reg scl_low,sda_low,rd;
 reg [6:0] dev;
 reg [15:0] address;
 reg [7:0] value, shift;
 reg [2:0] bit_no;
 reg [1:0] byte_no;
 reg [31:0] timer,watchdog;
 reg [1:0] scl_sync,sda_sync;
 wire high_phase=(state==TH || state==AH || state==RH || state==DH || state==NH || state==SH);
 wire tick=(timer==HALF-1);
 assign scl=scl_low?1'b0:1'bz;
 assign sda=sda_low?1'b0:1'bz;
 always @(posedge clk) begin
  if(!reset_n) begin
   state<=IDLE; scl_low<=0;sda_low<=0;busy<=0;done<=0;error<=0;
   read_data<=0;timer<=0;watchdog<=0;scl_sync<=3;sda_sync<=3;
   rd<=0;dev<=0;address<=0;value<=0;shift<=0;bit_no<=7;byte_no<=0;
  end else begin
   scl_sync<={scl_sync[0],scl};sda_sync<={sda_sync[0],sda};done<=0;
   if(!busy) begin timer<=0;watchdog<=0;end
   else begin
    watchdog<=watchdog+1;
    if(high_phase && !scl_sync[1]) timer<=0;
    else if(tick) timer<=0;
    else timer<=timer+1;
   end
   case(state)
    IDLE: if(start) begin
     rd<=read_op;dev<=device_address;address<=register_address;value<=write_data;
     error<=0;read_data<=0;busy<=1;state<=FREE;scl_low<=0;sda_low<=0;
    end
    FREE: if(scl_sync[1] && sda_sync[1]) begin
     sda_low<=1;state<=START;timer<=0;
    end
    START: if(tick) begin
     scl_low<=1;shift<={dev,1'b0};sda_low<=!dev[6];bit_no<=7;byte_no<=0;state<=TL;
    end
    TL: if(tick) begin scl_low<=0;state<=TH;end
    TH: if(scl_sync[1] && tick) begin
     scl_low<=1;
     if(bit_no==0) begin sda_low<=0;state<=AL;end
     else begin bit_no<=bit_no-1;shift<={shift[6:0],1'b0};sda_low<=!shift[6];state<=TL;end
    end
    AL: if(tick) begin scl_low<=0;state<=AH;end
    AH: if(scl_sync[1] && tick) begin
     scl_low<=1;
     if(sda_sync[1]) begin error<=1;sda_low<=1;state<=SL;end
     else if(byte_no==0) begin
      byte_no<=1;shift<=address[7:0];sda_low<=!address[7];bit_no<=7;state<=TL;
     end else if(byte_no==1) begin
      byte_no<=2;shift<=address[15:8];sda_low<=!address[15];bit_no<=7;state<=TL;
     end else if(byte_no==2 && rd) begin sda_low<=0;state<=RL;end
     else if(byte_no==2) begin
      byte_no<=3;shift<=value;sda_low<=!value[7];bit_no<=7;state<=TL;
     end else if(rd) begin sda_low<=0;bit_no<=7;state<=DL;end
     else begin sda_low<=1;state<=SL;end
    end
    RL: if(tick) begin scl_low<=0;state<=RH;end
    RH: if(scl_sync[1] && tick) begin sda_low<=1;state<=RS;end
    RS: if(tick) begin
     scl_low<=1;byte_no<=3;shift<={dev,1'b1};sda_low<=!dev[6];bit_no<=7;state<=TL;
    end
    DL: if(tick) begin scl_low<=0;state<=DH;end
    DH: if(scl_sync[1] && tick) begin
     scl_low<=1;read_data<={read_data[6:0],sda_sync[1]};
     if(bit_no==0) begin sda_low<=0;state<=NL;end
     else begin bit_no<=bit_no-1;state<=DL;end
    end
    NL: if(tick) begin scl_low<=0;state<=NH;end // master NACKs sole read byte
    NH: if(scl_sync[1] && tick) begin scl_low<=1;sda_low<=1;state<=SL;end
    SL: if(tick) begin scl_low<=0;state<=SH;end
    SH: if(scl_sync[1] && tick) begin sda_low<=0;state<=SE;end
    SE: if(tick) begin state<=ENDING;end
    ENDING: begin busy<=0;done<=1;state<=IDLE;end
    default: begin busy<=0;done<=1;error<=3;scl_low<=0;sda_low<=0;state<=IDLE;end
   endcase
   if(busy && watchdog>=TIMEOUT_CYCLES-1) begin
    busy<=0;done<=1;error<=2;scl_low<=0;sda_low<=0;state<=IDLE;timer<=0;
   end
  end
 end
endmodule
