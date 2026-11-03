# 构建与运行

以下命令均在代码包根目录执行，示例中的工具路径按本机安装位置替换。

## 环境准备

| 用途 | 环境 |
|---|---|
| 上板与实现 | Windows x64，PDS 2025.2 build 211867，PG2L200H 器件库、Fabric 工具及有效许可证 |
| 网页与图像源 | Python 3.11/3.12，Tkinter，`requirements.txt` 中的依赖 |
| 固件编译 | 人脸应用 WCH GCC 12；QO 默认固件及 CM 为 WCH GCC 15.2；QO 优化固件为 GCC 16.1 |
| 主机测试 | Python，Node.js |
| RTL 测试 | Icarus；完整应用仿真另需支持 SystemVerilog timing 的 Verilator、C++20 编译器及 PDS 仿真库 |

建议解压到较短的英文路径，例如 `D:\FPGA_Face`。安装 Python 依赖并核对文件：

```powershell
python -m pip install -r requirements.txt
python tools/verify_package.py
```

## 上板演示

### 1. 接线与下载

开发板接好电源、JTAG 下载器和底板 UART USB。HDMI 连接方向为“电脑 HDMI 输出 → 开发板 HDMI IN”。下载前在旧控制台结束任务、释放图像并断开串口。

```powershell
python tools/program_sram.py --pds-bin "PDS目录/bin" --target QO --program
```

脚本检查器件及温度状态后下载位流，并建立本次会话的串口序号记录。此方式写入 FPGA SRAM，掉电后重新下载；会话记录由程序自动维护。

### 2. 启动控制台

```powershell
python -B 04_host/console/serve.py
```

浏览器打开 `http://127.0.0.1:8783/`，选择开发板 COM 口并连接。点击“装载模型”，随后登记人员。模型驻留在 DDR 中，连续识别直接复用；人员信息和模板保存在 `runtime/data`。

### 3. 设置 HDMI 图像源

在 Windows 中选择扩展显示，将 FPGA 对应的显示目标设为 640×480，然后运行：

```powershell
python -B 04_host/display/show_source.py
```

保留一个图像源窗口。控制台可选择图片，也可打开电脑摄像头。点击“开始连续识别”后，网页显示板端返回的人脸框、人员信息和识别结果。主画面对应已完成识别的图像，预览区显示实时输入。

结束演示时点击暂停，等待本帧结果释放，再断开连接。

## 固件构建

以人脸应用为例：

```powershell
python tools/build_firmware.py face_application --cc "工具链/bin/riscv-wch-elf-gcc.exe"
```

| 构建目标 | 内容 |
|---|---|
| `face_application` | QO 人脸应用固件 |
| `coremark_QO_default` | 控制台默认 CoreMark 固件 |
| `coremark_QO_GCC16` | QO GCC 16 优化固件 |
| `coremark_CM_normal` | CM CoreMark 正常测试 |
| `coremark_CM_validation` | CM CoreMark 验证测试 |

精确编译参数保存在各目录的 `command.json`，输出写入新建的 `build` 子目录。脚本将重编译 ELF 的分配段与配套预编译固件比较，并报告差异。人脸 ROM 与 ELF 的对应信息见 `FIRMWARE_IDENTITY.json`。CM 的 UART 引导程序位于 `02_firmware/CM_boot`，负责接收并启动上传到 RAM 的测试程序。

赛题列出的工具链名称为 `riscv32-unknown-elf-gcc`，测试程序为 CoreMark v1.0；本包使用的发行版、命令前缀及 RV32/ILP32 参数均记录在固件目录。测量时分别运行正常和验证测试，每轮持续至少 10 秒并核对 CRC。

## PDS 工程

生成 QO 工程：

```powershell
python tools/prepare_pds.py QO
```

将 `QO` 改为 `CM` 可生成独立 CPU 工程。脚本输出新工程目录，在该目录依次执行：

```powershell
powershell -File run_stage.ps1 -PdsBin "PDS目录/bin" -Stage 01_synthesis
powershell -File run_stage.ps1 -PdsBin "PDS目录/bin" -Stage 02_mapping
powershell -File run_stage.ps1 -PdsBin "PDS目录/bin" -Stage 03_placement
```

每个阶段完成后查看成功标记及工具报告。`01_hardware/QO/physical_reference` 保存有限 CDC 约束、skew 约束和物理组织参考。源码重新映射后，按实际单元、时钟和端点更新约束，再继续布线和最终 STA。

包内还保存了已布线数据库 `08_bitstreams/<版本>/routed.adf`。在生成的工程目录执行以下阶段，可直接复核原实现或重新导出位流：

| 阶段名 | 操作 |
|---|---|
| `timing_max` | 最大延迟时序分析 |
| `timing_min` | 最小延迟时序分析 |
| `export_existing` | 从已布线数据库导出位流 |

这些入口使用配套的 PDS 2025.2 build 211867。位流导出设置为 SCBV High Voltage、启用 CRC、写入 DRM 初始化。`08_bitstreams` 中的 `.sbit` 与 `.fic` 为配套文件。

## 测试命令

主机测试使用模拟板对象：

```powershell
python -B tools/test_host.py
node 05_tests/host/test_metrics56.js
```

命令与结果接口 RTL 测试：

```powershell
python tools/test_rtl.py --iverilog "路径/iverilog.exe" --vvp "路径/vvp.exe"
```

完整应用仿真：

```powershell
python tools/full_application.py --verilator "路径/verilator_bin.exe" --verilator-root "路径/share/verilator" --cxx "路径/g++.exe" --pango-lib "PDS路径/arch/vendor/pango/verilog/simulation" --run
```

去掉 `--run` 可仅编译仿真程序。该测试依次执行五次固定图人脸任务、三次 CoreMark 短测，再返回人脸任务，并覆盖任务编号回绕。DDR 模型延迟设置为 40 拍，用于功能及同条件周期对照；实际帧率以实板连续任务测量为准。
