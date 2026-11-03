// Reuse loaded A/B panels across multiple 32x32 output tiles. Independent
// loader, compute, snapshot drain and elastic quantization. Output is tile-major
// INT8, 16B per handshake; addresses are byte offsets supplied by the caller.
// cmd_done means arithmetic/capture complete, NOT external memory visibility.
// Segment continuation preserves a whole macro-panel in INT32 block RAM;
// same shape/dest/quantization, in order, with total K <= 65535.
// the array accumulates in exact 24-bit lanes, so every array dot is
// at most CHUNK=511 K-steps; a longer K runs as consecutive chunks of the same tile
// (first chunk keeps the RUN's first flag, last chunk its last flag) and the INT32
// partial-sum store adds them exactly. Bit-identical to one 32-bit accumulation.
// the drain reads one 4-lane phase per handshake (wide modes: valid phases
// only; INT8: all four, as the quantizer reassembles 16-byte beats); FIFO, partial sums
// and the quantizer feed carry one phase. Same quantizer input sequence as before.
module panel_compute #(parameter AW=12, PANGO_SIMD=1, ROW_GROUPS=4)(
 input wire clk,rst,
 input wire load_start,load_bank,load_pair,load_hmode,load_half,input wire[AW-1:0]load_index,input wire[AW:0]load_a_words,load_b_words,
 output wire load_start_ready,input wire load_valid,input wire[255:0]load_data,load_high_data,
 output wire load_ready,output wire load_done,
 input wire release_valid,release_bank,release_hmode,release_half,output wire release_ready,
 output wire[1:0]bank_ready,
 input wire cmd_valid,cmd_bank,cmd_hmode,cmd_half,cmd_first,cmd_last,cmd_wide,cmd_shift8,cmd_q16,
 input wire[15:0]cmd_k,input wire[3:0]cmd_mtiles,cmd_ntiles,
 input wire[31:0]cmd_dest,output wire cmd_ready,output reg cmd_done,
 output reg[3:0]error,
 input wire param_valid,input wire[7:0]param_index,
 input wire signed[31:0]param_bias,input wire[31:0]param_multiplier,input wire signed[31:0]param_post_bias,
 input wire[5:0]param_shift,output wire param_ready,
 input wire signed[7:0]zero_point,clamp_min,clamp_max,
 // LAYOUT valid M/N of the macro-panel; all-padding vectors/phases are skipped.
 input wire[8:0]cfg_m,cfg_n,
 output wire out_valid,input wire out_ready,
 output wire[127:0]out_data,output wire[31:0]out_addr,
 output reg[63:0]cycles,mac_cycles,input_wait_cycles,result_wait_cycles,
 output reg[63:0]input_words,output_bytes,tiles,overlap_cycles,
 output wire outputs_idle
);
 localparam ROWS=ROW_GROUPS*8,TILE_BYTES=ROWS*32,VECTORS=ROWS*2;
 localparam IDLE=0,VALIDATE=1,SLOT=2,START=3,RUN=4,WAIT_RESULT=5,SEGMENT_WAIT=6,PREP=7;
 localparam[12:0]CHUNK=13'd511;
 reg[2:0]state;reg bank,hmode,half,first,last;reg[15:0]k;
 wire[3:0]vbank_ready;
 reg[3:0]mt,nt,mi,ni;reg[AW-1:0]abase,bbase;
 reg[19:0]need_a,need_b;reg[31:0]dest;reg[18:0]output_span;
 reg wide_q,shift8_q,partial_wide,model_q,partial_model;
 reg partial;reg[16:0]partial_k;reg[31:0]partial_dest,job_dest;
 reg[3:0]partial_mt,partial_nt;
 reg[12:0]tile_vector_base;
 reg[31:0]scheduled_vectors,committed_vectors;
 reg[3:0]settle;
 reg[12:0]kc;   // K-steps of the current tile already accumulated (chunk offset)
 wire[12:0]k_left=k[12:0]-kc;
 wire[12:0]chunk_k=k_left>CHUNK?CHUNK:k_left;
 wire last_chunk=k_left<=CHUNK;
 reg[3:0]nchunks;integer cj;
 always @*begin nchunks=1;for(cj=1;cj<9;cj=cj+1)if(k>cj*511)nchunks=cj+1;end
 reg[1:0]snap_full;reg cap_bank,cap_turn,drain_bank;
 // Both column halves are computed from the same resident panel. The first
 // half is never published, released or reloaded while the second owns it.
 reg capture_half;
 // OV: only replay the second physical half when a valid consumer exists.
 reg capture_second;
 wire store_release_ready;
 assign release_ready=store_release_ready&&(state==IDLE);
 reg[31:0]snap_dest[0:1];reg[3:0]snap_n[0:1];
 reg[12:0]snap_index[0:1];reg snap_first[0:1],snap_last[0:1];
 reg[5:0]snap_vm[0:1],snap_vn[0:1];reg[7:0]snap_end[0:1];
 // Valid rows/columns of the tile being captured (mi, ni) and of the whole panel.
 wire[9:0]tile_m_left={1'b0,cfg_m}-{1'b0,mi,5'b0},tile_n_left={1'b0,cfg_n}-{1'b0,ni,5'b0};
 wire[5:0]tile_vm=tile_m_left>32?6'd32:tile_m_left[5:0],tile_vn=tile_n_left>32?6'd32:tile_n_left[5:0];
 // Last drained entry of the tile: last row, last half, last phase of that half.
 wire[5:0]tile_last_cols_m1=(tile_vn>16?tile_vn-6'd16:tile_vn)-1'b1;
 wire[1:0]tile_last_ph=wide_q?tile_last_cols_m1[3:2]:2'd3;
 wire[9:0]last_n={1'b0,cfg_n}-{1'b0,nt-1'b1,5'b0};
 wire[4:0]panel_halves={nt-1'b1,1'b0}+(last_n>16?5'd2:5'd1);
 wire[6:0]panel_groups=({1'b0,cfg_n}+10'd3)>>2;
 // Explicit widths: a product inside a concatenation is only as wide as its operands.
 wire[15:0]panel_beats=cfg_m*panel_groups,panel_vectors=cfg_m*panel_halves;
 // c15: partial-sum entries (phases) per K chunk: wide = valid phases, INT8 = four per vector.
 wire[17:0]panel_entries=wide_q?{2'b0,panel_beats}:{panel_vectors,2'b0};
 wire[21:0]chunk_entries=panel_entries*nchunks;   // explicit width (K chunks)
 // registered products, valid in VALIDATE after two PREP cycles.
 reg[15:0]panel_beats_q,panel_vectors_q;reg[3:0]nchunks_q;reg[21:0]chunk_entries_q;reg prep2;
 always @(posedge clk)begin
  panel_beats_q<=panel_beats;panel_vectors_q<=panel_vectors;nchunks_q<=nchunks;
  chunk_entries_q<=(wide_q?{2'b0,panel_beats_q}:{panel_vectors_q,2'b0})*nchunks_q;
 end
 reg[8:0]rd_count;   // {row[5:0],half,phase[1:0]}
 reg signed[7:0]zp_q,lo_q,hi_q;
 wire sv,sf,sl,scmdready,srun_done;wire[ROWS*8-1:0]a;wire[255:0]b;
 wire[1:0]store_error;
 // PD01: select the physical B half before the relay; local MAC capture sees no half mux.
 reg [ROWS*8-1:0] relay_a /* synthesis syn_preserve=1 */;
 reg [127:0] relay_b /* synthesis syn_preserve=1 */;
 reg relay_valid,relay_first,relay_last;
 always @(posedge clk)begin
  relay_a<=a;relay_b<=capture_half?b[255:128]:b[127:0];relay_first<=sf;relay_last<=sl;
  if(rst)relay_valid<=0;else relay_valid<=sv&&(state==RUN);
 end
 wire step=relay_valid&&(state==RUN);
 // synthesis translate_off
 reg relay_half_tag;
 always @(posedge clk)begin
  relay_half_tag<=capture_half;
  if(!rst&&relay_valid&&(state==RUN)&&(relay_half_tag!==capture_half))
   $fatal(1,"PD_HALF_CHANGED_WHILE_VALID_RELAY_OWNED");
 end
 always @(posedge clk)if(!rst&&relay_valid&&(state!=RUN))
  $fatal(1,"PC_RELAY_VALID_OUTSIDE_OWNED_RUN");
 // synthesis translate_on
 paired_operand_store #(.AW(AW),.ROW_BYTES(ROWS)) store(
  .clk(clk),.rst(rst),.load_start(load_start),.load_bank(load_bank),.load_hmode(load_hmode),.load_half(load_half),
  .load_pair(load_pair),.load_high_data(load_high_data),.load_scatter(1'b1),.load_index(load_index),.load_a_words(load_a_words),.load_b_words(load_b_words),.load_start_ready(load_start_ready),
  .load_valid(load_valid),.load_data(load_data),.load_ready(load_ready),.load_done(load_done),
  .cmd_valid(state==START),.cmd_bank(bank),.cmd_hmode(hmode),.cmd_half(half),.cmd_a_base(abase+kc[AW-1:0]),.cmd_b_base(bbase+kc[AW-1:0]),
  .cmd_steps(chunk_k[AW:0]),.cmd_ready(scmdready),.run_done(srun_done),
  .release_valid(release_valid&&(state==IDLE)),.release_bank(release_bank),.release_hmode(release_hmode),.release_half(release_half),.release_ready(store_release_ready),
  .bank_ready(bank_ready),.vbank_ready(vbank_ready),.out_valid(sv),.out_ready(state==RUN),
  .out_a(a),.out_b(b),.out_first(sf),.out_last(sl),.error(store_error));
 wire array_done,rv;wire[95:0]raw;wire[7:0]ridx;
 wire[5:0]fifo_used;wire fifo_wr_ready,fv,fr;wire[148:0]fq;
 // Reserve space for the extra local-address read pipeline stage.
 wire drain_two=snap_vn[drain_bank]>16;
 wire read_issue=snap_full[drain_bank]&&(rd_count[8:3]<snap_vm[drain_bank])&&(fifo_used<27);
 // Phases (4-channel groups) of the vector being read: half 0 covers columns 0..15.
 wire[5:0]half_cols=rd_count[2]?snap_vn[drain_bank]-6'd16:(snap_vn[drain_bank]>16?6'd16:snap_vn[drain_bank]);
 wire[5:0]half_cols_m1=half_cols-1'b1;
 wire[1:0]rd_last_ph=wide_q?half_cols_m1[3:2]:2'd3;
 wire[8:0]rd_next=(rd_count[1:0]!=rd_last_ph)?rd_count+1'b1:
  (!rd_count[2]&&drain_two)?{rd_count[8:3],1'b1,2'b00}:{rd_count[8:3]+1'b1,1'b0,2'b00};
 mac_array_fold16 #(.ROW_GROUPS(ROW_GROUPS),.PANGO_SIMD(PANGO_SIMD)) array(
  .clk(clk),.rst(rst),.in_valid(step),.in_first(relay_first),.in_last(relay_last),
  .capture_bank(cap_bank),.capture_half(capture_half), .rows(relay_a),.columns({relay_b,relay_b}),.done(array_done),
  .rd_valid(read_issue),.rd_bank(drain_bank),.rd_index(rd_count[7:0]),
  .result_valid(rv),.result(raw),.result_index(ridx));
 reg[31:0]dst_pipe[0:3];reg[3:0]n_pipe[0:3];reg[3:0]bank_pipe;
 reg[12:0]index_pipe[0:3];reg[3:0]first_pipe,last_pipe;
 wire[31:0]result_address=dst_pipe[3]+{22'b0,ridx[7:2],4'b0};   // 16-byte vector address
 wire[12:0]result_vector=index_pipe[3]+{7'b0,ridx[7:2]};
 // Four high bits carry N-panel index; low address bit4 selects column half.
 // FIFO word: {first,last,entry{vector,phase},n,address,4 x 24-bit lanes}
 async_stream_fifo #(.WIDTH(149),.LGDEPTH(5)) result_fifo(
  rst,clk,rv,fifo_wr_ready,{first_pipe[3],last_pipe[3],result_vector,ridx[1:0],n_pipe[3],result_address,raw},fifo_used,
  clk,fv,fr,fq);
 wire pv,pr,pcommit;wire[127:0]praw;wire[37:0]pmeta;
 wire ps_valid,ps_ready;wire[127:0]ps_data;wire[37:0]ps_meta;
 // Two register slots isolate partial-sum RAM enables from remote tail ready.
 // Input ready depends only on registered occupancy. Output acceptance and
 // expected_output still govern command/parameter lifetime, not this buffer.
 pf_elastic2 #(.WIDTH(166)) partial_boundary(.clk(clk),.rst(rst),
  .in_valid(ps_valid),.in_ready(ps_ready),.in_data({ps_meta,ps_data}),
  .out_valid(pv),.out_ready(pr),.out_data({pmeta,praw}));
 // INT12 x INT8 uses two passes: signed low-byte + (signed high-byte << 8).
 // Shift only the new segment, before adding it to the preserved partial sum.
 wire[127:0]segment_raw;
 genvar seglane;
 generate for(seglane=0;seglane<4;seglane=seglane+1)begin:segment_precision
  assign segment_raw[seglane*32+:32]=shift8_q ?
   {fq[seglane*24+:24],8'b0}:{{8{fq[seglane*24+23]}},fq[seglane*24+:24]};
 end endgenerate
 partial_sum_store #(.DEPTH(VECTORS*64*4),.IW(15),.LANES(4),.META_W(38)) partial_sums(
  .clk(clk),.rst(rst),.in_valid(fv),.in_ready(fr),.in_first(fq[148]),.in_last(fq[147]),
  .in_index(fq[146:132]),.in_data(segment_raw),.in_meta({fq[133:132],fq[131:96]}),
  .out_valid(ps_valid),.out_ready(ps_ready),.out_data(ps_data),.out_meta(ps_meta),.commit(pcommit));
 // Parameter storage lives in explicit interleaved banks below.
 reg[255:0]parameter_set;
 wire[127:0]q_bias,q_mul,q_post_bias;wire[23:0]q_shift;
 wire[7:0]q_base={pmeta[34:32],pmeta[4],4'b0};
 // pmeta = {phase[1:0], N index[3:0], 16-byte vector address[31:0]} (c15).
 model_param_store4 parameters(.clk(clk),.rst(rst),.write_valid(param_valid&&param_ready),
  .write_index(param_index),.write_bias(param_bias),.write_mul(param_multiplier),
  .write_post_bias(param_post_bias),.write_shift(param_shift),.read_group({q_base[7:4],pmeta[37:36]}),
  .bias(q_bias),.mul(q_mul),.post_bias(q_post_bias),.shift(q_shift));
 // /c15: one 4-channel phase per handshake (the drain already skipped the
 // invalid phases of wide outputs), through a 4-lane quant.
 wire[1:0]ph=pmeta[37:36];
 wire use_quant=!wide_q||model_q;
 wire[31:0]vaddr={pmeta[31:4],4'b0};
 wire[31:0]phase_waddr=job_dest+((vaddr-job_dest)<<2)+{26'b0,ph,4'b0};
 wire qready,qvalid,qerror;wire[31:0]qdata4,qmeta;wire[127:0]qwide4;
 wire q_take=pv&&use_quant&&qready;
 wire raw_phase=pv&&wide_q&&!model_q;
 wire raw_take=raw_phase&&out_ready;
 wire phase_take=q_take||raw_take;
 assign pr=phase_take;
 // INT8 re-assembly (four phases -> one 16-byte beat)
 reg[95:0]i8_acc;reg i8_valid;reg[127:0]i8_data;reg[31:0]i8_addr;
 wire i8_ready=!i8_valid||out_ready;
 assign out_valid=wide_q?(model_q?qvalid:raw_phase):i8_valid;
 assign out_data=wide_q?(model_q?qwide4:praw):i8_data;
 assign out_addr=wide_q?(model_q?qmeta:phase_waddr):i8_addr;
 always @(posedge clk)begin
  if(rst)begin i8_valid<=0;i8_acc<=0;i8_data<=0;i8_addr<=0;end
  else begin
   if(i8_valid&&out_ready)i8_valid<=0;
   if(!wide_q&&qvalid&&i8_ready)begin
    if(qmeta[1:0]==3)begin i8_valid<=1;i8_data<={qdata4,i8_acc};i8_addr<={qmeta[31:4],4'b0};end
    else i8_acc[qmeta[1:0]*32+:32]<=qdata4;
   end
  end
 end
 quant_stream_lanes #(.LANES(4)) quant(.clk(clk),.rst(rst),.in_valid(pv&&use_quant),.in_ready(qready),
  .accum(praw),.bias(q_bias),.multiplier(q_mul),.shift(q_shift),.model_q16(model_q),.post_bias(q_post_bias),
  .zero_point(zp_q),.clamp_min(lo_q),.clamp_max(hi_q),.in_meta(wide_q?phase_waddr:{vaddr[31:4],2'b0,ph}),
  .out_valid(qvalid),.out_ready(wide_q?out_ready:i8_ready),.out_data(qdata4),.out_meta(qmeta),.out_wide(qwide4),.out_error(qerror));
 // Keep all parameters immutable while a job, partial dot or output owns them.
 reg[31:0]expected_output,accepted_output;
 reg[6:0]validation_bad;
 // PG: compare four local bytes, then qualify only an unchanged counter snapshot.
 // Dirty inhibits the registered old comparison on EVERY count update. This
 // delays completion by at most one edge; it can never authorize early reuse.
 reg[3:0]output_equal_bytes,vector_equal_bytes;
 reg output_compare_dirty,vector_compare_dirty;
 wire output_equal=(&output_equal_bytes)&&!output_compare_dirty;
 wire vector_equal=(&vector_equal_bytes)&&!vector_compare_dirty;
 wire admit_counts=state==VALIDATE&&store_error==0&&!(|validation_bad);
 integer compare_byte;
 always @(posedge clk)begin
  if(rst)begin output_equal_bytes<=15;vector_equal_bytes<=15;output_compare_dirty<=0;vector_compare_dirty<=0;end
  else begin
   for(compare_byte=0;compare_byte<4;compare_byte=compare_byte+1)begin
    output_equal_bytes[compare_byte]<=expected_output[8*compare_byte+:8]==accepted_output[8*compare_byte+:8];
    vector_equal_bytes[compare_byte]<=scheduled_vectors[8*compare_byte+:8]==committed_vectors[8*compare_byte+:8];
   end
   output_compare_dirty<=(admit_counts&&last)||(out_valid&&out_ready);
   vector_compare_dirty<=admit_counts||pcommit;
  end
 end
 // PJ: old equality is never usable on an edge that changes either count.
 reg counts_idle_q,param_window_q;
 always @(posedge clk)begin
  if(rst)begin counts_idle_q<=0;param_window_q<=0;end
  else begin
   counts_idle_q<=output_equal&&vector_equal&&!admit_counts&&!pcommit&&!(out_valid&&out_ready);
   param_window_q<=(state==IDLE)&&!partial&&(snap_full==0)&&!fv&&!rv&&
      counts_idle_q&&!(cmd_valid&&cmd_ready);
  end
 end
 assign outputs_idle=counts_idle_q&&(snap_full==0)&&!rv&&!fv;
 assign cmd_ready=!rst&&(state==IDLE)&&counts_idle_q;
 assign param_ready=!rst&&param_window_q;
 // synthesis translate_off
 always @(posedge clk)if(!rst)begin
  if(param_valid&&param_ready&&((state!=IDLE)||partial||snap_full!=0||fv||rv||
     expected_output!=accepted_output||scheduled_vectors!=committed_vectors))
   $fatal(1,"PJ_PARAMETER_ACCEPT_BEFORE_QUIESCENT");
  if(outputs_idle&&(expected_output!=accepted_output||scheduled_vectors!=committed_vectors))
   $fatal(1,"PJ_EARLY_OUTPUT_IDLE");
 end
 // synthesis translate_on
 // QL: the existing two PREP edges already qualify these products. Use
 // captured command registers and no remote fault/EXEC enable on APM inputs.
 // PREP1 computes; PREP2 checks; VALIDATE consumes the same numeric values.
 always @(posedge clk)begin
  need_a<=k*mt;need_b<=k*nt;
  output_span<=mt*nt*TILE_BYTES*(wide_q?4:1);
 end
 reg all_params;integer ci,p;
 always @(posedge clk)if(state==PREP)begin
  validation_bad[0]<=(k==0||mt==0||mt>8||nt==0||nt>8||need_a>(1<<AW)||need_b>(1<<AW));
  validation_bad[1]<=(dest[4:0]!=0||({1'b0,dest}+{14'b0,output_span}>33'h040000000));
  validation_bad[2]<=(!(hmode?vbank_ready[{half,bank}]:bank_ready[bank])||(!first&&!partial)||(first&&partial));
  validation_bad[3]<=(partial&&(partial_dest!=dest||partial_k+{1'b0,k}>65535||partial_mt!=mt||partial_nt!=nt||partial_wide!=wide_q||partial_model!=model_q));
  validation_bad[4]<=((model_q&&!wide_q)||!all_params||$signed(clamp_min)>$signed(clamp_max));
  validation_bad[5]<=(cfg_m==0||cfg_n==0||((cfg_m+9'd31)>>5)!=mt||((cfg_n+9'd31)>>5)!=nt);
  validation_bad[6]<=((partial||expected_output!=accepted_output)&&(zero_point!=zp_q||clamp_min!=lo_q||clamp_max!=hi_q));
 end
 always @*begin
  all_params=1;
  for(ci=0;ci<256;ci=ci+1)if(ci<nt*32&&!parameter_set[ci])all_params=0;
 end
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;bank<=0;hmode<=0;half<=0;first<=0;last<=0;k<=0;mt<=0;nt<=0;mi<=0;ni<=0;abase<=0;bbase<=0;dest<=0;wide_q<=0;shift8_q<=0;partial_wide<=0;model_q<=0;partial_model<=0;
   partial<=0;partial_k<=0;partial_dest<=0;settle<=0;kc<=0;snap_full<=0;cap_bank<=0;cap_turn<=0;drain_bank<=0;rd_count<=0;capture_half<=0;capture_second<=0;
   job_dest<=0;partial_mt<=0;partial_nt<=0;tile_vector_base<=0;scheduled_vectors<=0;committed_vectors<=0;first_pipe<=0;last_pipe<=0;
   cmd_done<=0;error<=0;parameter_set<=0;zp_q<=0;lo_q<=-128;hi_q<=127;
   cycles<=0;mac_cycles<=0;input_wait_cycles<=0;result_wait_cycles<=0;input_words<=0;output_bytes<=0;tiles<=0;overlap_cycles<=0;
   expected_output<=0;accepted_output<=0;bank_pipe<=0;
   for(p=0;p<4;p=p+1)begin dst_pipe[p]<=0;n_pipe[p]<=0;index_pipe[p]<=0;end
   for(p=0;p<2;p=p+1)begin snap_dest[p]<=0;snap_n[p]<=0;snap_index[p]<=0;snap_first[p]<=0;snap_last[p]<=0;snap_vm[p]<=0;snap_vn[p]<=0;snap_end[p]<=0;end
  end else begin
   cmd_done<=0;error<=0;cycles<=cycles+1;
   if(step)mac_cycles<=mac_cycles+1;
   if(pcommit)committed_vectors<=committed_vectors+1;
   if(state==RUN&&!relay_valid)input_wait_cycles<=input_wait_cycles+1;
   if(state==SLOT&&snap_full[cap_turn])result_wait_cycles<=result_wait_cycles+1;
   if(step&&((load_valid&&load_ready)||(out_valid&&out_ready)))overlap_cycles<=overlap_cycles+1;
   if(load_valid&&load_ready)input_words<=input_words+1;
   if(out_valid&&out_ready)begin output_bytes<=output_bytes+16;accepted_output<=accepted_output+16;end
   if(param_valid&&param_ready)begin parameter_set[param_index]<=1;end
   if(qerror)error<=10;
   if(param_valid&&!param_ready)error<=7;
   dst_pipe[0]<=snap_dest[drain_bank];n_pipe[0]<=snap_n[drain_bank];bank_pipe<={bank_pipe[2:0],drain_bank};
   index_pipe[0]<=snap_index[drain_bank];first_pipe<={first_pipe[2:0],snap_first[drain_bank]};last_pipe<={last_pipe[2:0],snap_last[drain_bank]};
   for(p=1;p<4;p=p+1)begin dst_pipe[p]<=dst_pipe[p-1];n_pipe[p]<=n_pipe[p-1];index_pipe[p]<=index_pipe[p-1];end
   if(read_issue)rd_count<=rd_next;
   if(rv&&ridx==snap_end[bank_pipe[3]])begin snap_full[bank_pipe[3]]<=0;drain_bank<=!drain_bank;rd_count<=0;end
   if(rv&&!fifo_wr_ready)error<=8;
   if(store_error!=0)begin state<=IDLE;partial<=0;cmd_done<=1;error<=9;end
   else case(state)
    IDLE:if(cmd_valid&&cmd_ready)begin
     bank<=cmd_bank;hmode<=cmd_hmode;half<=cmd_half;first<=cmd_first;last<=cmd_last;k<=cmd_k;mt<=cmd_mtiles;nt<=cmd_ntiles;
     dest<=cmd_dest;
     wide_q<=cmd_wide;shift8_q<=cmd_shift8;model_q<=cmd_q16;
     job_dest<=cmd_dest;tile_vector_base<=0;
     mi<=0;ni<=0;abase<=0;bbase<=0;kc<=0;capture_half<=0;state<=PREP;prep2<=0;
    end
    PREP:begin
     if(prep2)state<=VALIDATE;else prep2<=1;
    end
    VALIDATE:begin
     if(|validation_bad)begin
      error<=1;cmd_done<=1;state<=IDLE;
     end else begin
      zp_q<=zero_point;lo_q<=clamp_min;hi_q<=clamp_max;partial_wide<=wide_q;partial_model<=model_q;
      if(last)expected_output<=expected_output+{12'b0,wide_q?panel_beats_q:panel_vectors_q,4'b0};
      scheduled_vectors<=scheduled_vectors+{10'b0,chunk_entries_q};   // c15: counts partial-sum entries (c21: registered)
      state<=SLOT;
     end
    end
    SLOT:if(!snap_full[cap_turn])begin cap_bank<=cap_turn;capture_second<=tile_vn>16;state<=START;end
    START:if(scmdready)state<=RUN;
    RUN:if(step&&relay_last)begin state<=WAIT_RESULT;settle<=0;end
    SEGMENT_WAIT:if(settle==7)begin
     partial<=1;partial_k<=first?{1'b0,k}:partial_k+k;partial_dest<=dest;cmd_done<=1;state<=IDLE;
    end else settle<=settle+1;
    WAIT_RESULT:if(array_done&&!capture_half&&capture_second)begin
     // RAM write/capture and this control transition share this edge; the
     // old half tag remains stable for the completed MAC pipeline.
     capture_half<=1;state<=START;
    end else if(array_done&&(capture_half||!capture_second))begin
     capture_half<=0;
     snap_full[cap_bank]<=1;snap_dest[cap_bank]<=dest;snap_n[cap_bank]<=ni;cap_turn<=!cap_turn;tiles<=tiles+1;
     snap_index[cap_bank]<=tile_vector_base;snap_first[cap_bank]<=first&&kc==0;snap_last[cap_bank]<=last&&last_chunk;
     snap_vm[cap_bank]<=tile_vm;snap_vn[cap_bank]<=tile_vn;snap_end[cap_bank]<={tile_vm[4:0]-1'b1,tile_vn>16,tile_last_ph};
     if(!last_chunk)begin kc<=kc+chunk_k;state<=SLOT;end   // next K chunk of the same tile
     else begin
     kc<=0;tile_vector_base<=tile_vector_base+VECTORS;
     if(ni+1<nt)begin ni<=ni+1;bbase<=bbase+k;dest<=dest+TILE_BYTES;state<=SLOT;end
     else if(mi+1<mt)begin mi<=mi+1;ni<=0;abase<=abase+k;bbase<=0;dest<=dest+TILE_BYTES;state<=SLOT;end
     else begin
      partial<=!last;partial_k<=last?0:first?{1'b0,k}:partial_k+k;
      partial_dest<=job_dest;partial_mt<=mt;partial_nt<=nt;cmd_done<=1;state<=IDLE;
     end
     end
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
