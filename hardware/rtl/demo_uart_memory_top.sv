// UART boot + application owner + HMIC boundary. NOT the full CPU/NPU board top.
// app_* ports match the selected original-CPU application memory master.
// Real clock/reset/temperature CDC and HMIC PHY remain integration gates.
// The physical integration must supply real temperature/clock/reset status and
// exclusively arbitrate this boot master with the application before START.
module demo_uart_memory_top #(
 parameter integer CLOCK_HZ=133250000,BAUD=921600,VIDEO_WIDTH=640,VIDEO_HEIGHT=480,VIDEO_FIFO_AW=12
)(
 input wire clk,rst,uart_rx_pin,output wire uart_tx_pin,
 input wire video_pclk,video_prst,video_pixel_lock,video_vs,video_de,input wire[23:0]video_rgb,
 input wire video_rx_configured,video_rx_candidate,video_rx_fault,
 input wire[7:0]video_rx_fault_code,input wire[31:0]video_rx_raw_status,
 input wire ddr_init_done,controller_quiescent,safety_ready,
input wire application_done,application_drained,application_fault,
 input wire model_qualify,output wire model_verified,
 input wire gallery_qualify,output wire gallery_verified,
 output wire[1:0] application_mode,output wire[31:0] benchmark_iterations,
 output wire application_hold,application_hold_next,done,output wire[2:0]phase,
 input wire app_rd_valid,
 output wire app_rd_ready,
 input wire[31:0] app_rd_addr,
 input wire[6:0] app_rd_beats,
 input wire[63:0] app_rd_token,
 input wire[2:0] app_rd_owner,
 output wire app_r_valid,
 input wire app_r_ready,
 output wire[255:0] app_r_data,
 output wire[63:0] app_r_token,
 output wire[6:0] app_r_index,
 output wire app_r_last,
 output wire app_r_error,
 input wire app_wr_valid,
 output wire app_wr_ready,
 input wire[31:0] app_wr_addr,
 input wire[6:0] app_wr_beats,
 input wire[63:0] app_wr_token,
 input wire[2:0] app_wr_owner,
 input wire app_w_valid,
 output wire app_w_ready,
 input wire[255:0] app_w_data,
 input wire[31:0] app_w_strb,
 input wire app_w_last,
 output wire app_b_valid,
 input wire app_b_ready,
 output wire[63:0] app_b_token,
 output wire app_b_error,
 input wire[511:0]status_words,result_words,input wire result_ready,result_has_face,output wire[5:0]result_page,output wire start_pulse,
 output wire fault,output wire[7:0]fault_code,
 output wire[31:0]accepted_writes,rejected_packets,
 output wire[63:0]physical_read_bytes,physical_write_bytes,verify_read_bytes,
 output wire[31:0]verified_writes,verify_retries,
 output wire axi_arvalid,input wire axi_arready,output wire[27:0]axi_araddr,
 output wire[3:0]axi_arlen,axi_aruser_id,output wire axi_aruser_ap,
 input wire axi_rvalid,input wire[255:0]axi_rdata,input wire[3:0]axi_rid,input wire axi_rlast,
 output wire axi_awvalid,input wire axi_awready,output wire[27:0]axi_awaddr,
 output wire[3:0]axi_awlen,axi_awuser_id,output wire axi_awuser_ap,
 output wire[255:0]axi_wdata,output wire[31:0]axi_wstrb,
 input wire axi_wready,input wire[3:0]axi_wusero_id,input wire axi_wusero_last
);
 wire rx_valid,rx_ready,tx_valid,tx_ready,frame_fault,overflow_fault,link_fault,hmic_fault;
 wire[7:0]rx_data,tx_data;
 wire p_rd_valid,p_rd_ready;wire[31:0]p_rd_addr;wire[6:0]p_rd_beats;wire[63:0]p_rd_token;wire[2:0]p_rd_owner;
 wire p_r_valid,p_r_ready;wire[255:0]p_r_data;wire[63:0]p_r_token;wire[6:0]p_r_index;wire p_r_last,p_r_error;
 wire p_wr_valid,p_wr_ready;wire[31:0]p_wr_addr;wire[6:0]p_wr_beats;wire[63:0]p_wr_token;wire[2:0]p_wr_owner;
 wire p_w_valid,p_w_ready;wire[255:0]p_w_data;wire[31:0]p_w_strb;wire p_w_last;
 wire p_b_valid,p_b_ready;wire[63:0]p_b_token;wire p_b_error;
 wire boot_rd_valid;
 wire boot_rd_ready;
 wire[31:0] boot_rd_addr;
 wire[6:0] boot_rd_beats;
 wire[63:0] boot_rd_token;
 wire[2:0] boot_rd_owner;
 wire boot_r_valid;
 wire boot_r_ready;
 wire[255:0] boot_r_data;
 wire[63:0] boot_r_token;
 wire[6:0] boot_r_index;
 wire boot_r_last;
 wire boot_r_error;
 wire boot_wr_valid;
 wire boot_wr_ready;
 wire[31:0] boot_wr_addr;
 wire[6:0] boot_wr_beats;
 wire[63:0] boot_wr_token;
 wire[2:0] boot_wr_owner;
 wire boot_w_valid;
 wire boot_w_ready;
 wire[255:0] boot_w_data;
 wire[31:0] boot_w_strb;
 wire boot_w_last;
 wire boot_b_valid;
 wire boot_b_ready;
 wire[63:0] boot_b_token;
 wire boot_b_error;
 wire app_running,boot_allowed,owner_fault;
 wire rearm_allowed,rearm_ack,rearm_pulse,endpoint_rearm_ack;wire[31:0]session_generation;
 wire owner_safety=safety_ready&&ddr_init_done&&!frame_fault&&!overflow_fault&&!link_fault&&!hmic_fault;
 wire memory_drained;
 demo_model_residency resident_models(.clk(clk),.rst(rst),.ddr_ready(ddr_init_done),
  .fault(fault||application_fault||!safety_ready),
  .qualify(model_qualify&&app_running&&memory_drained&&owner_safety),
  .write_fire(p_wr_valid&&p_wr_ready),.write_address(p_wr_addr),.write_beats(p_wr_beats),
  .verified(model_verified));
 demo_gallery_residency resident_gallery(.clk(clk),.rst(rst),.ddr_ready(ddr_init_done),
  .fault(fault||application_fault||!safety_ready),
  .qualify(gallery_qualify&&app_running&&memory_drained&&owner_safety),
  .write_fire(p_wr_valid&&p_wr_ready),.write_address(p_wr_addr),.write_beats(p_wr_beats),
  .verified(gallery_verified));
 wire start_allowed;
 assign fault=frame_fault||overflow_fault||link_fault||hmic_fault||owner_fault;
 wire video_reserved,video_start_allowed,video_read_allowed,video_write_allowed;
 assign start_allowed=video_start_allowed&&owner_safety;
 wire video_arm_allowed,video_stop_allowed,video_recover_allowed,video_arm_pulse,video_stop_pulse,video_recover_pulse;
 wire[31:0]video_frame,video_generation,video_next_generation,video_held_generation,video_held_frame;
 wire[511:0]video_status_words;
 wire capture_arm_ready,capture_busy,capture_frame_ready,capture_rejected,recovery_ready,recovery_done,recovery_waiting_source,source_stopped;
 wire capture_release;wire[31:0]release_generation,pixels_accepted,writes_acknowledged;
 wire[7:0]capture_error,liveness_fault,video_writer_fault_code;wire video_writer_fault;
 wire  uart_wr_valid;
 wire  uart_wr_ready;
 wire [31:0] uart_wr_addr;
 wire [6:0] uart_wr_beats;
 wire [63:0] uart_wr_token;
 wire [2:0] uart_wr_owner;
 wire  uart_w_valid;
 wire  uart_w_ready;
 wire [255:0] uart_w_data;
 wire [31:0] uart_w_strb;
 wire  uart_w_last;
 wire  uart_b_valid;
 wire  uart_b_ready;
 wire [63:0] uart_b_token;
 wire  uart_b_error;
 wire  video_wr_valid;
 wire  video_wr_ready;
 wire [31:0] video_wr_addr;
 wire [6:0] video_wr_beats;
 wire [63:0] video_wr_token;
 wire [2:0] video_wr_owner;
 wire  video_w_valid;
 wire  video_w_ready;
 wire [255:0] video_w_data;
 wire [31:0] video_w_strb;
 wire  video_w_last;
 wire  video_b_valid;
 wire  video_b_ready;
 wire [63:0] video_b_token;
 wire  video_b_error;
 assign boot_wr_valid=video_reserved?video_wr_valid:uart_wr_valid;
 assign boot_wr_addr=video_reserved?video_wr_addr:uart_wr_addr;
 assign boot_wr_beats=video_reserved?video_wr_beats:uart_wr_beats;
 assign boot_wr_token=video_reserved?video_wr_token:uart_wr_token;
 assign boot_wr_owner=video_reserved?video_wr_owner:uart_wr_owner;
 assign boot_w_valid=video_reserved?video_w_valid:uart_w_valid;
 assign boot_w_data=video_reserved?video_w_data:uart_w_data;
 assign boot_w_strb=video_reserved?video_w_strb:uart_w_strb;
 assign boot_w_last=video_reserved?video_w_last:uart_w_last;
 assign boot_b_ready=video_reserved?video_b_ready:uart_b_ready;
 assign uart_wr_ready=!video_reserved&&boot_wr_ready; assign video_wr_ready=video_reserved&&boot_wr_ready;
 assign uart_w_ready=!video_reserved&&boot_w_ready; assign video_w_ready=video_reserved&&boot_w_ready;
 assign uart_b_valid=!video_reserved&&boot_b_valid; assign video_b_valid=video_reserved&&boot_b_valid;
 assign uart_b_token=boot_b_token;assign video_b_token=boot_b_token;
 assign uart_b_error=boot_b_error;assign video_b_error=boot_b_error;
 om_video_session video_session(
 .clk(clk),.rst(rst),.boot_allowed(boot_allowed),.memory_drained(memory_drained),.app_running(app_running),.start_pulse(start_pulse),
 .arm_pulse(video_arm_pulse),.stop_pulse(video_stop_pulse),.recover_pulse(video_recover_pulse),
 .requested_frame(video_frame),.requested_generation(video_generation),.session_generation(session_generation),
 .owner_rearm_ack(rearm_ack),.capture_arm_ready(capture_arm_ready),.capture_busy(capture_busy),.capture_frame_ready(capture_frame_ready),
 .capture_rejected(capture_rejected),.recovery_ready(recovery_ready),.recovery_done(recovery_done),.recovery_waiting_source(recovery_waiting_source),.source_stopped(source_stopped),
 .held_generation(video_held_generation),.held_frame(video_held_frame),.pixels_accepted(pixels_accepted),.writes_acknowledged(writes_acknowledged),
 .capture_error(capture_error),.liveness_fault(liveness_fault),.writer_fault_code(video_writer_fault_code),.writer_fault(video_writer_fault),
 .result_ready(result_ready),.rx_configured(video_rx_configured),.rx_candidate(video_rx_candidate),.rx_fault(video_rx_fault),
 .rx_fault_code(video_rx_fault_code),.rx_raw_status(video_rx_raw_status),
 .video_reserved(video_reserved),.arm_allowed(video_arm_allowed),.stop_allowed(video_stop_allowed),.recover_allowed(video_recover_allowed),
 .start_allowed(video_start_allowed),.read_allowed(video_read_allowed),.write_allowed(video_write_allowed),
 .release_frame(capture_release),.release_generation(release_generation),.endpoint_rearm_ack(endpoint_rearm_ack),
 .next_generation(video_next_generation),.status_words(video_status_words));
 oj_video_capture_recovery #(.WIDTH(VIDEO_WIDTH),.HEIGHT(VIDEO_HEIGHT),.SOURCE_WIDTH(VIDEO_WIDTH),.SOURCE_HEIGHT(VIDEO_HEIGHT),.FIFO_AW(VIDEO_FIFO_AW)) video_capture(
 .pclk(video_pclk),.prst(video_prst),.pixel_lock(video_pixel_lock),.vs(video_vs),.de(video_de),.rgb(video_rgb),
 .uclk(clk),.urst(rst),.arm(video_arm_pulse&&video_arm_allowed),.boot_allowed(boot_allowed),.bridge_drained(memory_drained),
 .generation(video_generation),.frame_id(video_frame),.base_address(32'h01800000),.arm_ready(capture_arm_ready),
 .release_frame(capture_release),.release_generation(release_generation),.cancel_request(video_stop_pulse&&video_stop_allowed),.recover_request(video_recover_pulse&&video_recover_allowed),
 .capture_busy(capture_busy),.liveness_fault(liveness_fault),.recovery_waiting_source(recovery_waiting_source),.source_stopped(source_stopped),.recovery_ready(recovery_ready),.recovery_done(recovery_done),
 .frame_ready(capture_frame_ready),.frame_rejected(capture_rejected),.capture_error(capture_error),.writer_fault(video_writer_fault),.writer_fault_code(video_writer_fault_code),
 .held_generation(video_held_generation),.held_frame_id(video_held_frame),.pixels_accepted(pixels_accepted),.writes_acknowledged(writes_acknowledged),
 .p_wr_valid(video_wr_valid),
 .p_wr_ready(video_wr_ready),
 .p_wr_addr(video_wr_addr),
 .p_wr_beats(video_wr_beats),
 .p_wr_token(video_wr_token),
 .p_wr_owner(video_wr_owner),
 .p_w_valid(video_w_valid),
 .p_w_ready(video_w_ready),
 .p_w_data(video_w_data),
 .p_w_strb(video_w_strb),
 .p_w_last(video_w_last),
 .p_b_valid(video_b_valid),
 .p_b_ready(video_b_ready),
 .p_b_token(video_b_token),
 .p_b_error(video_b_error));
 demo_uart_frontend #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) serial_link(
  .clk(clk),
  .rst(rst),
  .uart_rx_pin(uart_rx_pin),
  .uart_tx_pin(uart_tx_pin),
  .rx_valid(rx_valid),
  .rx_ready(rx_ready),
  .rx_data(rx_data),
  .tx_valid(tx_valid),
  .tx_ready(tx_ready),
  .tx_data(tx_data),
  .frame_fault(frame_fault),
  .overflow_fault(overflow_fault));
 demo_packet_endpoint #(.RECEIVE_TIMEOUT(CLOCK_HZ),.MEMORY_TIMEOUT(CLOCK_HZ)) endpoint(
  .clk(clk),
  .rst(rst),
  .rx_valid(rx_valid),
  .rx_ready(rx_ready),
  .rx_data(rx_data),
  .tx_valid(tx_valid),
  .tx_ready(tx_ready),
  .tx_data(tx_data),
  .video_arm_allowed(video_arm_allowed),.video_stop_allowed(video_stop_allowed),.video_recover_allowed(video_recover_allowed),
  .memory_read_allowed(video_read_allowed),.memory_write_allowed(video_write_allowed),
  .video_next_generation(video_next_generation),.video_held_generation(video_held_generation),.video_status_words(video_status_words),
  .video_arm_pulse(video_arm_pulse),.video_stop_pulse(video_stop_pulse),.video_recover_pulse(video_recover_pulse),
  .video_frame(video_frame),.video_generation(video_generation),
  .app_running(app_running),
  .start_allowed(start_allowed),
  .memory_drained(memory_drained),
  .rearm_allowed(rearm_allowed),.rearm_ack(endpoint_rearm_ack),.rearm_pulse(rearm_pulse),
  .result_has_face(result_has_face),.session_generation(session_generation),
  .status_words(status_words),.result_words(result_words),.result_ready(result_ready),.result_page(result_page),
  .application_mode(application_mode),.benchmark_iterations(benchmark_iterations),
  .start_pulse(start_pulse),
  .link_fault(link_fault),
  .accepted_writes(accepted_writes),
  .rejected_packets(rejected_packets),
  .p_rd_valid(boot_rd_valid),
  .p_rd_ready(boot_rd_ready),
  .p_rd_addr(boot_rd_addr),
  .p_rd_beats(boot_rd_beats),
  .p_rd_token(boot_rd_token),
  .p_rd_owner(boot_rd_owner),
  .p_r_valid(boot_r_valid),
  .p_r_ready(boot_r_ready),
  .p_r_data(boot_r_data),
  .p_r_token(boot_r_token),
  .p_r_index(boot_r_index),
  .p_r_last(boot_r_last),
  .p_r_error(boot_r_error),
  .p_wr_valid(uart_wr_valid),
  .p_wr_ready(uart_wr_ready),
  .p_wr_addr(uart_wr_addr),
  .p_wr_beats(uart_wr_beats),
  .p_wr_token(uart_wr_token),
  .p_wr_owner(uart_wr_owner),
  .p_w_valid(uart_w_valid),
  .p_w_ready(uart_w_ready),
  .p_w_data(uart_w_data),
  .p_w_strb(uart_w_strb),
  .p_w_last(uart_w_last),
  .p_b_valid(uart_b_valid),
  .p_b_ready(uart_b_ready),
  .p_b_token(uart_b_token),
  .p_b_error(uart_b_error));
 demo_hmic_bridge #(.WRITE_READBACK(0)) bridge(
  .clk(clk),
  .rst(rst),
  .ddr_init_done(ddr_init_done),
  .controller_quiescent(controller_quiescent),
  .fault(hmic_fault),
  .fault_code(fault_code),
  .drained(memory_drained),
  .p_rd_valid(p_rd_valid),
  .p_rd_ready(p_rd_ready),
  .p_rd_addr(p_rd_addr),
  .p_rd_beats(p_rd_beats),
  .p_rd_token(p_rd_token),
  .p_rd_owner(p_rd_owner),
  .p_r_valid(p_r_valid),
  .p_r_ready(p_r_ready),
  .p_r_data(p_r_data),
  .p_r_token(p_r_token),
  .p_r_index(p_r_index),
  .p_r_last(p_r_last),
  .p_r_error(p_r_error),
  .p_wr_valid(p_wr_valid),
  .p_wr_ready(p_wr_ready),
  .p_wr_addr(p_wr_addr),
  .p_wr_beats(p_wr_beats),
  .p_wr_token(p_wr_token),
  .p_wr_owner(p_wr_owner),
  .p_w_valid(p_w_valid),
  .p_w_ready(p_w_ready),
  .p_w_data(p_w_data),
  .p_w_strb(p_w_strb),
  .p_w_last(p_w_last),
  .p_b_valid(p_b_valid),
  .p_b_ready(p_b_ready),
  .p_b_token(p_b_token),
  .p_b_error(p_b_error),
  .axi_arvalid(axi_arvalid),
  .axi_arready(axi_arready),
  .axi_araddr(axi_araddr),
  .axi_arlen(axi_arlen),
  .axi_aruser_id(axi_aruser_id),
  .axi_aruser_ap(axi_aruser_ap),
  .axi_rvalid(axi_rvalid),
  .axi_rdata(axi_rdata),
  .axi_rid(axi_rid),
  .axi_rlast(axi_rlast),
  .axi_awvalid(axi_awvalid),
  .axi_awready(axi_awready),
  .axi_awaddr(axi_awaddr),
  .axi_awlen(axi_awlen),
  .axi_awuser_id(axi_awuser_id),
  .axi_awuser_ap(axi_awuser_ap),
  .axi_wdata(axi_wdata),
  .axi_wstrb(axi_wstrb),
  .axi_wready(axi_wready),
  .axi_wusero_id(axi_wusero_id),
  .axi_wusero_last(axi_wusero_last),
  .physical_read_bytes(physical_read_bytes),
  .physical_write_bytes(physical_write_bytes),
  .verify_read_bytes(verify_read_bytes),
  .verified_writes(verified_writes),
  .verify_retries(verify_retries),
  .reserved_beats(),
  .reserved_requests());
 demo_boot_owner ownership(
  .clk(clk),
  .cold_rst(rst),
  .rearm_request(rearm_pulse),.rearm_allowed(rearm_allowed),.rearm_ack(rearm_ack),.session_generation(session_generation),
  .start_request(start_pulse),
  .memory_drained(memory_drained),
  .safety_ready(owner_safety),
  .application_done(application_done),
  .application_drained(application_drained),
  .application_fault(application_fault),
  .application_hold(application_hold),.application_hold_next(application_hold_next),
  .app_selected(app_running),
  .boot_allowed(boot_allowed),
  .done(done),
  .fault(owner_fault),
  .phase(phase),
  .boot_rd_valid(boot_rd_valid),
  .app_rd_valid(app_rd_valid),
  .p_rd_valid(p_rd_valid),
  .boot_rd_ready(boot_rd_ready),
  .app_rd_ready(app_rd_ready),
  .p_rd_ready(p_rd_ready),
  .boot_rd_addr(boot_rd_addr),
  .app_rd_addr(app_rd_addr),
  .p_rd_addr(p_rd_addr),
  .boot_rd_beats(boot_rd_beats),
  .app_rd_beats(app_rd_beats),
  .p_rd_beats(p_rd_beats),
  .boot_rd_token(boot_rd_token),
  .app_rd_token(app_rd_token),
  .p_rd_token(p_rd_token),
  .boot_rd_owner(boot_rd_owner),
  .app_rd_owner(app_rd_owner),
  .p_rd_owner(p_rd_owner),
  .boot_r_valid(boot_r_valid),
  .app_r_valid(app_r_valid),
  .p_r_valid(p_r_valid),
  .boot_r_ready(boot_r_ready),
  .app_r_ready(app_r_ready),
  .p_r_ready(p_r_ready),
  .boot_r_data(boot_r_data),
  .app_r_data(app_r_data),
  .p_r_data(p_r_data),
  .boot_r_token(boot_r_token),
  .app_r_token(app_r_token),
  .p_r_token(p_r_token),
  .boot_r_index(boot_r_index),
  .app_r_index(app_r_index),
  .p_r_index(p_r_index),
  .boot_r_last(boot_r_last),
  .app_r_last(app_r_last),
  .p_r_last(p_r_last),
  .boot_r_error(boot_r_error),
  .app_r_error(app_r_error),
  .p_r_error(p_r_error),
  .boot_wr_valid(boot_wr_valid),
  .app_wr_valid(app_wr_valid),
  .p_wr_valid(p_wr_valid),
  .boot_wr_ready(boot_wr_ready),
  .app_wr_ready(app_wr_ready),
  .p_wr_ready(p_wr_ready),
  .boot_wr_addr(boot_wr_addr),
  .app_wr_addr(app_wr_addr),
  .p_wr_addr(p_wr_addr),
  .boot_wr_beats(boot_wr_beats),
  .app_wr_beats(app_wr_beats),
  .p_wr_beats(p_wr_beats),
  .boot_wr_token(boot_wr_token),
  .app_wr_token(app_wr_token),
  .p_wr_token(p_wr_token),
  .boot_wr_owner(boot_wr_owner),
  .app_wr_owner(app_wr_owner),
  .p_wr_owner(p_wr_owner),
  .boot_w_valid(boot_w_valid),
  .app_w_valid(app_w_valid),
  .p_w_valid(p_w_valid),
  .boot_w_ready(boot_w_ready),
  .app_w_ready(app_w_ready),
  .p_w_ready(p_w_ready),
  .boot_w_data(boot_w_data),
  .app_w_data(app_w_data),
  .p_w_data(p_w_data),
  .boot_w_strb(boot_w_strb),
  .app_w_strb(app_w_strb),
  .p_w_strb(p_w_strb),
  .boot_w_last(boot_w_last),
  .app_w_last(app_w_last),
  .p_w_last(p_w_last),
  .boot_b_valid(boot_b_valid),
  .app_b_valid(app_b_valid),
  .p_b_valid(p_b_valid),
  .boot_b_ready(boot_b_ready),
  .app_b_ready(app_b_ready),
  .p_b_ready(p_b_ready),
  .boot_b_token(boot_b_token),
  .app_b_token(app_b_token),
  .p_b_token(p_b_token),
  .boot_b_error(boot_b_error),
  .app_b_error(app_b_error),
  .p_b_error(p_b_error));
endmodule
