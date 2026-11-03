# RISC-V CPU 与 FPGA 人脸识别系统

本项目在紫光同创 PG2L200H FPGA 上实现 RISC-V CPU 与人脸识别加速系统，支持 HDMI 图像输入、人员登记、连续识别和网页结果显示。

提交版本为 2026-11-03。人脸识别工程采用 QO DEBUG136，配套 QO92 上位机；独立高频 CPU 工程 CM 用于 CoreMark 测试。

## 下载与文档

- [完整提交包 v3（RAR，72.56 MB）](https://github.com/max200701/riscv-fpga-face-recognition/releases/download/v2026.11.03-qo-debug136/FPGA_RISCV_Face_20261103_v3.rar)
- [使用说明](07_docs/BUILD_AND_RUN.md) · [系统架构](07_docs/ARCHITECTURE.md) · [时序报告](07_docs/TIMING_REPORT.md)
- [实板波形说明](10_board_waveforms/README.md) · [波形图索引](10_board_waveforms/FIGURES.md)

源码也可直接克隆：

```powershell
git clone https://github.com/max200701/riscv-fpga-face-recognition.git
cd riscv-fpga-face-recognition
```

## 快速开始

1. 按 [构建与运行](07_docs/BUILD_AND_RUN.md) 安装依赖并连接开发板。
2. 使用 `08_bitstreams/QO` 中的位流下载到 FPGA SRAM。
3. 启动网页控制台，装载模型，登记人员后开始识别。

包内附有可直接使用的位流和已布线数据库，也提供从源码构建的入口。

## 硬件与模型

| 项目 | 配置 |
|---|---|
| FPGA | PG2L200H-6IFBG676；PDS 选择 Logos2 / PG2L200H / -6 / FBB676 |
| 核心板 / 底板 | MES2L676-CORE-V1.4 / MES-PG2L676-Mini Base-V1.0 |
| CPU | 双取指、双退休 RV32IM，31.25 MHz |
| NPU / DDR 用户时钟 | 125 MHz / 125 MHz |
| 管理与测温基准 | 27 MHz |
| 检测模型 | RetinaFace，640×480 输入 |
| 识别模型 | w600k_mbf，112×112 输入 |
| 数值格式 | INT8、INT12、Q16；定点舍入与饱和，特征两次 L2 归一化 |

电脑负责摄像头或图片输入、HDMI 画面发送、模型和图库装载、结果显示。人脸检测、NMS/FIT、裁剪对齐、特征提取及图库匹配在 FPGA 内完成。首次使用时在控制台登记人员，图库保存在本地 `runtime/data`。

## 目录

```text
riscv-fpga-face-recognition/
├── 01_hardware/QO/          # CPU、NPU、DDR、HDMI、UART、测温与约束
│   ├── rtl/                # 整机功能模块
│   ├── ip/                 # 厂商 DDR 控制器与 PHY
│   ├── hdmi_rx/            # HDMI 接收配置
│   └── physical_reference/ # CDC 与物理组织参考
├── 02_firmware/            # 人脸应用、引导程序和各版 CoreMark
├── 03_models/              # RetinaFace、w600k_mbf 部署文件
├── 04_host/
│   ├── console/            # 网页控制台与串口协议
│   ├── display/            # HDMI 扩展屏图像窗口
│   └── source/             # 图片与摄像头输入处理
├── 05_tests/               # 主机测试、RTL 接口和完整应用仿真
├── 06_cpu_coremark/CM/     # 独立 162.5 MHz CPU 工程
├── 07_docs/
│   └── timing/QO/          # 布线后时序摘要及原始报告
├── 08_bitstreams/          # QO/CM 位流、FIC 与路由数据库
├── 09_licenses/            # 第三方组件许可
├── 10_board_waveforms/
│   ├── CM/coremark/        # CM 原始采样
│   ├── QO/coremark/        # QO 原始采样
│   ├── QO/diagnostics/     # 缓存、异常、中断、分支、MMIO 测试
│   ├── QO/face/            # 人脸应用 CPU 采样
│   └── figures/            # 技术报告中的八张波形图
├── tools/                  # 构建、下载、校验和测试入口
├── README.md
└── SHA256SUMS.json
```

| 目录 | 内容 |
|---|---|
| `01_hardware/QO` | 整机 RTL、DDR IP、HDMI、UART、测温、时钟复位、约束及调试配置 |
| `02_firmware` | 人脸应用、引导程序、CoreMark 源码、链接脚本、构建参数及预编译固件 |
| `03_models` | 模型权重、参数包、执行指令及装载信息 |
| `04_host` | 网页控制台、电脑图像源、HDMI 显示窗口和串口协议 |
| `05_tests` | 主机测试、RTL 测试、完整应用仿真及 219 份逐层数值参考 |
| `06_cpu_coremark/CM` | 独立 162.5 MHz CPU 测试工程，与 QO 分别下载使用 |
| `07_docs` | 使用说明、架构说明、测试结果和时序报告 |
| `08_bitstreams` | QO、CM 位流，配套 FIC 及已布线数据库 |
| `09_licenses` | 第三方组件来源与许可证 |
| `10_board_waveforms` | 实板逻辑分析原始数据、报告波形图和采样说明 |
| `tools` | 文件校验、固件构建、PDS 工程生成、SRAM 下载和测试脚本 |

各工程使用自己的源文件列表：QO 综合顶层为 `mini_face_demo_top`，完整应用仿真顶层为 `demo_board_logic`，CM 顶层为 `cpu_perf_board`。

## 测试结果

QO 已完成固定图数值对照、CPU 结果提交与释放、连续运行实板测试。布线后双角 setup、hold、recovery、removal 八项检查全部通过，最小 setup 裕量为 +0.002 ns，最小 hold 裕量为 +0.038 ns。详细结果和接口覆盖范围见 [时序报告](07_docs/TIMING_REPORT.md)。

| CoreMark 测试配置 | CPU 时钟 | 工具链 | 分数 | CoreMark/MHz |
|---|---:|---|---:|---:|
| QO 优化固件，RV32IM | 31.25 MHz | GCC 16.1 | 207.521307 | 6.640681820 |
| CM 独立 CPU，含 Zbc 扩展 | 162.5 MHz | WCH GCC 15.2 | 902.700471 | 5.555079823 |

两组均通过超过 10 秒的正常测试及 CRC 校验。网页控制台默认使用 GCC 15 固件；QO 的 GCC 16 优化固件另存于 `02_firmware/coremark_QO_GCC16`。

更多资料：[系统架构](07_docs/ARCHITECTURE.md) · [构建与运行](07_docs/BUILD_AND_RUN.md) · [代码包验证结果](07_docs/PACKAGING_CHECKS.md)。

## 实板波形

原始采样与报告配图见 [实板逻辑分析波形](10_board_waveforms/README.md)。包含 16 个窗口的 TXT、VCD、DPRJ，以及技术报告中八张波形图的采样对应信息。

## 报告文件与许可

两份完整时序路径报告在仓库中以 `.xz` 保存。执行 `python tools/extract_timing_reports.py` 可还原原始 `.rtr`；Release 中的 RAR 已包含原始文件。摘要、代码、模型、位流和波形可直接使用。

项目自有代码采用 [MIT 许可](LICENSE)，第三方组件遵循各自的[许可说明](09_licenses/THIRD_PARTY.md)。版本记录见 [CHANGELOG.md](CHANGELOG.md)。
