`timescale 1ns/1ps
// UG040009 V1.6: DCLK configuration load, fresh ADC_A events and APB reads.
// No control-register writes, external analog channels or efuse operations.
module adc_temperature_reader #(
  parameter integer LOAD_WAIT=512, SETTLE_CYCLES=2700000,
  parameter integer STALE_CYCLES=6750000, READ_TIMEOUT=1024
)(
  input wire clk, rst_n,
  input wire logic_done_a, drdy, dmodified, over_temp,
  input wire [15:0] adc_data,
  output wire loadsc_n, den, secen,
  output wire [7:0] daddr,
  output reg [11:0] raw,
  output wire valid, output wire [2:0] fault,
  output reg [31:0] sample_seq, output wire ot
);
  localparam integer READY_AT=LOAD_WAIT+4+SETTLE_CYCLES;
  localparam [2:0] IDLE=0, SETUP1=1, SETUP2=2, ACCESS=3, GAP=4;
  reg [31:0] init_count, age, timeout_count;
  reg [2:0] state;
  reg done_meta, done_sync, done_old, mod_meta, mod_sync, ot_meta, ot_sync;
  reg config_changed, read_failed, have_sample;
  wire initialized = init_count == READY_AT;
  wire fresh_event = done_sync && !done_old;
  assign loadsc_n = !(init_count >= LOAD_WAIT && init_count < LOAD_WAIT+4);
  assign den = (state == SETUP1 || state == SETUP2 || state == ACCESS);
  assign secen = state == ACCESS;
  assign daddr = 8'h40;
  assign ot = ot_sync;
  // Fault: 1=startup, 2=no fresh sample/stale, 3=APB timeout or stuck DRDY,
  // 4=configuration changed by JTAG (latched until reset), 5=rail code.
  assign fault = !initialized ? 3'd1 : config_changed ? 3'd4 :
                 read_failed ? 3'd3 : (!have_sample || age >= STALE_CYCLES) ? 3'd2 :
                 (raw == 0 || raw == 12'hfff) ? 3'd5 : 3'd0;
  assign valid = fault == 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      init_count<=0; age<=STALE_CYCLES; state<=IDLE; timeout_count<=0;
      done_meta<=0; done_sync<=0; done_old<=0;
      mod_meta<=0; mod_sync<=0; ot_meta<=0; ot_sync<=0;
      config_changed<=0; read_failed<=0; have_sample<=0; raw<=0; sample_seq<=0;
    end else begin
      done_meta<=logic_done_a; done_sync<=done_meta; done_old<=done_sync;
      mod_meta<=dmodified; mod_sync<=mod_meta; ot_meta<=over_temp; ot_sync<=ot_meta;
      if (init_count < READY_AT) init_count<=init_count+1'b1;
      if (age < STALE_CYCLES) age<=age+1'b1;
      if (initialized && mod_sync) config_changed<=1;
      if (!initialized || config_changed || mod_sync) state<=IDLE;
      else case (state)
        IDLE: if (fresh_event) begin
          if (drdy) read_failed<=1; // do not accept an old completion
          else begin state<=SETUP1; timeout_count<=0; end
        end
        SETUP1: if (drdy) begin read_failed<=1; state<=GAP; end
                else state<=SETUP2;
        SETUP2: if (drdy) begin read_failed<=1; state<=GAP; end
                else state<=ACCESS; // DEN led SECEN by two complete DCLK cycles
        ACCESS: begin
          if (drdy) begin
            raw<=adc_data[15:4]; sample_seq<=sample_seq+1'b1;
            have_sample<=1; age<=0; read_failed<=0; state<=GAP;
          end else if (timeout_count == READ_TIMEOUT-1) begin
            read_failed<=1; state<=GAP;
          end else timeout_count<=timeout_count+1'b1;
        end
        GAP: state<=IDLE;
        default: state<=IDLE;
      endcase
    end
  end
endmodule
