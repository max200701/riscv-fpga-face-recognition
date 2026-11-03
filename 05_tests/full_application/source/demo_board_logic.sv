// CPU/UI/NPU derived clocks, original CPU and actual graph, one physical writer.
module demo_board_logic #(parameter NATIVE=1,BAUD=921600)(
`ifdef PM_SIM_OBSERVER
 output wire[31:0]audit_base,audit_index,output wire[4:0]audit_state,
 output wire audit_done,audit_model_verified,audit_gallery_verified,
 output wire audit_capture_commit,output wire[31:0]audit_capture_generation,audit_capture_base,
`endif
 input wire video_pclk,video_prst,video_pixel_lock,video_vs,video_de,input wire[23:0]video_rgb,
 input wire video_rx_configured,video_rx_candidate,video_rx_fault,
 input wire[7:0]video_rx_fault_code,input wire[31:0]video_rx_raw_status,
 input wire clk_cpu,clk_ui,clk_mgmt,rst,uart_rx,output wire uart_tx,
 input wire ddr_init_done,safety_ready,input wire[63:0]temperature,
 input wire[31:0]physical_flags,output wire led0,
 output wire fault,finished,output wire[31:0]cpu_status,cpu_pc,cpu_phase,
 output wire[31:0]command_index,mark_kind,mark_a,mark_b,mark_c,output wire mark_toggle,
 output wire[63:0]cpu_cycles,npu_macs,vector_elements,
 output wire  axi_arvalid,
 input wire  axi_arready,
 output wire [27:0] axi_araddr,
 output wire [3:0] axi_arlen,
 output wire [3:0] axi_aruser_id,
 output wire  axi_aruser_ap,
 input wire  axi_rvalid,
 input wire [255:0] axi_rdata,
 input wire [3:0] axi_rid,
 input wire  axi_rlast,
 output wire  axi_awvalid,
 input wire  axi_awready,
 output wire [27:0] axi_awaddr,
 output wire [3:0] axi_awlen,
 output wire [3:0] axi_awuser_id,
 output wire  axi_awuser_ap,
 output wire [255:0] axi_wdata,
 output wire [31:0] axi_wstrb,
 input wire  axi_wready,
 input wire [3:0] axi_wusero_id,
 input wire  axi_wusero_last);
`ifdef PM_SIM_OBSERVER
 // Native vendor RAM model resolves this global even when GRS_EN is FALSE.
 GTP_GRS GRS_INST(.GRS_N(1'b1));
`endif

 wire  app_rd_valid;
 wire  app_rd_ready;
 wire [31:0] app_rd_addr;
 wire [6:0] app_rd_beats;
 wire [63:0] app_rd_token;
 wire [2:0] app_rd_owner;
 wire  app_r_valid;
 wire  app_r_ready;
 wire [255:0] app_r_data;
 wire [63:0] app_r_token;
 wire [6:0] app_r_index;
 wire  app_r_last;
 wire  app_r_error;
 wire  app_wr_valid;
 wire  app_wr_ready;
 wire [31:0] app_wr_addr;
 wire [6:0] app_wr_beats;
 wire [63:0] app_wr_token;
 wire [2:0] app_wr_owner;
 wire  app_w_valid;
 wire  app_w_ready;
 wire [255:0] app_w_data;
 wire [31:0] app_w_strb;
 wire  app_w_last;
 wire  app_b_valid;
 wire  app_b_ready;
 wire [63:0] app_b_token;
 wire  app_b_error;
`ifdef PM_SIM_OBSERVER
 assign audit_base=core.dma_fetch.sequencer.base;
 assign audit_index=core.dma_fetch.sequencer.index;
 assign audit_state=core.dma_fetch.sequencer.state;
 assign audit_done=core.dma_fetch.sequencer.done;
 assign audit_model_verified=model_verified;
 assign audit_gallery_verified=gallery_verified;
 assign audit_capture_commit=transport.capture_frame_ready&&!transport.video_session.transfer_pending;
 assign audit_capture_generation=transport.video_held_generation;
 assign audit_capture_base=transport.capture_base;
`endif
 wire[1:0] application_mode;wire[31:0] benchmark_iterations;
 wire hold_app,done,start_pulse,transport_fault,core_fault,client_fault,client_drained,result_fault;
 wire[7:0]fault_code;wire[2:0]phase;wire[31:0]accepted_writes,rejected_packets,verified_writes,verify_retries;
 wire[63:0]physical_read_bytes,physical_write_bytes,verify_read_bytes;
 wire[511:0]status_words,result_words;wire[5:0]result_page;wire result_ready,result_committed,result_has_face;
 wire core_finished;wire[31:0]core_status,core_pc;wire[63:0]core_cycles;
 wire[128:0]cpu_snapshot;wire cpu_snapshot_valid;
 wire app_reset=rst||hold_app;
 wire hold_next,mailbox_reset,result_reset;
 demo_hold_root status_hold_root(.clk(clk_ui),.cold_rst(rst),.hold_next(hold_next),.reset(mailbox_reset));
 demo_hold_root result_hold_root(.clk(clk_ui),.cold_rst(rst),.hold_next(hold_next),.reset(result_reset));
 wire model_verified,gallery_verified;
 wire gallery_qualify=!hold_app&&mark_toggle!=model_mark_seen&&mark_kind==32'h201&&mark_a==32'hfffffff4&&mark_b==32'h50474c31;
 reg model_mark_seen;
 always @(posedge clk_ui)if(rst)model_mark_seen<=0;else model_mark_seen<=mark_toggle;
 wire model_qualify=!hold_app&&mark_toggle!=model_mark_seen&&mark_kind==32'h201&&
  mark_a==32'hfffffff6&&mark_b==32'h50454d31;
 demo_status_cdc #(.W(129)) cpu_mailbox(.s_clk(clk_cpu),.d_clk(clk_ui),.arst(mailbox_reset),
  .s_data({core_cycles,core_pc,core_status,core_finished}),.d_data(cpu_snapshot),.d_valid(cpu_snapshot_valid));
 assign cpu_cycles=cpu_snapshot[128:65];assign cpu_pc=cpu_snapshot[64:33];assign cpu_status=cpu_snapshot[32:1];
 wire cpu_done=cpu_snapshot_valid&&cpu_snapshot[0];
 assign fault=transport_fault||core_fault||client_fault||result_fault||(cpu_done&&cpu_status!=1);
 assign finished=done||fault;
 // All application logic resets together; physical DDR and boot link keep running.
 // Related clocks are timed, not hidden by asynchronous clock exceptions.
 wire c_arvalid,c_arready,c_rvalid,c_rlast,c_awvalid,c_awready,c_wready,c_wlast,c_arap,c_awap;
 wire[27:0]c_araddr,c_awaddr;wire[3:0]c_arlen,c_awlen,c_arid,c_awid,c_rid,c_wid;
 wire[255:0]c_rdata,c_wdata;wire[31:0]c_wstrb;
 fullgraph_core #(.NATIVE(NATIVE),.FAST_CONTROL(1),.DMA_FETCH(1),.LOCAL_APPLICATION_HOLD(1)) core(
  .application_cold_rst(rst),.application_hold_next(hold_next),
  .application_mode(application_mode),.benchmark_iterations(benchmark_iterations),
  .resident_model_verified(model_verified),.resident_gallery_verified(gallery_verified),
  .uart_rx(1'b1),.uart_tx(),.gpio(),.arst(app_reset),.cpu_clk(clk_cpu),.npu_clk(clk_ui),.ddr_clk(clk_ui),.ddr_init_done(ddr_init_done),
  .axi_arvalid(c_arvalid),.axi_arready(c_arready),.axi_araddr(c_araddr),.axi_arlen(c_arlen),.axi_aruser_id(c_arid),.axi_aruser_ap(c_arap),
  .axi_rvalid(c_rvalid),.axi_rdata(c_rdata),.axi_rlast(c_rlast),.axi_rid(c_rid),
  .axi_awvalid(c_awvalid),.axi_awready(c_awready),.axi_awaddr(c_awaddr),.axi_awlen(c_awlen),.axi_awuser_id(c_awid),.axi_awuser_ap(c_awap),
  .axi_wdata(c_wdata),.axi_wstrb(c_wstrb),.axi_wready(c_wready),.axi_wusero_id(c_wid),.axi_wusero_last(c_wlast),
  .fault(core_fault),.npu_macs(npu_macs),.vector_elements(vector_elements),.finished(core_finished),.cpu_status(core_status),.cpu_pc(core_pc),.cpu_phase(cpu_phase),
  .command_index(command_index),.mark_kind(mark_kind),.mark_a(mark_a),.mark_b(mark_b),.mark_c(mark_c),.mark_toggle(mark_toggle),.cpu_cycles(core_cycles));
 demo_hmic_client client(.clk(clk_ui),.rst(rst),.enabled(!hold_app),.fault(client_fault),.drained(client_drained),
  .c_arvalid(c_arvalid),.c_arready(c_arready),.c_araddr(c_araddr),.c_arlen(c_arlen),.c_arid(c_arid),.c_rvalid(c_rvalid),.c_rdata(c_rdata),.c_rid(c_rid),.c_rlast(c_rlast),
  .c_awvalid(c_awvalid),.c_awready(c_awready),.c_awaddr(c_awaddr),.c_awlen(c_awlen),.c_awid(c_awid),.c_wdata(c_wdata),.c_wstrb(c_wstrb),.c_wready(c_wready),.c_wid(c_wid),.c_wlast(c_wlast),
  .app_rd_valid(app_rd_valid),
  .app_rd_ready(app_rd_ready),
  .app_rd_addr(app_rd_addr),
  .app_rd_beats(app_rd_beats),
  .app_rd_token(app_rd_token),
  .app_rd_owner(app_rd_owner),
  .app_r_valid(app_r_valid),
  .app_r_ready(app_r_ready),
  .app_r_data(app_r_data),
  .app_r_token(app_r_token),
  .app_r_index(app_r_index),
  .app_r_last(app_r_last),
  .app_r_error(app_r_error),
  .app_wr_valid(app_wr_valid),
  .app_wr_ready(app_wr_ready),
  .app_wr_addr(app_wr_addr),
  .app_wr_beats(app_wr_beats),
  .app_wr_token(app_wr_token),
  .app_wr_owner(app_wr_owner),
  .app_w_valid(app_w_valid),
  .app_w_ready(app_w_ready),
  .app_w_data(app_w_data),
  .app_w_strb(app_w_strb),
  .app_w_last(app_w_last),
  .app_b_valid(app_b_valid),
  .app_b_ready(app_b_ready),
  .app_b_token(app_b_token),
  .app_b_error(app_b_error));
 demo_result_store results(.application_mode(application_mode),.clk(clk_ui),.rst(result_reset),.mark_toggle(mark_toggle),.mark_kind(mark_kind),.mark_a(mark_a),.mark_b(mark_b),
  .page(result_page),.words(result_words),.ready(result_ready),.committed(result_committed),.fault(result_fault),.has_face(result_has_face));
 reg[63:0]ticks;always @(posedge clk_ui)if(rst)ticks<=0;else ticks<=ticks+1'b1;
 assign led0=fault?1'b0:~ticks[26];
 assign status_words[0*32+:32]=32'h31444246;
 assign status_words[1*32+:32]=1;
 assign status_words[2*32+:32]=32'h26102420;
 assign status_words[3*32+:32]={20'b0,result_committed,done,fault,safety_ready,hold_app,ddr_init_done,3'b0,phase};
 assign status_words[4*32+:32]=31250000;
 assign status_words[5*32+:32]=125000000;
 assign status_words[6*32+:32]=125000000;
 assign status_words[7*32+:32]={20'b0,temperature[43:32]};
 assign status_words[8*32+:32]={27'b0,temperature[48:44]};
 assign status_words[9*32+:32]=cpu_status;
 assign status_words[10*32+:32]=cpu_phase;
 assign status_words[11*32+:32]=command_index;
 assign status_words[12*32+:32]=physical_read_bytes[31:0];
 assign status_words[13*32+:32]=physical_write_bytes[31:0];
 assign status_words[14*32+:32]=physical_flags;
 assign status_words[15*32+:32]={20'b0,result_fault,client_fault,core_fault,transport_fault,fault_code};
 demo_uart_memory_top #(.CLOCK_HZ(125000000),.BAUD(BAUD)) transport(
 .video_pclk(video_pclk),.video_prst(video_prst),.video_pixel_lock(video_pixel_lock),.video_vs(video_vs),.video_de(video_de),.video_rgb(video_rgb),
 .video_rx_configured(video_rx_configured),.video_rx_candidate(video_rx_candidate),.video_rx_fault(video_rx_fault),.video_rx_fault_code(video_rx_fault_code),.video_rx_raw_status(video_rx_raw_status),

  .clk(clk_ui),.mgmt_clk(clk_mgmt),.rst(rst),.uart_rx_pin(uart_rx),.uart_tx_pin(uart_tx),.ddr_init_done(ddr_init_done),.controller_quiescent(1'b1),.safety_ready(safety_ready),
  .application_done(cpu_done&&cpu_status==1&&result_committed),.application_drained(client_drained&&!c_arvalid&&!c_awvalid),.application_fault(core_fault||client_fault||result_fault||(cpu_done&&cpu_status!=1)),
  .model_qualify(model_qualify),.model_verified(model_verified),
  .gallery_qualify(gallery_qualify),.gallery_verified(gallery_verified),
  .application_mode(application_mode),.benchmark_iterations(benchmark_iterations),
  .application_hold(hold_app),.application_hold_next(hold_next),.done(done),.phase(phase),.status_words(status_words),.result_words(result_words),.result_ready(result_ready&&done&&!fault),.result_has_face(result_has_face),.result_page(result_page),.start_pulse(start_pulse),
  .fault(transport_fault),.fault_code(fault_code),.accepted_writes(accepted_writes),.rejected_packets(rejected_packets),
  .physical_read_bytes(physical_read_bytes),.physical_write_bytes(physical_write_bytes),.verify_read_bytes(verify_read_bytes),.verified_writes(verified_writes),.verify_retries(verify_retries),
  .app_rd_valid(app_rd_valid),
  .app_rd_ready(app_rd_ready),
  .app_rd_addr(app_rd_addr),
  .app_rd_beats(app_rd_beats),
  .app_rd_token(app_rd_token),
  .app_rd_owner(app_rd_owner),
  .app_r_valid(app_r_valid),
  .app_r_ready(app_r_ready),
  .app_r_data(app_r_data),
  .app_r_token(app_r_token),
  .app_r_index(app_r_index),
  .app_r_last(app_r_last),
  .app_r_error(app_r_error),
  .app_wr_valid(app_wr_valid),
  .app_wr_ready(app_wr_ready),
  .app_wr_addr(app_wr_addr),
  .app_wr_beats(app_wr_beats),
  .app_wr_token(app_wr_token),
  .app_wr_owner(app_wr_owner),
  .app_w_valid(app_w_valid),
  .app_w_ready(app_w_ready),
  .app_w_data(app_w_data),
  .app_w_strb(app_w_strb),
  .app_w_last(app_w_last),
  .app_b_valid(app_b_valid),
  .app_b_ready(app_b_ready),
  .app_b_token(app_b_token),
  .app_b_error(app_b_error),
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
  .axi_wusero_last(axi_wusero_last));
endmodule
