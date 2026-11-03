# 系统架构

系统由电脑图像源、FPGA 人脸识别系统和网页控制台组成。电脑通过 HDMI 向开发板发送图像，通过串口装载模型、管理图库和读取结果；识别计算由 FPGA 内的 RISC-V CPU 与 NPU 协作完成。

## 一帧图像的处理过程

```text
电脑摄像头 / 图片
        ↓ HDMI
图像接收与 RGB 采集 → DDR 帧缓冲
        ↓
RetinaFace 人脸检测（NPU）
        ↓
候选解码、NMS、FIT 参数计算（CPU）
        ↓
人脸裁剪与对齐（硬件 warp）
        ↓
w600k_mbf 特征提取（NPU）
        ↓
两次 L2 归一化、图库匹配、阈值判断（CPU）
        ↓
结果提交 → UART 返回摘要 → 网页显示
        ↓
图像释放，进入下一帧
```

## 模块分工

CPU 执行应用程序，负责调度、检测后处理、图库匹配和结果提交。NPU 执行量化卷积、深度卷积、逐元素计算、转置及量化尾处理。warp 单元根据 CPU 计算的变换参数生成 112×112 识别输入。

DDR 保存模型、输入图像和中间结果。各模块通过统一写出接口访问物理写通路，以写入完成应答和帧槽编号管理数据交接；下游繁忙时由背压控制暂停上游。温度采样和保护逻辑独立运行。

电脑侧的 OpenCV 用于图像解码、缩放和补边。显示的人脸框、特征匹配结果来自 FPGA；离线仿真另用参考数据核对计算结果。

## 主要源码

| 子系统 | 主要源码（位于`01_hardware/QO/rtl`，除另有说明） |
|---|---|
| CPU | `rv32_core.v`、`rv32_alu.v`、`rv32_muldiv.v`、`rv32_regfile.v`、`cpu_soc.v` |
| 缓存与程序存储 | `rv32_icache.v`、`rv32_dcache.v`、`boot_rom_dp.v`、`sync_ram.v` |
| CPU/NPU调度 | `cpu_npu_queue.v`、`graph_mmio_dma_sequencer.v`、`graph_mmio_sequencer.v`、`package_cpu_bridge.v` |
| DDR与跨域 | `demo_hmic_client.sv`、`demo_hmic_bridge.sv`、`hmic_*`、`joint_async_fifo.v`、`ip/`厂商DDR控制器/PHY |
| 操作数供数 | `conv_window_source.v`、`native_panel_loader.v`、`paired_operand_store.v`、`panel_operand_store.v` |
| 计算阵列 | `mac_array_fold16.v`、`dual_int8_mac*.v`、`panel_compute.v`、`partial_sum_store.v` |
| 数值尾处理 | `quant_stream16.v`、`requant_stream4.v`、`graph_linear_stream.v`、`graph_elementwise4.v`、`graph_transpose_stream.v` |
| 对齐 | `retina_warp_q16.sv`、`retina_warp_normalize.v`、`warp_coordinates_pinned.sv`、`warp_bilinear_new.sv` |
| 写回与帧生命周期 | `tile_writeback4.v`、`pp_writer_mux.sv`、`pp_video_session.sv`、`demo_result_store.sv` |
| UART、协议、模型与图库资格 | `po_uart_domains.sv`、`demo_packet_endpoint.sv`、`demo_model_residency.sv`、`demo_gallery_residency.sv` |
| HDMI | `hdmi_rx/`、根目录`oj_ms7200_table.vh`、`demo_video_q16_writer.sv` |
| 温度 | `adc_temperature_reader.v`、`logos2_temperature_adc.v` |
| 系统顶层 | 根目录`mini_face_demo_top.sv` |


实际文件列表见各工程的 `sources.json`。主机端分别显示最近完成窗口的平均帧率和最后一帧间隔，主画面与对应的板端结果同步更新。
