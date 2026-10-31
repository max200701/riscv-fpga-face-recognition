// Full shared-memory accelerator integration; physical DDR/PLL remains external.
module fullgraph_accelerators #(parameter NATIVE=0, PROGRAM_CACHE=0, SAME_CLOCK=0, LOCAL_APPLICATION_HOLD=0)(
 input wire application_cold_rst,application_hold_next,
 input wire arst,cpu_clk,npu_clk,ddr_clk,ddr_init_done,
 input wire bus_valid,bus_write,input wire[11:0]bus_addr,input wire[31:0]bus_wdata,input wire[3:0]bus_wstrb,
 input wire npu_dq_valid,output wire npu_dq_ready,input wire[31:0]npu_dq_door,input wire[255:0]npu_dq_args,   // c22
 output wire npu_dr_valid,input wire npu_dr_pop,output wire[127:0]npu_dr_data,
 output wire bus_ready,bus_error,output wire[31:0]bus_rdata,output wire irq,
 input wire program_owner,program_rd_valid,output wire program_rd_ready,input wire[31:0]program_rd_address,input wire[4:0]program_rd_beats,
 output wire program_r_valid,input wire program_r_ready,output wire[255:0]program_r_data,output wire program_r_last,program_r_error,
 output wire axi_arvalid,input wire axi_arready,output wire[27:0]axi_araddr,
 output wire[3:0]axi_arlen,axi_aruser_id,output wire axi_aruser_ap,
 input wire axi_rvalid,input wire[255:0]axi_rdata,input wire axi_rlast,input wire[3:0]axi_rid,
 output wire axi_awvalid,input wire axi_awready,output wire[27:0]axi_awaddr,
 output wire[3:0]axi_awlen,axi_awuser_id,output wire axi_awuser_ap,
 output wire[255:0]axi_wdata,output wire[31:0]axi_wstrb,
 input wire axi_wready,input wire[3:0]axi_wusero_id,input wire axi_wusero_last,
 output wire fault,output wire[63:0]npu_macs,vector_elements
);
// Same-cycle local roots: source ownership state and destination reset release are unchanged.
 wire[5:0] local_arst;
 genvar hr;
 generate for(hr=0;hr<6;hr=hr+1)begin:hold_roots
  if(LOCAL_APPLICATION_HOLD)begin:local_root
   demo_hold_root root(.clk(ddr_clk),.cold_rst(application_cold_rst),.hold_next(application_hold_next),.reset(local_arst[hr]));
  end else begin:legacy_root
   assign local_arst[hr]=arst;
  end
 end endgenerate
 wire npu_arst; graph_reset_leaf npu_reset_leaf(.clk(npu_clk),.arst(local_arst[0]),.reset(npu_arst));
 wire vector_arst; graph_reset_leaf vector_reset_leaf(.clk(npu_clk),.arst(local_arst[1]),.reset(vector_arst));
 wire vector_transport_arst; graph_reset_leaf vector_transport_reset_leaf(.clk(ddr_clk),.arst(local_arst[2]),.reset(vector_transport_arst));
 wire package_arst; graph_reset_leaf package_reset_leaf(.clk(cpu_clk),.arst(local_arst[3]),.reset(package_arst));
 wire package_transport_arst; graph_reset_leaf package_transport_reset_leaf(.clk(ddr_clk),.arst(local_arst[4]),.reset(package_transport_arst));
 wire fabric_arst; graph_reset_leaf fabric_reset_leaf(.clk(ddr_clk),.arst(local_arst[5]),.reset(fabric_arst));
wire[2:0]br,be,bi,arv,arr,arap,rv,awv,awr,awap,wr;
 // claude_c02 c19: client-side AR/AW (c*) pass through two-entry skid buffers to the arbiter; R is
 // delivered to the clients one register later (no backpressure on R). W is unchanged.
 wire[2:0]carv,carr,carap,cawv,cawr,cawap;wire[27:0]cara[0:2],cawa[0:2];wire[3:0]carl[0:2],cari[0:2],cawl[0:2],cawi[0:2];
 reg[2:0]rv_q;reg[255:0]rdata_q;reg rlast_q;reg[3:0]rid_q;
 always @(posedge ddr_clk)begin rv_q<=fabric_arst?3'b0:rv;rdata_q<=axi_rdata;rlast_q<=axi_rlast;rid_q<=axi_rid;end
 genvar sk;
 generate for(sk=0;sk<3;sk=sk+1)begin:hmic_skid
  axi_skid #(.W(37)) ar(.clk(ddr_clk),.rst(fabric_arst),.s_valid(carv[sk]),.s_ready(carr[sk]),.s_data({cara[sk],carl[sk],cari[sk],carap[sk]}),
   .m_valid(arv[sk]),.m_ready(arr[sk]),.m_data({ara[sk],arl[sk],ari[sk],arap[sk]}));
  axi_skid #(.W(37)) aw(.clk(ddr_clk),.rst(fabric_arst),.s_valid(cawv[sk]),.s_ready(cawr[sk]),.s_data({cawa[sk],cawl[sk],cawi[sk],cawap[sk]}),
   .m_valid(awv[sk]),.m_ready(awr[sk]),.m_data({awa[sk],awl[sk],awi[sk],awap[sk]}));
 end endgenerate
 wire[31:0]bd[0:2];wire[27:0]ara[0:2],awa[0:2];wire[3:0]arl[0:2],ari[0:2],awl[0:2],awi[0:2];
 wire[255:0]wd[0:2];wire[31:0]ws[0:2];wire arb_fault,vfault,pfault,nfault,rwfault;
 wire[1:0]sel=bus_addr[11]?2:bus_addr[10]?1:0;
 assign bus_ready=br[sel];assign bus_error=be[sel];assign bus_rdata=bd[sel];assign irq=|bi;
 assign fault=arb_fault||vfault||pfault||nfault||rwfault;
cpu_npu_queue #(.NATIVE(NATIVE),.WATCHDOG(4000000),.SAME_CLOCK(SAME_CLOCK)) npu(
 .arst(npu_arst),.cpu_clk(cpu_clk),.npu_clk(npu_clk),.bus_valid(bus_valid&&sel==0),.bus_write(bus_write),.bus_addr(bus_addr),
 .bus_wdata(bus_wdata),.bus_wstrb(bus_wstrb),.bus_ready(br[0]),.bus_error(be[0]),.bus_rdata(bd[0]),.diagnostic_fault(nfault),.diagnostic_macs(npu_macs),
 .dq_valid(npu_dq_valid),.dq_ready(npu_dq_ready),.dq_door(npu_dq_door),.dq_args(npu_dq_args),.dr_valid(npu_dr_valid),.dr_pop(npu_dr_pop),.dr_data(npu_dr_data),.irq(bi[0]),.ddr_clk(ddr_clk),.ddr_init_done(ddr_init_done),
 .axi_arvalid(carv[0]),.axi_arready(carr[0]),.axi_araddr(cara[0]),.axi_arlen(carl[0]),.axi_aruser_id(cari[0]),.axi_aruser_ap(carap[0]),
 .axi_rvalid(rv_q[0]),.axi_rdata(rdata_q),.axi_rlast(rlast_q),.axi_rid(rid_q),
 .axi_awvalid(cawv[0]),.axi_awready(cawr[0]),.axi_awaddr(cawa[0]),.axi_awlen(cawl[0]),.axi_awuser_id(cawi[0]),.axi_awuser_ap(cawap[0]),
 .axi_wdata(wd[0]),.axi_wstrb(ws[0]),.axi_wready(wr[0]),.axi_wusero_id(axi_wusero_id),.axi_wusero_last(axi_wusero_last));
wire vector_rdv,vector_rdr,vector_rv,vector_rr,vector_rl,vector_re;
 wire[31:0]vector_ra;wire[4:0]vector_rn;wire[255:0]vector_data;
 wire vector_ov,vector_ore,vector_ol,vector_pv,vector_pr;wire[31:0]vector_oa,vector_os,vector_ot,vector_pt;wire[255:0]vector_od;
graph_vector_bridge vector(.arst(vector_arst),.cpu_clk(cpu_clk),.npu_clk(npu_clk),.bus_valid(bus_valid&&sel==1),.bus_write(bus_write),.bus_addr(bus_addr),
 .bus_wdata(bus_wdata),.bus_wstrb(bus_wstrb),.bus_ready(br[1]),.bus_error(be[1]),.bus_rdata(bd[1]),.diagnostic_elements(vector_elements),.irq(bi[1]),.rd_valid(vector_rdv),.rd_ready(vector_rdr),.rd_addr(vector_ra),.rd_beats(vector_rn),
 .r_valid(vector_rv),.r_ready(vector_rr),.r_data(vector_data),.r_last(vector_rl),.r_error(vector_re),.out_valid(vector_ov),.out_ready(vector_ore),.out_addr(vector_oa),.out_strb(vector_os),.out_tag(vector_ot),.out_data(vector_od),.out_last(vector_ol),
 .posted_valid(vector_pv),.posted_ready(vector_pr),.posted_tag(vector_pt));
hmic_layout_cdc #(.TIMEOUT_CYCLES(4000000)) vector_transport(.arst(vector_transport_arst),.npu_clk(npu_clk),.ddr_clk(ddr_clk),.ddr_init_done(ddr_init_done),
 .rd_valid(vector_rdv),.rd_ready(vector_rdr),.rd_addr(vector_ra),.rd_beats(vector_rn),
 .r_valid(vector_rv),.r_ready(vector_rr),.r_data(vector_data),.r_last(vector_rl),.r_error(vector_re),.in_valid(vector_ov),.in_ready(vector_ore),.in_addr(vector_oa),.in_data(vector_od),.in_strb(vector_os),.in_tag(vector_ot),.in_last(vector_ol),
 .posted_valid(vector_pv),.posted_ready(vector_pr),.posted_tag(vector_pt),.fault_npu(vfault),
 .axi_arvalid(carv[1]),.axi_arready(carr[1]),.axi_araddr(cara[1]),.axi_arlen(carl[1]),.axi_aruser_id(cari[1]),.axi_aruser_ap(carap[1]),
 .axi_rvalid(rv_q[1]),.axi_rdata(rdata_q),.axi_rlast(rlast_q),.axi_rid(rid_q),
 .axi_awvalid(cawv[1]),.axi_awready(cawr[1]),.axi_awaddr(cawa[1]),.axi_awlen(cawl[1]),.axi_awuser_id(cawi[1]),.axi_awuser_ap(cawap[1]),
 .axi_wdata(wd[1]),.axi_wstrb(ws[1]),.axi_wready(wr[1]),.axi_wusero_id(axi_wusero_id),.axi_wusero_last(axi_wusero_last),.read_bytes_ui(),.write_bytes_ui(),.credit_stalls_ui(),.useful_write_bytes_ui(),.write_bursts_ui(),.full_bursts_ui(),.idle_flushes_ui());
wire package_rdv,package_rdr,package_rv,package_rr,package_rl,package_re;
 wire[31:0]package_ra;wire[4:0]package_rn;wire[255:0]package_data;
 wire package_ov,package_ore,package_ol,package_pv,package_pr;wire[31:0]package_oa,package_os,package_ot,package_pt;wire[255:0]package_od;
wire host_rdv,host_rdr,host_rv,host_rr,host_rl,host_re;
 wire[31:0]host_ra;wire[4:0]host_rn;wire[255:0]host_data;
 wire program_selected=PROGRAM_CACHE&&program_owner;
 assign package_rdv=program_selected?program_rd_valid:host_rdv;
 assign package_ra=program_selected?program_rd_address:host_ra;
 assign package_rn=program_selected?program_rd_beats:host_rn;
 assign package_rr=program_selected?program_r_ready:host_rr;
 assign host_rdr=!program_selected&&package_rdr;assign program_rd_ready=program_selected&&package_rdr;
 assign host_rv=!program_selected&&package_rv;assign program_r_valid=program_selected&&package_rv;
 assign host_data=package_data;assign program_r_data=package_data;
 assign host_rl=package_rl;assign program_r_last=package_rl;
 assign host_re=package_re;assign program_r_error=package_re;
package_cpu_bridge #(.WRITE_READBACK(0)) package_bridge(.arst(package_arst),.cpu_clk(cpu_clk),.npu_clk(npu_clk),.bus_valid(bus_valid&&sel==2),.bus_write(bus_write),.bus_addr(bus_addr),
 .bus_wdata(bus_wdata),.bus_wstrb(bus_wstrb),.bus_ready(br[2]),.bus_error(be[2]),.bus_rdata(bd[2]),.rd_valid(host_rdv),.rd_ready(host_rdr),.rd_addr(host_ra),.rd_beats(host_rn),
 .r_valid(host_rv),.r_ready(host_rr),.r_data(host_data),.r_last(host_rl),.r_error(host_re),
 .out_valid(package_ov),.out_ready(package_ore),.out_addr(package_oa),.out_strb(package_os),.out_tag(package_ot),.out_data(package_od),.out_last(package_ol),
 .posted_valid(package_pv),.posted_ready(package_pr),.posted_tag(package_pt),.transport_fault(pfault),.fault(rwfault));
assign bi[2]=0;
hmic_layout_cdc #(.TIMEOUT_CYCLES(4000000)) package_transport(.arst(package_transport_arst),.npu_clk(npu_clk),.ddr_clk(ddr_clk),.ddr_init_done(ddr_init_done),
 .rd_valid(package_rdv),.rd_ready(package_rdr),.rd_addr(package_ra),.rd_beats(package_rn),
 .r_valid(package_rv),.r_ready(package_rr),.r_data(package_data),.r_last(package_rl),.r_error(package_re),.in_valid(package_ov),.in_ready(package_ore),.in_addr(package_oa),.in_data(package_od),.in_strb(package_os),.in_tag(package_ot),.in_last(package_ol),
 .posted_valid(package_pv),.posted_ready(package_pr),.posted_tag(package_pt),.fault_npu(pfault),
 .axi_arvalid(carv[2]),.axi_arready(carr[2]),.axi_araddr(cara[2]),.axi_arlen(carl[2]),.axi_aruser_id(cari[2]),.axi_aruser_ap(carap[2]),
 .axi_rvalid(rv_q[2]),.axi_rdata(rdata_q),.axi_rlast(rlast_q),.axi_rid(rid_q),
 .axi_awvalid(cawv[2]),.axi_awready(cawr[2]),.axi_awaddr(cawa[2]),.axi_awlen(cawl[2]),.axi_awuser_id(cawi[2]),.axi_awuser_ap(cawap[2]),
 .axi_wdata(wd[2]),.axi_wstrb(ws[2]),.axi_wready(wr[2]),.axi_wusero_id(axi_wusero_id),.axi_wusero_last(axi_wusero_last),.read_bytes_ui(),.write_bytes_ui(),.credit_stalls_ui(),.useful_write_bytes_ui(),.write_bursts_ui(),.full_bursts_ui(),.idle_flushes_ui());
hmic_owner3 ownership(.clk(ddr_clk),.rst(fabric_arst),.fault(arb_fault),
 .sv_arvalid(arv),.sv_arready(arr),.sv_araddr({ara[2],ara[1],ara[0]}),.sv_arlen({arl[2],arl[1],arl[0]}),.sv_arid({ari[2],ari[1],ari[0]}),.sv_arap(arap),
 .sv_rvalid(rv),.sv_rdata(),.sv_rlast(),.sv_rid(),
 .sv_awvalid(awv),.sv_awready(awr),.sv_awaddr({awa[2],awa[1],awa[0]}),.sv_awlen({awl[2],awl[1],awl[0]}),.sv_awid({awi[2],awi[1],awi[0]}),.sv_awap(awap),
 .sv_wdata({wd[2],wd[1],wd[0]}),.sv_wstrb({ws[2],ws[1],ws[0]}),.sv_wready(wr),.sv_wid(),.sv_wlast(),
 .arvalid(axi_arvalid),.arready(axi_arready),.araddr(axi_araddr),.arlen(axi_arlen),.arid(axi_aruser_id),.arap(axi_aruser_ap),
 .rvalid(axi_rvalid),.rdata(axi_rdata),.rlast(axi_rlast),.rid(axi_rid),
 .awvalid(axi_awvalid),.awready(axi_awready),.awaddr(axi_awaddr),.awlen(axi_awlen),.awid(axi_awuser_id),.awap(axi_awuser_ap),
 .wdata(axi_wdata),.wstrb(axi_wstrb),.wready(axi_wready),.wid(axi_wusero_id),.wlast(axi_wusero_last));
endmodule
