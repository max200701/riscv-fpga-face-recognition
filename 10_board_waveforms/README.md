# 实板逻辑分析波形

采集日期：2026-11-02。使用 PDS Fabric Debugger，通过 JTAG 读取 FPGA 内的逻辑分析核。

## 采样内容

| 目录 | 测试内容 | 窗口数 | 采样时钟 |
|---|---|---:|---:|
| `CM/coremark` | 独立 CPU 的 CoreMark 流水与退休 | 3 | 162.5 MHz |
| `QO/coremark` | 人脸整机 CPU 的 CoreMark 执行 | 3 | 31.25 MHz |
| `QO/diagnostics/test1` | 缓存冲突访问 | 2 | 31.25 MHz |
| `QO/diagnostics/test2` | ECALL、非法指令、软件中断和定时器中断 | 2 | 31.25 MHz |
| `QO/diagnostics/test3` | 条件分支及队列控制 | 2 | 31.25 MHz |
| `QO/diagnostics/test4` | CPU 外设 MMIO 访问 | 2 | 31.25 MHz |
| `QO/face` | 特征归一化与模型调度 | 2 | 31.25 MHz |

共 16 个窗口，每个窗口连续采样 2048 拍。CM 采样宽度为 138 位，QO 为 136 位。采样信号包含 PC、发射、退休、访存握手、队列状态和计数器，信号分组见 `probes`。

## 文件格式与打开方法

| 文件 | 用途 |
|---|---|
| `capture.dprj` | PDS Fabric Debugger 原生工程，保存采样和显示配置 |
| `wave.txt` | PDS 原始数值导出，每行一个采样点，数值为十六进制 |
| `wave.vcd` | PDS 原始波形导出 |
| `physical_time.vcd` | 按实际 CPU 周期标定时间轴的波形，便于查看物理时间 |
| `samples.csv` | 按信号名称展开的采样表，含字节地址和退休计数变化 |

在 PDS Fabric Debugger 中打开 `capture.dprj` 即可查看原生采样。需要指定调试配置时，选择 `08_bitstreams` 中对应 CM 或 QO 的 FIC。

使用支持 VCD 的波形查看器时，推荐打开 `physical_time.vcd`。PDS 原始 VCD 的刻度为 100 ns；时间标定版采用 1 ps 单位，QO 每拍 32 ns，CM 每拍约 6.153846 ns，两份文件的采样值一致。

双击 [index.html](index.html) 可查看技术报告中的八张波形图。`INDEX.json` 列出每张图对应的采样文件、起始序号和信号名称。人脸应用组记录的是 CPU 执行特征归一化与模型调度时的状态。

## 程序与位流

CoreMark 和人脸应用的配套固件位于 `02_firmware`，专项测试源程序及 ELF 位于本目录的 `firmware/diagnostics`。各组对应的位流、FIC 和 ELF 校验值记录在 `INDEX.json`。

在代码包根目录执行以下命令，可核对原始 TXT、VCD、CSV 与时间标定波形的采样值：

```powershell
python tools/verify_waveforms.py
```
