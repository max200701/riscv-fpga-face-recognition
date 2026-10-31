# QG 外部依赖逐文件清单

由 external_files.json 生成；表内文件未随仓库发布。放置后使用 check_dependencies.py 校验。获取渠道见 THIRD_PARTY.md。

| 目标路径 | 字节 | SHA-256 | 原因 |
|---|---:|---|---|
| `hardware/ip/mini_ddr.v` | 22194 | `cfc34cd4419680a89b6ee093e991886e4ce0d251d4ff2a857e01463aaed35347` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/mini_ddr_ddrphy_top.v` | 53204 | `503a019dab8fa9bfe254bbd3d6cdd405986486544f807a5cdd0c427cd8b53e32` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ips2l_rst_sync_v1_3.vp` | 3024 | `64b8d83f15f2ff373e6b1040405c42051d8761bd1857dec719c884c2eb59361a` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_calib_mux_v1_0.vp` | 13948 | `676e36319e7ce80b93e3543e255d53708d9fc71606587a6e692eab1ec82ecaed` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_calib_top_v1_10.vp` | 29035 | `04faf434cef120b5d712911dfc97c8f498901b0679fba720b806f596d688bded` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_control_path_adj_v1_10.vp` | 8870 | `8cdd7b9ec01c143882217b038cbf840d77e52ee3037e629e75e10b03fc223a38` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_cpd_ctrl_v1_3.vp` | 12614 | `56f52683adbe720c7d43da1a9f199f4ab3add3f3b5960e3f687f87f60267c161` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_cpd_lock_v1_0.vp` | 3988 | `a6696f8e79e2d132a6e76ad4997d5366d6c9cf8f05c60f77feff1b47b50d0090` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_data_slice_dqs_gate_cal_v1_10.vp` | 7140 | `8764275d4eeb8d1765b3a09aba527d6d3bf3e46f5e1d17eefc685d7e0dbe1520` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_data_slice_v1_10.vp` | 43859 | `e13e33d97ecbfea1838c4dd28e7f9f1c57dcb974606179523be46bba75344d50` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_data_slice_wrcal_v1_10.vp` | 20167 | `b7a9757c252f74c4b57eb0fb74738c57e4eed3e669ddd7ffeeca1acedd330b2e` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_data_slice_wrlvl_v1_10.vp` | 21219 | `871874f4af0f068571416916898f83eb07052e6e015c5800ffdf65d67620cf7e` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_dfi_v1_3.vp` | 23431 | `9828a1ef43a864d287a7a317910fe330bfc904f44e8f60c8773aafa1d8c1534e` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_dll_update_ctrl_v1_3.vp` | 8102 | `bc4e8f402d2fb98920e050a3c1514d44ec959877217d7865a30b22b7da73cac6` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_dqsi_rdel_cal_v1_3.vp` | 29297 | `ef7e57755ab7558b1b518aa73999384368f349efe7077cf9283e0911e711ac1a` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_dqs_gate_coarse_cal_v1_0.vp` | 11936 | `950a0010929854894c2c92d9f3f8e9dce0fee6985fee70d4160540a058853ede` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_dqs_rddata_align_v1_10.vp` | 39545 | `c0cab4287a7a7b6b720977c1c5f9259c5f48f8da18e9a3ca1173a073b1ccf025` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_drift_ctrl_v1_0.vp` | 7226 | `8ea99ac6decf6fe14c0585b4f121d7a1acc17290d7a1c68725d984e704e277bc` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_eyecal_v1_5.vp` | 16271 | `31977dd34339d163ecbd8b9949ac4b65f0eaa6fbcd9a75d787400ae73f7f51d2` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_gatecal_v1_10.vp` | 17323 | `b6859250ca098e81ff05bcab08dfe8ffee77648218e90c040a1dd3838a0671f2` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_gate_update_ctrl_v1_3.vp` | 6262 | `ce20eb3b9cbe3b392d8be0aa1d6787247bc7b2d91af36a1f734f35c9eb03d642` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_gpll_phase_v1_0.vp` | 3812 | `ef8ebe3742d23848bd2a1492d4901f886ce49aa98dbc295873b67e4116ba8524` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_info_v1_0.vp` | 12042 | `0794201be97885e7695a16b6c35848655b08c4bf191405d26417126512ce4aa8` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_init_v1_0.vp` | 43375 | `817f9f32b2260a4c35af446e89ff4c2d4b065381b25cb2020c538d22b4a45088` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_main_ctrl_v1_10.vp` | 13750 | `39d5024d7364b441340b131d265d0648d8b7c1f92cc417424d7c584413c5f4a6` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_rdcal_v1_10.vp` | 56971 | `6b4c7f3c24a4750ac69b4e7882617105c6e31f02da712aaa87932b8561ccea2b` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_reset_ctrl_v1_3.vp` | 19445 | `17189b59ed5307c4a27ec35485b33af5c98a89e6ee7f9c5d85aaed9c03a77163` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_rst_clk_phase_adj_v1_0.vp` | 7292 | `dd1dbae71726d968df475fe7fbb2b7321411fa67786092c0dc2e065edcf39382` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_rst_debounce_v1_0.vp` | 4580 | `bff7ed95c8d305dfb88e6002c6de8453a21c72c03a5a0521a76ddd105598dc4d` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_slice_rddata_align_v1_0.vp` | 6878 | `befb44f07d851524109a6dc8e17c5b8062694aa274ed8dbc4f7326b8fe1c443e` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_training_ctrl_v1_0.vp` | 4908 | `777e8ee9d8d819fdcf04b39b5a5d6086c52369a7f19f04dbd0d06f7a7d3d6110` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_upcal_v1_0.vp` | 10182 | `afbca3503da609f7951ad7fbef386bd007f403c89f52377211ba521967c94455` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_wdata_path_adj_v1_10.vp` | 16469 | `85f625ed4a09964442e8616074eea9e4757e43b4217589bb9e2f289c9748b272` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_wrcal_v1_7.vp` | 37069 | `0a8cb0bb70bd40809260c50bcb85d092c16fea5d9ab2e4fbbe647ccbd1bfb1b0` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/ips2l_ddrphy_wrlvl_v1_0.vp` | 12764 | `00c086bd729be3ab8287f6eb786cfb3549c97aa92f8465c608b8fc2477df3edc` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/ddrphy/mini_ddr_slice_top_v1_10.v` | 55690 | `79289273f592e16c7b89c5f36b79f6d6c62b7a8a0bc2e24658f568b969793d6d` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_apb_cross_v1_2.vp` | 9592 | `62f7d55354a8afe4d02bc6f6d6dc30fc8e9960d3b21709988b887acc99d09cf5` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_calib_delay_v1_2.vp` | 6590 | `a52e992b9766b6cb22ed23aa01d1cc5ac9b6a429a8e49de7a13ac51dd70e9784` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_cfg_apb_v1_2.vp` | 42389 | `482cb280a614f70209f1d07892fdd773a259d2ca0f23e8f38b85a9faf00513b9` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_dcd_bm_v1_2.vp` | 17651 | `bfbd472dd8b427fe6b003dd510f73db89f915ac92d31fe8a779c40f9d4e56bee` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_dcd_rowaddr_v1_2.vp` | 4580 | `4ac4721747b13020e1895be6265e55df90968f05beb8056279589039394bb9be` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_dcd_sm_v1_2.vp` | 15064 | `d7e710e3ed4d1807fb0bdd4d84c264817247a4da41123c72439c555573821f49` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_dcd_top_v1_2.vp` | 12330 | `26ab4e142f555602c023f62b19df52056c6d51da5052401254066cae0655ddaa` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_dcp_back_ctrl_v1_2.vp` | 48957 | `fe7b340b41d80ec7428cc38329a41864bcf5c209a6310610d09c7bc8579e541f` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_dcp_buf_v1_2.vp` | 22007 | `dab35fa172243ecbb5426a8ebccc2c168368ea0a6ea0558c909b815d781b17d6` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_dcp_out_v1_2.vp` | 15064 | `9471082e23170b144dc619f7f7e08c94b8a03378f72da388f744d6acb728928b` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_dcp_top_v1_2.vp` | 24371 | `21b1f0e3b4660e1078b47000bfe50022346414f5d5e713ac9e522a4f39f76548` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_dfi_v1_2.vp` | 32495 | `abf138d692e634fabe5f569b98d897dfece8a8ae66cee1dba830a56d7e255df1` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_lp_v1_2.vp` | 23123 | `7a80ccb1e053e5c9d8f389169359570f256d709ff2e4ad2c51fda7a7a6a4239d` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_mrs_v1_2.vp` | 23735 | `f78133bc021a57cf469773daaf102817fc37069447e8accc80afa1f4b20b0ad6` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_prefetch_fifo_v1_2.vp` | 6044 | `ee3aa91e980fb3dd08231cf1806a28edf759f4ea8248adfd44407d607519b9e4` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_rdatapath_v1_2.vp` | 5212 | `72dd8ece021f4ee74fd576c1628c4f7d3606ef632f0e68b9569a288a092a6b0f` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_reg_fifo2_v1_2.vp` | 4818 | `bc9cff65e4002a51af0c20c2f0a9b9f17dacde5157b58691bbfb1c44348ee08a` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_ui_axi_v1_2a.vp` | 19885 | `145b69395412be2553835f9278cdf1cb1703d3beeb914abf7d985e3c69f817fb` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_wdatapath_v1_2.vp` | 11760 | `db648e90ff607ca2f9e2b5cca048de417439888d0b906288e0cec7cf038d9dee` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_wdp_align_v1_2.vp` | 9722 | `1645e9eb7fac3c9c13cd3e0d7367f132293f9cec16835ce188c6345993d2b730` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_wdp_dcp_v1_2.vp` | 9132 | `3f30be0f49f78f09915743995c950fa6ff8de5f14598ebc8802e73b5c6d140ee` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/ips2l_mcdq_wrapper_v1_2b.vp` | 47013 | `d35010f49be551fb15ab2655cbeffcaaaa74fdf3ccb0754b033fc979d615e805` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/pll/ips2l_ddrphy_gpll_v1_3.vp` | 8324 | `3fecc367573a4b5bd158e1a8ff106c5c401c5f180143e8e5abe6bb068e5078d2` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/pll/ips2l_ddrphy_ppll_v1_0.vp` | 17323 | `34bb46106b84eab147f130bd7526f1486d35caeb40b0258cd59656e50d19dddd` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/distributed_fifo/ips2l_distributed_fifo_v1_0.vp` | 7838 | `d6c0b0d8560b0f22128b4883933944fc686fd7597cfea0d6c545cc6af56c0b7a` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/syn_mod/ips2l_mcdq_com_timing_v1_2.vp` | 6636 | `e3f19c4be6352ab64f07426973387f2876c540ee992f6eac9d3f2d470b3d49c2` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/syn_mod/ips2l_mcdq_tfaw_timing_v1_2.vp` | 8738 | `c632619f042bebb4f059df7f20eee90eb2b51b81210430cb37d01958ad3cd30f` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/syn_mod/ips2l_mcdq_tfaw_v1_2.vp` | 4074 | `ab87b7718bffc4fb2a2b27765576187f09b5266bbca7fc393c43c6dec96ff379` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/syn_mod/ips2l_mcdq_timing_act2wr_pass_v1_2.vp` | 7642 | `1b3874b059923481f292ba382ad156f7dcdd9ad39da6c86dddd480290ccce498` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/syn_mod/ips2l_mcdq_timing_act_pass_v1_2.vp` | 5892 | `9f32b6936e039c15f7b07b74480179d39d1b3787965e1b90bd067a7ede7fdd4c` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/syn_mod/ips2l_mcdq_timing_pre_pass_v1_2.vp` | 10248 | `e40a64caec9725c231cd88dde69973eab3aca38c9d2e66a2c5c0bbddf3103ae0` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/syn_mod/ips2l_mcdq_timing_rd_pass_v1_2.vp` | 8652 | `78b1de719a43ee0fc80e1a5464f7284439d91f1d4b3f83ef2ae5611920293988` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/syn_mod/ips2l_mcdq_timing_ref_pass_v1_2.vp` | 5672 | `c79dde6f9a682c55aff7bb89c4863f76a069b874fb154dff7d3e4d4a7a88f9d1` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/syn_mod/ips2l_mcdq_timing_wr_pass_v1_2.vp` | 8626 | `ea3470ca984554d4908ec950314f9242042417c6c4c6b3fd05ac5d6daab98c90` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/syn_mod/ips2l_mcdq_trc_timing_v1_2.vp` | 10424 | `7234241e5968f91ec6e396794f0bb80f6c7d1bca2038aa004d5078d3937953da` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/distributed_fifo/rtl/ips2l_distributed_fifo_ctr_v1_0.vp` | 18809 | `fe31c8f44bea653ab20bb1830ad4f8ed41566e9cfef354bd5e2d48c7682f353d` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/distributed_fifo/rtl/ips2l_distributed_fifo_v1_0_distributed_fifo_v1_0.vp` | 7708 | `867ac91a1485dfe613a81f372d788e784bba8cd4b0497e56986135e92685ba73` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/ip/rtl/mcdq_ctrl/distributed_fifo/rtl/ips2l_distributed_sdpram_v1_0_distributed_fifo_v1_0.vp` | 6854 | `3561bbbbd4e4432a538c3d20818d262b4f1e5517c48296f6b1b4cc8afdd19aef` | Pango proprietary/generated DDR IP; obtain under the vendor licence |
| `hardware/oj_ms7200_table.vh` | 9755 | `668797588946f3b6386cdc6b5f6b2cb44d1a7c571039f93e1fcb3cc5521de3b7` | HDMI reference table provenance/redistribution reviewed separately; not under project MIT |
| `hardware/hdmi_rx/oj_ms7200_table.vh` | 9755 | `668797588946f3b6386cdc6b5f6b2cb44d1a7c571039f93e1fcb3cc5521de3b7` | HDMI reference table provenance/redistribution reviewed separately; not under project MIT |
| `hardware/application_rom.hex` | 163840 | `23b538040bea9f1d41d59f1587d0acff22bbcbf3b15a6c6d9ba4e34bf1a28842` | Generated firmware ROM; rebuild from included C/assembly and exact external libgcc |
| `external/libgcc_rv32im_ilp32.a` | 2581436 | `319ebf6a066967b5d676773a4acb1faf53003bb34e00f1e400d10a5edfa7429f` | Exact GCC runtime dependency; not silently replaced by another toolchain runtime |
| `external/coremark/coremark.h` | 4547 | `d3031335e6e1b5e05d07681357e8e00a70ab60b0524b92d088e546c0ff7f56d6` | EEMBC upstream dependency, preserve upstream licence separately |
| `external/coremark/core_list_join.c` | 15147 | `1c8aa83861634d6a33cb11c785b738ac205404e2e9222571465dc02156f9154d` | EEMBC upstream dependency, preserve upstream licence separately |
| `external/coremark/core_main.c` | 12859 | `eaffa2c0ec253d25a348d24ea16ead8d439c1110ad636d7cddbb15efb9e1caf1` | EEMBC upstream dependency, preserve upstream licence separately |
| `external/coremark/core_matrix.c` | 8405 | `acf3fe63db2ddd929f405b67fd273e49f558871f0bf8d51a6814cdd881b602c8` | EEMBC upstream dependency, preserve upstream licence separately |
| `external/coremark/core_state.c` | 7463 | `02a6e604d852a2806a8eb2a455c924b0483a8042cfe96478009821558cf35521` | EEMBC upstream dependency, preserve upstream licence separately |
| `external/coremark/core_util.c` | 5381 | `f8479f7a4e100ded31e2ebecf1f37ffff8904d88314188b0a85d32687e3ca813` | EEMBC upstream dependency, preserve upstream licence separately |
| `external/coremark/cvt_barebones.c` | 1950 | `4a1e090efe0cb6b4c6b10cb9f9b3c2348fbdf85114a58ade4aed1c0108fd7210` | EEMBC upstream dependency, preserve upstream licence separately |
| `external/coremark/ee_printf_barebones.c` | 14281 | `67140f256dbe05f47d8129233c7dd4ee08f29308903963b532968ea2d66e51f3` | EEMBC upstream dependency, preserve upstream licence separately |
| `external/coremark/LICENSE.md` | 9460 | `2e56cf9d95872517dd5eaf58dcba75e9da54927c5201f8aeac005e55d270e602` | EEMBC upstream dependency, preserve upstream licence separately |
| `external/coremark/README.md` | 19192 | `e79d28bf5ede365816c409ccf6eca5ae8040f1c7016530aee206d1d0e40ce1fa` | EEMBC upstream dependency, preserve upstream licence separately |
| `external/models/model0_package.snpkg` | 549722 | `44d90045c3a0914526ce1ede67a85d84a2031d5e80c8febd6413752383171bbd` | Model-derived payload; no redistribution under project MIT |
| `external/models/model0_assets.bin` | 3680000 | `430f83c0d396283c62ce7408ccbede34b0fd2b3b84cf5dd5391cdc4cbd62c704` | Model-derived payload; no redistribution under project MIT |
| `external/models/model0_program.bin` | 926784 | `9d9d2ba2ef2100341d9f4e51cc9e92568089e38538771ade8ffff9f770d49a59` | Model-derived payload; no redistribution under project MIT |
| `external/models/model1_package.snpkg` | 3617343 | `148ff21869996c70962401a6948d8ea717734cd655f4704743809d1e59240581` | Model-derived payload; no redistribution under project MIT |
| `external/models/model1_assets.bin` | 4630528 | `bf9d42f1bb04ffc665f587d75547e5bd4f7df9803e31581ccf5b14d0c3cdb40a` | Model-derived payload; no redistribution under project MIT |
| `external/models/model1_program.bin` | 256320 | `21f47e7394ffd6e139fe9892291da168587ccbc8cb817410281b9b6653c3a37f` | Model-derived payload; no redistribution under project MIT |
