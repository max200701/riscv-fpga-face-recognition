// same ports, descriptor checks, NCHW values, signed-12 split,
// vector order/index/last, cache banks and error codes as the MR source.
// The 32-lane x 160-byte gather crossbars are replaced by row segments: lanes of
// one output row read an arithmetic byte sequence, so one 128-byte rotate of the
// four bank lines plus fixed decimation serves a whole segment ("pass").
// Pipeline: segment record -> pass -> 4-entry pass queue -> bank lookup ->
// rotate/decimate -> merge -> 8-entry output FIFO. A miss replays the pass from
// the queue after REQUEST/FILL; nothing after it has been merged. Output
// backpressure never stalls the datapath: a pass that completes a vector is
// issued only with a free FIFO credit.
// W2b: line validity is a generation stored with the tag (no 4x2^LG valid
// registers). Reset, and a clear that would wrap the generation, sweep every
// tag to generation 0 (never current) before the next lookup.
module conv_window_source #(parameter LG=9, PREFETCH=8, GW=8)(
 input wire clk,rst,start, input wire [31:0] cfg_base,cfg_epoch,
 input wire [15:0] cfg_h,cfg_w,cfg_c,cfg_oh,cfg_ow,cfg_y,cfg_x,
 input wire [8:0] cfg_m, input wire [3:0] cfg_kh,cfg_kw,
 input wire [1:0] cfg_sy,cfg_sx,input wire [3:0] cfg_py,cfg_px,
 input wire cfg_wide,cfg_high,cfg_cache,cfg_scatter,input wire signed[15:0] cfg_zero,
 output wire ready,output reg done,output reg[3:0] error,
 output wire rd_valid,input wire rd_ready,output wire[31:0] rd_addr,
 output wire[4:0] rd_beats,input wire r_valid,output wire r_ready,
 input wire[255:0] r_data,input wire r_last,r_error,
 output wire out_valid,input wire out_ready,output wire[255:0] out_data,
 output wire[12:0] out_index,output wire out_last,output wire[255:0]out_high_data,
 output reg[63:0] cycles,read_bytes,hits,misses,vectors,stall_cycles
);
 localparam IDLE=0,CHECK=1,CHECK2=8,CHECK3=9,CHECK4=10,CHECK_APPLY=2,SETUP1=3,SETUP2=4,RUN=5,REQUEST=6,FILL=7,MISS_LIMIT=11,MISS_REQUEST=12,WAIT_LINE=13,DRAIN=14;
 localparam TW=23-LG,QD=16,FD=8;
 reg[3:0] state;
 wire running=(state==RUN||state==REQUEST||state==FILL||state==MISS_LIMIT||state==MISS_REQUEST||state==WAIT_LINE)&&error==0;
 reg check_bad;
 reg[31:0] base,old_epoch,input_end,spatial_start,plane_bytes;
 reg[15:0] h,w,nc,oh,ow,seed_y,seed_x,k_total;
 reg[8:0] count;reg[3:0] kh,kw,py,px,mt;
 reg[1:0] sy,sx;reg wide,high,use_cache,scatter,fast;reg signed[15:0] zero;
 reg fast_pf /* synthesis syn_preserve=1 */;
 reg[1:0] bsl;reg[7:0] zero_lo,zero_hi;
 wire signed[17:0] iy_init=$signed({1'b0,(sy==2)?{seed_y,1'b0}:{1'b0,seed_y}})-$signed({14'b0,py});
 wire signed[34:0] row_off_full=iy_init*$signed({1'b0,w});
 reg[31:0] wb,seg_step,chan_adv;reg signed[31:0] row_off;reg[15:0] kh_back;
 function[7:0] split(input signed[15:0] v,input hi);
  reg signed[16:0] low,upper;
  begin low={{9{v[7]}},v[7:0]};upper=($signed({v[15],v})-low)>>>8;split=hi?upper[7:0]:v[7:0];end
 endfunction
 // Same predicate as the MR source, evaluated over three registered steps.
 reg[31:0] c_plane,c_span,c_start,c_nk;reg[31:0]c_bytes_lo,c_bytes_hi;reg[63:0] c_bytes,c_k,c_kmt;
 wire[63:0] check_plane={32'b0,c_plane},check_bytes=c_bytes,check_k=c_k,check_span={32'b0,c_span},check_start={32'b0,c_start};
 wire bad=h==0||w==0||h>1024||w>1024||nc==0||nc>4096||
  oh==0||ow==0||oh>1024||ow>1024||seed_y>=oh||seed_x>=ow||count==0||count>256||
  kh==0||kh>7||kw==0||kw>7||(sx!=1&&sx!=2)||(sy!=1&&sy!=2)||
  check_start+count>check_span||check_k==0||check_k>4096||c_kmt>4096||
  base>=32'h40000000||({32'b0,base}+check_bytes)>64'h40000000||
  (wide&&base[0])||(!wide&&high)||
  (wide&&(zero < -2048||zero>2047))||(!wide&&(zero < -128||zero>127));

 // ---------------- generator: vector and row-segment walk ----------------
 // gen_on: walking; gen_adv: moving the 32-lane panel to the next mi.
 reg gen_on,gen_adv;reg[5:0] adv_rem;
 reg[3:0] v_mi,v_kx,v_ky;reg[15:0] v_k;reg[15:0]v_k_left;reg[12:0] v_index;reg[8:0] v_left;
 reg[31:0] v_cbase,v_rowbase,v_fastoff;reg signed[15:0] v_iy;
 reg[15:0] oy0,ox0;reg signed[15:0] iy0;reg[31:0] mi_rowbase;
 reg[15:0] panel_row_left,s_row_left;reg[5:0] s_left;
 reg[5:0] s_z;reg[15:0] s_ox;reg signed[15:0] s_iy;reg[31:0] s_rowbase;
 // vend=min(v_left,32) is kept in a register, updated with every v_left assignment.
 reg[5:0] vend;
 function[5:0] vend_of(input[8:0] x);begin vend_of=x>32?6'd32:x[5:0];end endfunction
 wire v_last_vec=(v_mi+1==mt)&&(v_k_left==1);
 // Segment record for the current walker position.
 wire[5:0] lanes_left=s_left;
 wire[15:0] ow_left=s_row_left;
 wire[5:0] seg_len=fast?vend:(ow_left<lanes_left?ow_left[5:0]:lanes_left);
 wire seg_last=fast||(ow_left>={10'b0,lanes_left});
 wire signed[16:0] ix0=$signed({1'b0,(sx==2)?{s_ox[14:0],1'b0}:s_ox})-$signed({13'b0,px})+$signed({13'b0,v_kx});
 wire row_ok=s_iy>=0&&s_iy<$signed({1'b0,h});
 wire signed[16:0] neg_ix0=-ix0;
 wire[5:0] t_lo=(fast||!ix0[16])?6'd0:((sx==2)?neg_ix0[6:1]+neg_ix0[0]:neg_ix0[5:0]);
 wire signed[17:0] room=$signed({2'b0,w})-ix0;
 wire[16:0] t_hi_raw=(sx==2)?(room[16:0]+17'd1)>>1:room[16:0];
 wire[5:0] t_hi=room<=0?6'd0:(t_hi_raw>32?6'd32:t_hi_raw[5:0]);
 wire[5:0] t_end=fast?vend:(!row_ok?6'd0:(t_hi<seg_len?t_hi:seg_len));
 // Valid descriptors bound ix0 below by -15. Ceil clipping therefore leaves
 // 0 for stride 1, or parity(ix0) for stride 2; no subtract/ceil/add feedback cone.
 wire[16:0] first_col=ix0[16]?((sx==2)?{16'b0,ix0[0]}:17'b0):ix0;
 wire[31:0] seg_alo=fast?v_cbase+(v_fastoff<<wide):s_rowbase+({15'b0,first_col}<<wide);
 // Next vector context.
 wire nf_kx_wrap=v_kx+1>=kw,nf_ky_wrap=v_ky+1>=kh;
 // Segment record register.
 // Four-entry reserved record FIFO decouples the walker from pass sizing.
 reg rf_last[0:3],rf_vlast[0:3];reg[5:0] rf_z0[0:3],rf_tlo[0:3],rf_tend[0:3];reg[31:0] rf_alo[0:3],rf_uend[0:3];reg[12:0] rf_index[0:3];
 reg[1:0]rf_rd,rf_wr;reg[2:0]rf_count;
 wire sr_valid=rf_count!=0,sr_last=rf_last[rf_rd],sr_vlast=rf_vlast[rf_rd];
 wire[5:0] sr_z0=rf_z0[rf_rd],sr_tlo=rf_tlo[rf_rd],sr_tend=rf_tend[rf_rd];
 wire[31:0] sr_alo=rf_alo[rf_rd],sr_uend=rf_uend[rf_rd];wire[12:0] sr_index=rf_index[rf_rd];
 // Pass generator.
 reg[5:0] p_toff;
 wire[5:0] p_remain=sr_tend-sr_tlo-p_toff;
 wire p_active=sr_tend>sr_tlo;
 wire[31:0] p_a=sr_alo+({26'b0,p_toff}<<bsl);
 wire[5:0] p_nfit=(bsl==2)?(({1'b0,7'd126-{2'b0,p_a[4:0]}}>>2)+1):6'd32;
 wire[5:0] p_n=p_remain<p_nfit?p_remain:p_nfit;
 wire p_record_done=!p_active||p_n==p_remain;
 // PG register between pass generator and queue write.
 reg pg_valid,pg_vlast,pg_last,pg_empty;reg[31:0] pg_a,pg_uend;reg[5:0] pg_n,pg_za;reg[12:0] pg_index;
 // Queue of passes: {g[4],ls_lo,needed,rot,mask,index,vlast,last,empty,uend}.
 reg[24:0] q_g0[0:QD-1],q_g1[0:QD-1],q_g2[0:QD-1],q_g3[0:QD-1];
 reg[1:0] q_lslo[0:QD-1];reg[3:0] q_need[0:QD-1];reg[6:0] q_rot[0:QD-1];reg[31:0] q_mask[0:QD-1];
 reg[12:0] q_index[0:QD-1];reg q_vlast[0:QD-1],q_last[0:QD-1],q_empty[0:QD-1];reg[31:0] q_uend[0:QD-1];
 reg[4:0] q_tail,q_issue,q_commit;
 wire[4:0] q_used=q_tail-q_commit;
 wire q_space=q_used<QD;
 wire pg_ready=!pg_valid||q_space;
 wire sr_take=sr_valid&&pg_ready&&p_record_done&&running;
 reg sg_valid,sg_fast,sg_wide,sg_stride2,sg_last,sg_vlast,sg_row_ok;
 reg signed[16:0]sg_ix;reg signed[17:0]sg_room;
 reg[5:0]sg_len,sg_vend,sg_z0;reg[12:0]sg_index;
 reg[31:0]sg_rowbase,sg_fastaddr,sg_uend;
 // PU: two spare record slots remove the long same-edge pop bypass.
 // Reserve the pending SG record; full backpressure may add a restart bubble,
 // but uninterrupted records still enter at II=1. No DDR credits are added.
 wire seg_take=running&&gen_on&&!gen_adv&&({1'b0,rf_count}+sg_valid<4'd4);
 wire rf_push=running&&sg_valid;
 wire signed[16:0]sg_neg_ix=-sg_ix;
 wire[5:0]sg_tlo=(sg_fast||!sg_ix[16])?6'd0:
   (sg_stride2?sg_neg_ix[6:1]+sg_neg_ix[0]:sg_neg_ix[5:0]);
 wire[16:0]sg_hi_raw=sg_stride2?(sg_room[16:0]+17'd1)>>1:sg_room[16:0];
 wire[5:0]sg_hi=sg_room<=0?6'd0:sg_hi_raw>32?6'd32:sg_hi_raw[5:0];
 wire[5:0]sg_tend=sg_fast?sg_vend:!sg_row_ok?6'd0:sg_hi<sg_len?sg_hi:sg_len;
 wire[16:0]sg_col=sg_ix[16]?(sg_stride2?{16'b0,sg_ix[0]}:17'b0):sg_ix;
 wire[31:0]sg_alo=sg_fast?sg_fastaddr:sg_rowbase+({15'b0,sg_col}<<sg_wide);
 // Lookup/extract pipeline. c26 keeps eight explicit copies of the byte-rotate
 // selector.  Each copy controls one 128-bit slice, bounding its mux fanout and
 // physical span instead of relying on synthesis to replicate one global net.
 reg s1_valid;reg[24:0] s1_g[0:3];reg[1:0] s1_lslo;reg[3:0] s1_need;reg[6:0] s1_rot;
 reg[1:0] s1_rot_l0 /* synthesis syn_preserve=1 */;
 reg[1:0] s1_rot_l1 /* synthesis syn_preserve=1 */;
 reg[1:0] s1_rot_l2 /* synthesis syn_preserve=1 */;
 reg[1:0] s1_rot_l3 /* synthesis syn_preserve=1 */;
 reg[1:0] s1_rot_l4 /* synthesis syn_preserve=1 */;
 reg[1:0] s1_rot_l5 /* synthesis syn_preserve=1 */;
 reg[1:0] s1_rot_l6 /* synthesis syn_preserve=1 */;
 reg[1:0] s1_rot_l7 /* synthesis syn_preserve=1 */;
 reg[31:0] s1_mask;
 reg[12:0] s1_index;reg s1_vlast,s1_last,s1_empty;reg[31:0] s1_uend;
 reg s2_valid,s2_vlast,s2_last,s2_empty;reg[4:0] s2_rot /* synthesis syn_maxfan=128 */;reg[31:0] s2_mask;reg[12:0] s2_index;reg[1023:0] s2_d;
 reg s3_valid,s3_vlast,s3_last,s3_empty;reg s3_rot6 /* synthesis syn_maxfan=128 */;reg[31:0] s3_mask;reg[12:0] s3_index;reg[1023:0] s3_d;
 reg s4_valid,s4_vlast,s4_last,s4_empty;reg[31:0] s4_mask;reg[12:0] s4_index;reg[255:0] s4_lo,s4_hi;
 reg[255:0] asm_d,asm_h;
 // Output FIFO.
 reg[255:0] f_d[0:FD-1],f_h[0:FD-1];reg[12:0] f_i[0:FD-1];reg f_l[0:FD-1];
 reg[3:0] f_rd,f_wr;wire[3:0] f_count=f_wr-f_rd;
 assign out_valid=!rst&&f_count!=0&&error==0;
 assign out_data=f_d[f_rd[2:0]];assign out_high_data=f_h[f_rd[2:0]];
 assign out_index=f_i[f_rd[2:0]];assign out_last=f_l[f_rd[2:0]];
 assign ready=!rst&&state==IDLE&&error==0;
 // Cache banks.
 wire[255:0] bank_data[0:3];wire[TW-1:0] bank_tag[0:3];wire[3:0] bank_valid;
 reg[31:0] selected;
 // Four bounded ordered cache fills. Requests and cache consumption advance
 // independently; only the missing line is waited on, not the entire burst.
 // No payload FIFO is added. All data goes to the existing four RAM banks.
 reg[31:0]fq_addr[0:3],fq_end[0:3];reg[4:0]fq_left[0:3];
 reg[2:0]fq_head,fq_tail;wire[2:0]fq_count=fq_tail-fq_head;
 wire[31:0]fill_address=fq_addr[fq_head[1:0]];
 wire fill_last=fq_left[fq_head[1:0]]==1;
 wire return_fire=r_valid&&r_ready;
 wire return_bad=return_fire&&(r_error||r_last!=fill_last);
 // A tag-only probe borrows idle cache read ports while a demanded line is
 // outstanding. Probe only already-generated future passes, never other jobs.
 reg[4:0]look_ptr;reg[2:0]probe_state;reg[3:0]pr_need;reg[1:0]pr_lslo;
 reg[24:0]pr_g[0:3];reg[31:0]pr_uend,pf_addr,pf_uend,pf_span,pf_page;
 reg pf_found,pf_valid,pf_filled;reg[4:0]pf_beats;
 // PN: cap each operand independently before selecting the minimum.
 // min(min(span,page),limit) == min(min(span,limit),min(page,limit)).
 // Same registers, requests, cycles and numeric semantics; avoid a 32-bit
 // comparison feeding another wide comparison. Preserve generic fallback.
 wire[31:0]pf_requested;
 generate if(PREFETCH>=0 && PREFETCH<=16)begin : BOUNDED_PREFETCH
  wire[4:0]lim=fast_pf?5'd16:PREFETCH;
  wire[4:0]span_cap=(|pf_span[31:5])||(pf_span[4:0]>=lim)?lim:pf_span[4:0];
  wire[4:0]page_cap=(|pf_page[31:5])||(pf_page[4:0]>=lim)?lim:pf_page[4:0];
  assign pf_requested={27'b0,span_cap<page_cap?span_cap:page_cap};
 end else begin : GENERIC_PREFETCH
  wire[31:0]bounded=pf_span<pf_page?pf_span:pf_page;
  assign pf_requested=bounded<(fast_pf?16:PREFETCH)?bounded:(fast_pf?16:PREFETCH);
 end endgenerate
 // PO03: slot-local range/alias calculations run WITH span calculation.
 // No extra probe stage. Fills may retire between the snapshot and use;
 // conservative coverage is safe and pf_filled covers the same-edge return.
 reg[27:0]pf_distance_q[0:3],pf_absolute_q[0:3];
 reg[LG+1:0]pf_alias_distance_q[0:3];
 reg[3:0]pf_live_q,pf_covered_q,pf_protected_q;
 wire[4:0]pf_slot_limit[0:3];wire[3:0]pf_alias_vec;
 genvar ps;
 generate for(ps=0;ps<4;ps=ps+1)begin:PREFETCH_LOCAL_CHECK
  localparam[1:0]BANK_ID=ps;
  wire[1:0]age=ps-fq_head[1:0];
  wire[24:0]pg=ps==0?q_g0[q_commit[3:0]]:ps==1?q_g1[q_commit[3:0]]:
                       ps==2?q_g2[q_commit[3:0]]:q_g3[q_commit[3:0]];
  wire[26:0]protected_line={pg,BANK_ID};
  always @(posedge clk)if(probe_state==2)begin
   pf_live_q[ps]<={1'b0,age}<fq_count;
   pf_covered_q[ps]<=({1'b0,age}<fq_count)&&pf_addr>=fq_addr[ps]&&pf_addr<fq_end[ps];
   pf_distance_q[ps]<={1'b0,fq_addr[ps][31:5]}-{1'b0,pf_addr[31:5]};
   pf_absolute_q[ps]<={1'b0,protected_line}-{1'b0,pf_addr[31:5]};
   pf_alias_distance_q[ps]<=protected_line[LG+1:0]-pf_addr[LG+6:5];
   pf_protected_q[ps]<=q_need[q_commit[3:0]][ps];
  end
  // Any distance >=32 or negative cannot trim the <=16-beat request.
  assign pf_slot_limit[ps]=pf_live_q[ps]&&!(|pf_distance_q[ps][27:5])&&
       pf_distance_q[ps][4:0]!=0?pf_distance_q[ps][4:0]:5'd16;
  assign pf_alias_vec[ps]=pf_protected_q[ps]&&pf_alias_distance_q[ps]<pf_requested&&
      ((|pf_absolute_q[ps][27:5])||pf_absolute_q[ps][4:0]>=pf_requested);
 end endgenerate
 wire[4:0]pf_min01=pf_slot_limit[0]<pf_slot_limit[1]?pf_slot_limit[0]:pf_slot_limit[1];
 wire[4:0]pf_min23=pf_slot_limit[2]<pf_slot_limit[3]?pf_slot_limit[2]:pf_slot_limit[3];
 wire[4:0]pf_min_slots=pf_min01<pf_min23?pf_min01:pf_min23;
 wire[4:0]pf_trim=pf_requested<pf_min_slots?pf_requested[4:0]:pf_min_slots;
 wire pf_covered=|pf_covered_q,pf_alias=|pf_alias_vec;
 // PU: all tag comparisons and returned-line comparisons are bank local.
 // Select a one-hot winner only after these comparisons; do not select a
 // 25-bit address and then perform another wide equality on the critical path.
 function[3:0] first_missing(input[3:0]mask,input[1:0]lo);
  reg[3:0]rotated,first;
  begin
   case(lo)0:rotated=mask;1:rotated={mask[0],mask[3:1]};
    2:rotated={mask[1:0],mask[3:2]};default:rotated={mask[2:0],mask[3]};endcase
   first={rotated[3]&&!rotated[2]&&!rotated[1]&&!rotated[0],
          rotated[2]&&!rotated[1]&&!rotated[0],rotated[1]&&!rotated[0],rotated[0]};
   case(lo)0:first_missing=first;1:first_missing={first[2:0],first[3]};
    2:first_missing={first[1:0],first[3:2]};default:first_missing={first[0],first[3:1]};endcase
  end
 endfunction
 wire[3:0]pr_miss,pr_pick_raw,pr_pick,pr_return_match;
 wire pr_missing=|pr_miss;
 assign pr_pick_raw=first_missing(pr_miss,pr_lslo);
 assign pr_pick=pr_missing?pr_pick_raw:4'b0001;
 wire[1:0]pr_bank={pr_pick[3]|pr_pick[2],pr_pick[3]|pr_pick[1]};
 wire[24:0]pr_selected_g=({25{pr_pick[0]}}&pr_g[0])|({25{pr_pick[1]}}&pr_g[1])|
     ({25{pr_pick[2]}}&pr_g[2])|({25{pr_pick[3]}}&pr_g[3]);
 genvar pm;
 generate for(pm=0;pm<4;pm=pm+1)begin:PROBE_BANK_MATCH
  localparam[1:0]BID=pm;
  assign pr_miss[pm]=pr_need[pm]&&!(bank_valid[pm]&&bank_tag[pm]==pr_g[pm][22:LG]);
  assign pr_return_match[pm]=fill_address=={pr_g[pm],BID,5'b0};
 end endgenerate
 // PZ: register independent miss selection and same-edge fill match.
 // Reduce them in the existing MISS_LIMIT preparation slot: no new wait state.
 reg[3:0] miss_pick_q,miss_return_q,probe_pick_q,probe_return_q;
 reg selected_filled;reg selected_pending;integer fi;
 wire cache_write;
 wire[24:0]probe_fill_g=fill_address[6:5]==0?q_g0[look_ptr[3:0]]:
  fill_address[6:5]==1?q_g1[look_ptr[3:0]]:fill_address[6:5]==2?q_g2[look_ptr[3:0]]:q_g3[look_ptr[3:0]];
 wire probe_collision=cache_write&&q_need[look_ptr[3:0]][fill_address[6:5]]&&probe_fill_g[LG-1:0]==fill_address[LG+6:7];
 wire probe_issue=state==WAIT_LINE&&selected_pending&&probe_state==0&&!probe_collision&&
   look_ptr!=q_tail&&((look_ptr-q_commit)&31)<((q_tail-q_commit)&31);
 // QN50: address is speculative; only issue/probe_issue authorizes consumption.
 // Keep collision, ownership and queue lifetime checks on valid, off the RAM address.
 wire[4:0]cache_q=(state==WAIT_LINE)?look_ptr:q_issue;

 wire[3:0]selected_slot_pending;
 genvar fs;
 generate for(fs=0;fs<4;fs=fs+1)begin:FILL_SLOT_RANGE
  wire[1:0]age=fs-fq_head[1:0];
  assign selected_slot_pending[fs]=({1'b0,age}<fq_count)&&selected>=fq_addr[fs]&&selected<fq_end[fs];
 end endgenerate
 // QL: preserve exact membership at each consumer edge, but terminate the
 // wide range comparisons at four local state bits instead of cache addresses.
 reg[3:0] selected_pending_q;
 wire[32:0] accepted_end={1'b0,rd_addr}+({28'b0,rd_beats}<<5);
 integer sq;
 always @*selected_pending=|selected_pending_q;
 // synthesis translate_off
 always @(posedge clk)if(!rst&&error==0&&(state==MISS_REQUEST||state==WAIT_LINE))
  if(selected_pending!==( |selected_slot_pending))$fatal(1,"QL_PENDING_MEMBERSHIP_MISMATCH");
 // synthesis translate_on
 reg[31:0] miss_uend;reg[3:0] fresh;reg[24:0] pend_g[0:3];
 wire epoch_clear=start&&ready&&cfg_epoch!=old_epoch;
 reg[GW-1:0] gen;reg sweeping;reg[LG-1:0] sweep_idx;
 assign rd_valid=!rst&&(state==REQUEST||pf_valid)&&fq_count<4&&error==0;
 assign r_ready=!rst&&fq_count!=0&&error==0;
 assign cache_write=return_fire&&!return_bad;
 wire[31:0] page_left=(4096-{20'b0,selected[11:0]})>>5;
 wire[31:0] end_left=(miss_uend+31-selected)>>5;
 reg[31:0]end_left_q,page_left_q;reg[4:0]request_beats;
 wire[31:0] bounded=(end_left_q<page_left_q)?end_left_q:page_left_q;
 wire[31:0] prefetch_limit=fast_pf?16:PREFETCH;
 wire[31:0] requested=(bounded<prefetch_limit)?bounded:prefetch_limit;
 assign rd_addr=pf_valid?pf_addr:selected;assign rd_beats=pf_valid?pf_beats:request_beats;
 // Issue: a vector-completing pass needs a free output slot counting passes in flight.
 wire[4:0] q_iq=q_issue;
 wire[3:0] vlast_flight={3'b0,s1_valid&&s1_vlast}+{3'b0,s2_valid&&s2_vlast}+{3'b0,s3_valid&&s3_vlast}+{3'b0,s4_valid&&s4_vlast};
 wire credit=f_count+vlast_flight<FD;
 // Suppress a same-address RAM read/write collision; correctness does not
 // depend on an unspecified vendor read-during-write mode.
 wire[24:0]issue_fill_g=fill_address[6:5]==0?q_g0[q_iq[3:0]]:
  fill_address[6:5]==1?q_g1[q_iq[3:0]]:fill_address[6:5]==2?q_g2[q_iq[3:0]]:q_g3[q_iq[3:0]];
 wire fill_conflict=cache_write&&q_need[q_iq[3:0]][fill_address[6:5]]&&issue_fill_g[LG-1:0]==fill_address[LG+6:7];
 wire issue=state==RUN&&error==0&&!sweeping&&!fill_conflict&&q_issue!=q_tail&&(!q_vlast[q_iq[3:0]]||credit);
 genvar g;
 generate for(g=0;g<4;g=g+1)begin:BANK
  wire[24:0] issue_g=g==0?q_g0[cache_q[3:0]]:g==1?q_g1[cache_q[3:0]]:g==2?q_g2[cache_q[3:0]]:q_g3[cache_q[3:0]];
  specialized_window_bank #(.LG(LG),.TW(TW),.GW(GW)) cache(
   // Speculative reads have no side effect; data is consumed only by
   // issue/probe_issue tags. A suppressed collision never becomes valid.
   .clk(clk),.re(state==RUN||state==WAIT_LINE),.ra(issue_g[LG-1:0]),.gen(gen),
   .data_q(bank_data[g]),.tag_q(bank_tag[g]),.valid_q(bank_valid[g]),
   .we(sweeping||(cache_write&&fill_address[6:5]==g)),.wa(sweeping?sweep_idx:fill_address[LG+6:7]),.wgen(sweeping?{GW{1'b0}}:gen),
   .data(r_data),.tag(fill_address[29:LG+7]));
 end endgenerate
 // Lookup check of the pass in S1 against bank outputs.
 wire[3:0] s1_hit,s1_miss;
 generate for(g=0;g<4;g=g+1)begin:CHK
  assign s1_hit[g]=bank_valid[g]&&bank_tag[g]==s1_g[g][22:LG]&&(use_cache||fresh[g]);
  assign s1_miss[g]=s1_need[g]&&!s1_hit[g];
 end endgenerate
 wire s1_live=s1_valid&&state==RUN&&error==0;
 wire s1_ok=s1_live&&s1_miss==0;
 always @(posedge clk)begin
  if(rst)selected_pending_q<=0;
  else begin
   if(state==MISS_LIMIT)selected_pending_q<=selected_slot_pending;
   // This edge advances/removes the head. Clear exactly when the selected
   // line has retired, not when a FIFO merely accepted the request.
   if(cache_write&&(fill_last||fill_address==selected))selected_pending_q[fq_head[1:0]]<=0;
   if(rd_valid&&rd_ready)selected_pending_q[fq_tail[1:0]]<=
       ({1'b0,selected}>={1'b0,rd_addr}&&{1'b0,selected}<accepted_end);
   if(s1_live&&!s1_ok)selected_pending_q<=0;
  end
 end

 // Lowest missing line: lines are Ls+i in bank (Ls+i)&3.
 wire[3:0]miss_pick_raw=first_missing(s1_miss,s1_lslo);
 wire[3:0]miss_pick=(|s1_miss)?miss_pick_raw:4'b0001;
 wire[1:0]miss_bank={miss_pick[3]|miss_pick[2],miss_pick[3]|miss_pick[1]};
 wire[24:0]miss_g=({25{miss_pick[0]}}&s1_g[0])|({25{miss_pick[1]}}&s1_g[1])|
     ({25{miss_pick[2]}}&s1_g[2])|({25{miss_pick[3]}}&s1_g[3]);
 wire[3:0]miss_return_match;
 generate for(g=0;g<4;g=g+1)begin:MISS_BANK_MATCH
  localparam[1:0]BID=g;
  assign miss_return_match[g]=fill_address=={s1_g[g],BID,5'b0};
 end endgenerate
 // Rotate helpers (bytes, right rotate).
 function[1023:0] rot(input[1023:0] x,input[6:0] r);
  reg[2047:0] t;begin t={x,x}>>{r,3'b0};rot=t[1023:0];end
 endfunction
 wire[1023:0] s1_bankcat={bank_data[3],bank_data[2],bank_data[1],bank_data[0]};
 reg[1023:0] s1_rotated;
 always @*begin
  case(s1_rot_l0)0:s1_rotated[127:0]=s1_bankcat[127:0];1:s1_rotated[127:0]=s1_bankcat[135:8];2:s1_rotated[127:0]=s1_bankcat[143:16];default:s1_rotated[127:0]=s1_bankcat[151:24];endcase
  case(s1_rot_l1)0:s1_rotated[255:128]=s1_bankcat[255:128];1:s1_rotated[255:128]=s1_bankcat[263:136];2:s1_rotated[255:128]=s1_bankcat[271:144];default:s1_rotated[255:128]=s1_bankcat[279:152];endcase
  case(s1_rot_l2)0:s1_rotated[383:256]=s1_bankcat[383:256];1:s1_rotated[383:256]=s1_bankcat[391:264];2:s1_rotated[383:256]=s1_bankcat[399:272];default:s1_rotated[383:256]=s1_bankcat[407:280];endcase
  case(s1_rot_l3)0:s1_rotated[511:384]=s1_bankcat[511:384];1:s1_rotated[511:384]=s1_bankcat[519:392];2:s1_rotated[511:384]=s1_bankcat[527:400];default:s1_rotated[511:384]=s1_bankcat[535:408];endcase
  case(s1_rot_l4)0:s1_rotated[639:512]=s1_bankcat[639:512];1:s1_rotated[639:512]=s1_bankcat[647:520];2:s1_rotated[639:512]=s1_bankcat[655:528];default:s1_rotated[639:512]=s1_bankcat[663:536];endcase
  case(s1_rot_l5)0:s1_rotated[767:640]=s1_bankcat[767:640];1:s1_rotated[767:640]=s1_bankcat[775:648];2:s1_rotated[767:640]=s1_bankcat[783:656];default:s1_rotated[767:640]=s1_bankcat[791:664];endcase
  case(s1_rot_l6)0:s1_rotated[895:768]=s1_bankcat[895:768];1:s1_rotated[895:768]=s1_bankcat[903:776];2:s1_rotated[895:768]=s1_bankcat[911:784];default:s1_rotated[895:768]=s1_bankcat[919:792];endcase
  case(s1_rot_l7)0:s1_rotated[1023:896]=s1_bankcat[1023:896];1:s1_rotated[1023:896]={s1_bankcat[7:0],s1_bankcat[1023:904]};2:s1_rotated[1023:896]={s1_bankcat[15:0],s1_bankcat[1023:912]};default:s1_rotated[1023:896]={s1_bankcat[23:0],s1_bankcat[1023:920]};endcase
 end
 // Decimation and split.
 reg[255:0] dec_lo,dec_hi;integer z;
 wire[1023:0] s3_full=s3_rot6?{s3_d[511:0],s3_d[1023:512]}:s3_d;
 always @*for(z=0;z<32;z=z+1)begin
  dec_lo[z*8+:8]=bsl==0?s3_full[z*8+:8]:bsl==1?s3_full[z*16+:8]:s3_full[(z*32)%1024+:8];
  dec_hi[z*8+:8]=bsl==1?s3_full[z*16+8+:8]:bsl==2?s3_full[(z*32+8)%1024+:8]:{8{s3_full[z*8+7]}};
 end
 reg[255:0] lane_d,lane_h;reg[31:0] lane_bad;reg signed[15:0] smp;integer y;
 always @*for(y=0;y<32;y=y+1)begin
  smp=wide?{s4_hi[y*8+:8],s4_lo[y*8+:8]}:{{8{s4_lo[y*8+7]}},s4_lo[y*8+:8]};
  lane_d[y*8+:8]=split(smp,high);lane_h[y*8+:8]=split(smp,1'b1);
  lane_bad[y]=wide&&smp[15:12]!={4{smp[11]}};
 end
 reg[255:0] merged_d,merged_h;integer u;
 always @*for(u=0;u<32;u=u+1)begin
  merged_d[u*8+:8]=s4_mask[u]?lane_d[u*8+:8]:asm_d[u*8+:8];
  merged_h[u*8+:8]=s4_mask[u]?lane_h[u*8+:8]:asm_h[u*8+:8];
 end
 wire s4_bad=s4_valid&&!s4_empty&&(lane_bad&s4_mask)!=0;
 // PA: payload advances even during reset; only the valid pipeline is reset.
 // No stage latency/II change, no accepted transaction or RAM write is added.
 always @(posedge clk)begin
  // PI stage payload is free-running; seg_take controls validity and walker
  // advance, never a wide payload CE. The record is consumed the next edge.
  sg_fast<=fast;sg_wide<=wide;sg_stride2<=sx==2;
  sg_last<=seg_last;sg_vlast<=seg_last&&v_last_vec;sg_row_ok<=row_ok;
  sg_ix<=ix0;sg_room<=room;sg_len<=seg_len;sg_vend<=vend;sg_z0<=s_z;
  sg_index<=v_index;sg_rowbase<=s_rowbase;sg_fastaddr<=v_cbase+(v_fastoff<<wide);
  sg_uend<=fast&&count!=check_plane[15:0]?v_cbase+((spatial_start+count)<<wide):input_end;
  s2_vlast<=s1_vlast;
  s2_last<=s1_last;
  s2_empty<=s1_empty;
  s2_rot<=s1_rot[6:2];
  s2_mask<=s1_mask;
  s2_index<=s1_index;
  s2_d<=s1_rotated;
  s3_vlast<=s2_vlast;
  s3_last<=s2_last;
  s3_empty<=s2_empty;
  s3_rot6<=s2_rot[4];
  s3_mask<=s2_mask;
  s3_index<=s2_index;
  s3_d<=rot(rot(s2_d,{3'b0,s2_rot[1:0],2'b0}),{1'b0,s2_rot[3:2],4'b0});
  s4_vlast<=s3_vlast;
  s4_last<=s3_last;
  s4_empty<=s3_empty;
  s4_mask<=s3_mask;
  s4_index<=s3_index;
  s4_lo<=dec_lo;
  s4_hi<=dec_hi;
 end
 integer i;
 always @(posedge clk)begin
  if(rst)begin
   gen<=1;sweeping<=1;sweep_idx<=0;
   state<=IDLE;error<=0;done<=0;old_epoch<=0;check_bad<=0;
   cycles<=0;read_bytes<=0;hits<=0;misses<=0;vectors<=0;stall_cycles<=0;
   base<=0;input_end<=0;spatial_start<=0;plane_bytes<=0;
   h<=0;w<=0;nc<=0;oh<=0;ow<=0;seed_y<=0;seed_x<=0;k_total<=0;count<=0;kh<=0;kw<=0;py<=0;px<=0;mt<=0;
   sy<=0;sx<=0;wide<=0;high<=0;use_cache<=0;scatter<=0;fast<=0;fast_pf<=0;zero<=0;bsl<=0;zero_lo<=0;zero_hi<=0;
   wb<=0;seg_step<=0;chan_adv<=0;row_off<=0;kh_back<=0;
   gen_on<=0;gen_adv<=0;adv_rem<=0;v_mi<=0;v_kx<=0;v_ky<=0;v_k<=0;v_k_left<=0;v_index<=0;v_left<=0;vend<=0;
   v_cbase<=0;v_rowbase<=0;v_fastoff<=0;v_iy<=0;oy0<=0;ox0<=0;iy0<=0;mi_rowbase<=0;
   s_z<=0;s_ox<=0;s_iy<=0;s_rowbase<=0;panel_row_left<=0;s_row_left<=0;s_left<=0;rf_rd<=0;rf_wr<=0;rf_count<=0;
   p_toff<=0;pg_valid<=0;sg_valid<=0;q_tail<=0;q_issue<=0;q_commit<=0;
   s1_valid<=0;s2_valid<=0;s3_valid<=0;s4_valid<=0;asm_d<=0;asm_h<=0;f_rd<=0;f_wr<=0;
   selected<=0;fq_head<=0;fq_tail<=0;selected_filled<=0;look_ptr<=0;probe_state<=0;pf_valid<=0;miss_uend<=0;fresh<=0;
  end else begin
   done<=0;
   if(sweeping)begin sweep_idx<=sweep_idx+1'b1;if(&sweep_idx)sweeping<=0;end
   if(epoch_clear)begin
    if(&gen)begin gen<=1;sweeping<=1;sweep_idx<=0;end else gen<=gen+1'b1;
   end
   if(state!=IDLE&&error==0)cycles<=cycles+1;
   if((out_valid&&!out_ready)||(rd_valid&&!rd_ready)||(r_ready&&!r_valid))stall_cycles<=stall_cycles+1;
   if(out_valid&&out_ready)begin
    f_rd<=f_rd+1;vectors<=vectors+1;
    if(f_l[f_rd[2:0]])begin
     if(fq_count==0)begin done<=1;state<=IDLE;end else state<=DRAIN;
    end
   end
   if(start&&ready)begin
    base<=cfg_base;h<=cfg_h;w<=cfg_w;nc<=cfg_c;oh<=cfg_oh;ow<=cfg_ow;
    seed_y<=cfg_y;seed_x<=cfg_x;count<=cfg_m;kh<=cfg_kh;kw<=cfg_kw;sy<=cfg_sy;sx<=cfg_sx;py<=cfg_py;px<=cfg_px;
    wide<=cfg_wide;high<=cfg_high;use_cache<=cfg_cache;scatter<=cfg_scatter;zero<=cfg_zero;
    mt<=({1'b0,cfg_m}+31)>>5;old_epoch<=cfg_epoch;state<=CHECK;
   end
   if(error==0)case(state)
    MISS_LIMIT:begin end_left_q<=end_left;page_left_q<=page_left;selected_filled<=|(miss_pick_q&miss_return_q);state<=MISS_REQUEST;end
    MISS_REQUEST:begin
     request_beats<=requested[4:0];
     if(use_cache&&(selected_filled||selected_pending))state<=WAIT_LINE;else state<=REQUEST;
    end
    WAIT_LINE:if(!selected_pending&&probe_state==0&&!pf_valid)state<=RUN;
    DRAIN:if(fq_count==0)begin done<=1;state<=IDLE;end
    CHECK:begin
     c_plane<={16'b0,h}*w;c_span<={16'b0,oh}*ow;c_start<={16'b0,seed_y}*ow+seed_x;c_nk<={16'b0,nc}*kh;
     state<=CHECK2;
    end
    CHECK2:begin
     c_bytes_lo<=c_plane[15:0]*nc;c_bytes_hi<=c_plane[31:16]*nc;c_k<={32'b0,c_nk}*kw;state<=CHECK3;
    end
    CHECK3:begin c_bytes<=({32'b0,c_bytes_lo}+{16'b0,c_bytes_hi,16'b0})<<wide;c_kmt<=c_k*mt;state<=CHECK4;end
    CHECK4:begin
     check_bad<=bad;
     plane_bytes<=check_plane<<wide;input_end<=base+check_bytes;k_total<=check_k;spatial_start<=check_start;
     state<=CHECK_APPLY;
    end
    CHECK_APPLY:if(check_bad)begin error<=1;state<=IDLE;end else begin
     fast<=scatter&&kh==1&&kw==1&&sy==1&&sx==1&&py==0&&px==0&&oh==h&&ow==w;
     fast_pf<=scatter&&kh==1&&kw==1&&sy==1&&sx==1&&py==0&&px==0&&oh==h&&ow==w;
     bsl<=(sx==2?2'd1:2'd0)+(wide?2'd1:2'd0);
     zero_lo<=split(zero,high);zero_hi<=split(zero,1'b1);
     row_off<=row_off_full[31:0];
     kh_back<=(kh-1)*w;
     state<=SETUP1;
    end
    SETUP1:begin
     wb<={16'b0,w}<<wide;seg_step<=({16'b0,w}<<(sy==2))<<wide;
     chan_adv<=plane_bytes-({16'b0,kh_back}<<wide);
     mi_rowbase<=base+(row_off<<<wide);
     oy0<=seed_y;ox0<=seed_x;iy0<=iy_init[15:0];panel_row_left<=ow-seed_x;
     state<=SETUP2;
    end
    SETUP2:begin
     // First vector of the first panel. Assembly holds the padding value.
     v_mi<=0;v_k<=0;v_k_left<=k_total;v_kx<=0;v_ky<=0;v_index<=0;v_left<=count;vend<=vend_of(count);v_cbase<=base;v_fastoff<=spatial_start;
     v_rowbase<=mi_rowbase;v_iy<=iy0;
     s_z<=0;s_ox<=ox0;s_iy<=iy0;s_rowbase<=mi_rowbase;s_row_left<=panel_row_left;s_left<=vend_of(count);
     asm_d<={32{zero_lo}};asm_h<={32{zero_hi}};
     gen_on<=1;gen_adv<=0;rf_rd<=0;rf_wr<=0;rf_count<=0;p_toff<=0;pg_valid<=0;sg_valid<=0;
     q_tail<=0;q_issue<=0;q_commit<=0;s1_valid<=0;s2_valid<=0;s3_valid<=0;s4_valid<=0;f_rd<=0;f_wr<=0;fresh<=0;
     state<=RUN;
    end
    REQUEST:if(rd_valid&&rd_ready)begin
     state<=use_cache?RUN:FILL;
    end
    FILL:if(cache_write&&fill_last)state<=RUN;
   endcase
   // ---- generator ----
   if(running)begin
    if(gen_adv)begin
     if({10'b0,adv_rem}<panel_row_left)begin
      ox0<=ox0+adv_rem;gen_adv<=0;panel_row_left<=panel_row_left-adv_rem;s_row_left<=panel_row_left-adv_rem;s_left<=vend;
      v_rowbase<=mi_rowbase;v_iy<=iy0;s_z<=0;s_ox<=ox0+adv_rem;s_iy<=iy0;s_rowbase<=mi_rowbase;
     end else begin
      adv_rem<=adv_rem-panel_row_left;panel_row_left<=ow;ox0<=0;oy0<=oy0+1;iy0<=iy0+sy;mi_rowbase<=mi_rowbase+seg_step;
     end
    end
    rf_count<=rf_count+rf_push-sr_take;
    if(sr_take)rf_rd<=rf_rd+1'b1;
    sg_valid<=seg_take;
    if(rf_push)begin
     rf_wr<=rf_wr+1'b1;rf_last[rf_wr]<=sg_last;rf_vlast[rf_wr]<=sg_vlast;
     rf_z0[rf_wr]<=sg_z0;rf_tlo[rf_wr]<=sg_tlo;rf_tend[rf_wr]<=sg_tend;
     rf_alo[rf_wr]<=sg_alo;rf_index[rf_wr]<=sg_index;rf_uend[rf_wr]<=sg_uend;
    end
    if(seg_take)begin
     // The independently registered payload above belongs to this admission.
     if(!seg_last)begin
      s_left<=s_left-seg_len;s_row_left<=ow;s_z<=s_z+seg_len;s_ox<=0;s_iy<=s_iy+sy;s_rowbase<=s_rowbase+seg_step;
     end else if(fast)begin
      if(v_mi+1<mt)begin
       v_mi<=v_mi+1;v_left<=v_left-32;vend<=vend_of(v_left-32);s_left<=vend_of(v_left-32);v_fastoff<=v_fastoff+32;v_index<=v_index+k_total;
      end else if(v_k_left>1)begin
       v_mi<=0;v_left<=count;vend<=vend_of(count);s_left<=vend_of(count);v_fastoff<=spatial_start;v_k<=v_k+1;v_k_left<=v_k_left-1'b1;v_index<=v_k+1;v_cbase<=v_cbase+plane_bytes;
      end else gen_on<=0;
      s_z<=0;
     end else begin
      v_index<=v_index+1;s_row_left<=panel_row_left;s_left<=vend;
      if(v_k_left==1)begin
       if(v_mi+1==mt)gen_on<=0;
       else begin
        v_mi<=v_mi+1;v_left<=v_left-32;vend<=vend_of(v_left-32);v_k<=0;v_k_left<=k_total;v_kx<=0;v_ky<=0;v_cbase<=base;
        gen_adv<=1;adv_rem<=32;
       end
      end else begin
       v_k<=v_k+1;v_k_left<=v_k_left-1'b1;
       if(!nf_kx_wrap)begin
        v_kx<=v_kx+1;s_z<=0;s_ox<=ox0;s_iy<=v_iy;s_rowbase<=v_rowbase;
       end else if(!nf_ky_wrap)begin
        v_kx<=0;v_ky<=v_ky+1;v_iy<=v_iy+1;v_rowbase<=v_rowbase+wb;
        s_z<=0;s_ox<=ox0;s_iy<=v_iy+1;s_rowbase<=v_rowbase+wb;
       end else begin
        v_kx<=0;v_ky<=0;v_iy<=iy0;v_rowbase<=v_rowbase+chan_adv;v_cbase<=v_cbase+plane_bytes;
        s_z<=0;s_ox<=ox0;s_iy<=iy0;s_rowbase<=v_rowbase+chan_adv;
       end
      end
     end
    end
   end
   // ---- pass generator -> PG register ----
   if(running)begin
    if(pg_ready)begin
     pg_valid<=0;
     if(sr_valid&&(p_active||sr_last))begin
      pg_valid<=1;pg_vlast<=sr_last&&p_record_done;pg_last<=sr_vlast&&p_record_done;pg_empty<=!p_active;
      pg_a<=p_a;pg_n<=p_active?p_n:6'd0;pg_za<=sr_z0+sr_tlo+p_toff;pg_index<=sr_index;pg_uend<=sr_uend;
     end
     if(sr_valid)p_toff<=p_record_done?6'd0:p_toff+p_n;
    end
    // ---- queue write ----
    if(pg_valid&&q_space)begin : QW
     reg[24:0] gg,gg1;reg[6:0] span;reg[2:0] nl;reg[3:0] base_need;reg[1:0] lo;
     gg=pg_a[31:7];gg1=gg+1;lo=pg_a[6:5];
     q_g0[q_tail[3:0]]<=(0<lo)?gg1:gg;q_g1[q_tail[3:0]]<=(1<lo)?gg1:gg;
     q_g2[q_tail[3:0]]<=(2<lo)?gg1:gg;q_g3[q_tail[3:0]]<=gg;
     span={2'b0,pg_a[4:0]}+((pg_n==0?7'd0:{1'b0,pg_n-6'd1})<<bsl)+(wide?7'd1:7'd0);
     nl=pg_empty?3'd0:{1'b0,span[6:5]}+3'd1;
     base_need=nl==0?4'b0000:nl==1?4'b0001:nl==2?4'b0011:nl==3?4'b0111:4'b1111;
     q_need[q_tail[3:0]]<=({base_need,base_need}<<lo)>>4;
     q_lslo[q_tail[3:0]]<=lo;
     q_rot[q_tail[3:0]]<=pg_a[6:0]-({1'b0,pg_za}<<bsl);
     q_mask[q_tail[3:0]]<=pg_empty?32'b0:((32'hffffffff<<pg_za)&~((33'h1ffffffff<<({1'b0,pg_za}+pg_n))));
     q_index[q_tail[3:0]]<=pg_index;q_vlast[q_tail[3:0]]<=pg_vlast;q_last[q_tail[3:0]]<=pg_last;
     q_empty[q_tail[3:0]]<=pg_empty;q_uend[q_tail[3:0]]<=pg_uend;
     q_tail<=q_tail+1;
    end
   end
   // ---- issue to S1 ----
   if(issue)begin
    s1_valid<=1;s1_g[0]<=q_g0[q_iq[3:0]];s1_g[1]<=q_g1[q_iq[3:0]];s1_g[2]<=q_g2[q_iq[3:0]];s1_g[3]<=q_g3[q_iq[3:0]];
    s1_lslo<=q_lslo[q_iq[3:0]];s1_need<=q_need[q_iq[3:0]];s1_rot<=q_rot[q_iq[3:0]];
    s1_rot_l0<=q_rot[q_iq[3:0]][1:0];s1_rot_l1<=q_rot[q_iq[3:0]][1:0];
    s1_rot_l2<=q_rot[q_iq[3:0]][1:0];s1_rot_l3<=q_rot[q_iq[3:0]][1:0];
    s1_rot_l4<=q_rot[q_iq[3:0]][1:0];s1_rot_l5<=q_rot[q_iq[3:0]][1:0];
    s1_rot_l6<=q_rot[q_iq[3:0]][1:0];s1_rot_l7<=q_rot[q_iq[3:0]][1:0];
    s1_mask<=q_mask[q_iq[3:0]];
    s1_index<=q_index[q_iq[3:0]];s1_vlast<=q_vlast[q_iq[3:0]];s1_last<=q_last[q_iq[3:0]];s1_empty<=q_empty[q_iq[3:0]];
    s1_uend<=q_uend[q_iq[3:0]];q_issue<=q_issue+1;
   end else if(state==RUN)s1_valid<=0;
   // ---- S1 lookup ----
   s2_valid<=s1_ok;
   
   if(s1_ok)begin
    q_commit<=q_commit+1;fresh<=0;
    if(!s1_empty)hits<=hits+s1_need[0]+s1_need[1]+s1_need[2]+s1_need[3];
   end else if(s1_live)begin
    // Miss: replay this pass after the fill; later issues are discarded.
    q_issue<=q_commit;s1_valid<=0;
    selected<={miss_g,miss_bank,5'b0};miss_uend<=s1_uend;state<=MISS_LIMIT;
    selected_filled<=0;miss_pick_q<=miss_pick;miss_return_q<={4{cache_write}}&miss_return_match;
    look_ptr<=q_commit+1;
    for(i=0;i<4;i=i+1)pend_g[i]<=s1_g[i];
   end
   // ---- rotate and decimate ----
   s3_valid<=s2_valid;
   
   s4_valid<=s3_valid;
   
   // ---- merge and output ----
   if(s4_valid&&error==0)begin
    if(s4_bad)begin error<=4;state<=IDLE;end
    else if(s4_vlast)begin
     f_d[f_wr[2:0]]<=merged_d;f_h[f_wr[2:0]]<=merged_h;f_i[f_wr[2:0]]<=s4_index;f_l[f_wr[2:0]]<=s4_last;f_wr<=f_wr+1;
     asm_d<={32{zero_lo}};asm_h<={32{zero_hi}};
    end else begin asm_d<=merged_d;asm_h<=merged_h;end
   end
   if(rd_valid&&rd_ready)begin
    misses<=misses+1;fq_addr[fq_tail[1:0]]<=rd_addr;
    fq_end[fq_tail[1:0]]<=rd_addr+({27'b0,rd_beats}<<5);
    fq_left[fq_tail[1:0]]<=rd_beats;fq_tail<=fq_tail+1;
    if(pf_valid)begin pf_valid<=0;probe_state<=0;end
   end
   if(probe_issue)begin
    look_ptr<=look_ptr+1;probe_state<=1;pr_need<=q_need[look_ptr[3:0]];pr_lslo<=q_lslo[look_ptr[3:0]];
    pr_g[0]<=q_g0[look_ptr[3:0]];pr_g[1]<=q_g1[look_ptr[3:0]];
    pr_g[2]<=q_g2[look_ptr[3:0]];pr_g[3]<=q_g3[look_ptr[3:0]];pr_uend<=q_uend[look_ptr[3:0]];
   end
   if(probe_state==1)begin
    pf_addr<={pr_selected_g,pr_bank,5'b0};pf_uend<=pr_uend;pf_found<=pr_missing;probe_state<=2;
    pf_filled<=0;probe_pick_q<=pr_pick;probe_return_q<={4{cache_write}}&pr_return_match;
   end
   if(probe_state==2)begin
    pf_filled<=|(probe_pick_q&probe_return_q);
    pf_span<=(pf_uend+31-pf_addr)>>5;pf_page<=(4096-{20'b0,pf_addr[11:0]})>>5;probe_state<=3;
   end
   if(probe_state==3)begin
    // Debug/timing candidate: payload capture is independent of acceptance.
    // A rejected probe is never advertised; a held accepted AR is unchanged.
    // Keep span/min/trim validation off the payload register clock-enable.
    pf_beats<=pf_trim;
    if(pf_found&&!pf_covered&&!pf_alias&&!pf_filled&&pf_trim!=0&&
       !(cache_write&&fill_address==pf_addr))begin pf_valid<=1;probe_state<=4;end
    else probe_state<=0;
   end
   if(cache_write&&(probe_state==2||probe_state==3)&&fill_address==pf_addr)pf_filled<=1;
   if(cache_write)begin
    read_bytes<=read_bytes+32;
    fq_addr[fq_head[1:0]]<=fill_address+32;
    if(fill_last)fq_head<=fq_head+1;else fq_left[fq_head[1:0]]<=fq_left[fq_head[1:0]]-1;
    if(fill_address==selected && !(s1_live&&!s1_ok))selected_filled<=1;
    // Uncached operation retains the original pass-scoped freshness contract.
    if(!use_cache)for(i=0;i<4;i=i+1)
     if(fill_address[6:5]==i&&fill_address[31:7]==pend_g[i])fresh[i]<=1;
   end
   // Only unadvertised speculation may be cancelled; held AR remains stable.
   if(state==WAIT_LINE&&!selected_pending&&!pf_valid)begin
    state<=RUN;probe_state<=0;pf_valid<=0;
   end
   if(return_bad)begin error<=2;done<=0;state<=IDLE;end

  end
 end
endmodule

// Simple-dual-port RAM banks: data and tags have no reset or partial writes.
module specialized_window_bank #(parameter LG=9,TW=14,GW=8)(
 input wire clk,re,we,input wire[LG-1:0] ra,wa,input wire[GW-1:0] gen,wgen,
 input wire[255:0]data,input wire[TW-1:0]tag,
 output reg[255:0]data_q,output wire[TW-1:0]tag_q,output wire valid_q
);
 reg[255:0] mem[0:(1<<LG)-1] /* synthesis syn_ramstyle="block_ram" */;
 reg[TW+GW-1:0] tags[0:(1<<LG)-1] /* synthesis syn_ramstyle="block_ram" */;
 reg[TW+GW-1:0] tq;
 // The current generation cannot change between a read and its use.
 assign valid_q=tq[TW+GW-1:TW]==gen;assign tag_q=tq[TW-1:0];
 always @(posedge clk)begin
  if(re)begin data_q<=mem[ra];tq<=tags[ra];end
  if(we)begin mem[wa]<=data;tags[wa]<={wgen,tag};end
 end
endmodule
