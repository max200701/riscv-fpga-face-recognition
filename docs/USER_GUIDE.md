# QG 交付与使用指南

这份指南对应实际上板的 **QG 两网络 ECO 位流 + QB 功能 RTL + QG38 主机软件**。
不是 PX、QI 或 PDS2025 实验。先阅读本页，再按需要阅读 BUILD、HOST 和 EVIDENCE。

## 1. 先选择要做的事情

| 目的 | 本公开仓库现在能做到什么 | 额外需要 |
|---|---|---|
| 学习 CPU/NPU/DDR/HDMI 架构 | 阅读实际源码和物理实现参考 | 无 |
| 无板检查、网页预览 | 可直接按下文安装及测试 | Python，RTL 短测另需 Icarus |
| 重建 CPU 固件 | 提供构建脚本及原参数 | 指定 GCC、libgcc；CoreMark 模式还需其上游代码 |
| 综合、Device Map | 依赖补齐后生成独立入口 | 合法 PDS、DDR/IP、ROM、HDMI 表 |
| 从源码生成新位流 | 需继续完成映射审查、布局、布线与 STA | 本仓库未提供已验证的全自动实现入口 |
| 直接复现原 QG 位流字节 | 公开包目前不支持 | 原 QG 已布线数据库或原位流；均未随包公开 |
| 在新电脑连接板子演示 | 下文提供操作顺序，但公开启动器尚未完成可移植实板入口 | 合法模型包、QG 位流和配套实板启动配置 |

最后两项是实质性缺件，不是安装 Python 就会自动解决的问题。不要删除参考 Tcl 的停止保护来冒充已具备完整流程。

## 2. 下载、建立环境

以下命令在 Windows PowerShell 执行；Python 3.12 或以上。每个版本使用独立目录，不覆盖正在运行的项目。

```powershell
git clone https://github.com/max200701/riscv-fpga-face-recognition.git
cd riscv-fpga-face-recognition
git rev-parse HEAD
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r host/requirements.txt
.\.venv\Scripts\python.exe scripts/verify_release.py
```

最后应显示 `SOURCE_RELEASE_CHECK_PASS`，errors 为空。它只验证源码包，不代表板子或完整模型通过。
记录 commit ID，后续报告都使用同一版本。无需修改全局 PowerShell 执行策略，因为这里直接调用虚拟环境 Python。

## 3. 无板测试与预览

```powershell
.\.venv\Scripts\python.exe scripts/prepare_test_assets.py
.\.venv\Scripts\python.exe scripts/run_host_tests.py
.\.venv\Scripts\python.exe scripts/run_rtl_smoke.py --iverilog C:/iverilog/bin/iverilog.exe --vvp C:/iverilog/bin/vvp.exe
.\.venv\Scripts\python.exe host/console/demo_console.py --source host/source/assets_reference01 --port 8784
```

浏览器打开 `http://127.0.0.1:8784/`。这只是离线界面预览，生成的是合成测试图，并不执行人脸网络。Ctrl+C 停止预览服务。
Icarus 路径需改成自己的安装位置。首次测试资产生成后不必重复生成；脚本拒绝覆盖已有目录时，应保留它或换一个新 checkout。
主机测试的假板对象只验证协议和界面逻辑，不是 FPGA 结果。

## 4. 补齐外部依赖

权威列表是 `docs/external_files.json`：每项含目标路径、长度、SHA-256 和未随包分发原因。
`docs/DEPENDENCY_TABLE.md` 提供便于阅读的逐文件表。模型另有地址契约 `docs/model_contracts.json`。

```powershell
.\.venv\Scripts\python.exe scripts/check_dependencies.py
.\.venv\Scripts\python.exe scripts/check_dependencies.py --prefix hardware/
```

`MISSING` 表示未提供，`HASH_MISMATCH` 表示文件不是本版固定输入。不能仅改文件名或修改清单哈希解决。

合法取得依赖后，可手动按清单路径放置，也可先在例如 `C:/qg-dependencies/` 下保留清单目录结构：

```text
C:/qg-dependencies/hardware/ip/...
C:/qg-dependencies/hardware/application_rom.hex
C:/qg-dependencies/external/libgcc_rv32im_ilp32.a
C:/qg-dependencies/external/coremark/...
C:/qg-dependencies/external/models/...
```

```powershell
python scripts/import_dependencies.py --from-dir C:/qg-dependencies
python scripts/import_dependencies.py --from-dir C:/qg-dependencies --apply
python scripts/check_dependencies.py
```

第一条只预览；全部依赖身份合格后第二条才复制缺失文件，已有文件不会被覆盖。该工具不联网、不搜索整盘、不下载权重、不接设备。受限文件在 `.gitignore` 中，不能强制提交到 GitHub。

获取渠道：厂商 IP 从合法 PDS/板卡资料获取；CoreMark 从 EEMBC 上游获取对应版本；模型需相应许可及本工程固定派生包。通用 ONNX、任意 DDR 例程或另一个 libgcc 不保证等价。上游链接及限制见 THIRD_PARTY。

## 5. 固件和 CoreMark

```powershell
python scripts/build_firmware.py face --cc C:/toolchains/gcc12/bin/riscv-wch-elf-gcc.exe
python scripts/build_firmware.py coremark --cc C:/toolchains/gcc15/bin/riscv32-wch-elf-gcc.exe
Copy-Item -LiteralPath build/face/application_rom.hex -Destination hardware/application_rom.hex
python scripts/check_dependencies.py --prefix hardware/
```

脚本拒绝覆盖已有 build 子目录；有旧结果请用新 checkout。人脸 ROM 自动与冻结 SHA 核对。
CPU 程序 ROM 是 FPGA 片上初始化存储，不是板上的两颗 DDR，也不等于 Flash 固化。
CoreMark 上传镜像是 CPU 程序，不是模型。QG 同一 CPU 可进入 benchmark 模式并返回人脸，不需要新增 CPU 或重新传模型；但断电后的 DDR 模型需要重新装载。

## 6. PDS 实现路径

工具为 PDS 2022.2-SP6.1，Logos2 / PG2L200H / -6 / FBB676，唯一 top `mini_face_demo_top`。
CPU 31.25 MHz、NPU/UI 125 MHz；不能混用后续 2025 数据库。先确认本机有效许可证。

```powershell
python scripts/prepare_pds.py --out build/pds
```

命令输出实际工作目录和运行方式。先执行生成的 synth.tcl，确认综合完成，再执行 map.tcl；两者有真实依赖，不能并行互相抢写同一工程。
后续按 `reference/pds/place.tcl`、`route.tcl`、`qg_two_net_eco.tcl`、`generate_bitstream.tcl` 审查对应步骤。
这些是历史配方，不是可以无条件复制执行的公开自动流水线。新映射必须核对原生实例、站点、时钟及 CDC；新布局需要实际位置/拥塞审查。QG ECO 仅适用于其指定 QB 路由基底。

阶段记录应包括：源码/约束哈希、工具版本、资源、布局、残网、双角 setup/hold/recovery/removal、位流哈希。进程退出码为零不能替代日志成功标记，布局或零残网不能替代最终 STA。
原版验证记录保存在 EVIDENCE；不得把重新生成的位流直接称为原 QG 同字节版本。

## 7. 实板接线与演示顺序（取得完整配套包后）

适用板：MES2L676-CORE-V1.4 + MES-PG2L676-Mini Base-V1.0。不同板修订须重新核对原理图与 IO。

1. 断电连接 JTAG 排线；下载器 USB 接电脑，底板 UART USB-C 用数据线接电脑。
2. 电脑 HDMI 输出连接开发板 **HDMI IN**，不是 OUT。开发板接收端会在 Windows 中作为外接显示器出现，无需另接显示屏。
3. 使用随板适配器；上电后核对设备、温度与 DDR 校准。首次用 JTAG 临时下载 SRAM，不默认写 Flash。
4. 原 QG 位流身份见 release_identity.json。下载后先核对实际版本和协议响应，不使用旧板代际/会话记录冒充新连接资格。
5. Windows 选择扩展屏，配置 FPGA 显示源 640×480。显示源只输出图像，不把主控制台或桌面工具栏送到 FPGA 输入区。
6. 配套实板服务独占 UART（原环境 921600 波特率）；COM 号按本机枚举，不能照抄历史 COM9。关闭其他占串口程序。
7. 装载六份固定模型资产，核对地址/长度/校验，建立空图库；从单张图片开始，核对检测框、任务完成与释放。
8. 用实际板端提取的人脸特征登记人员；更换人员或图库后完成更新再识别，不能使用上一版图库状态缓存。
9. 启动电脑摄像头预览，允许摄像头权限；打开连续识别，观察人脸框、身份/未登记、温度和每轮时间；暂停后再登记或切换 CoreMark。
10. CoreMark 完成须检查 CRC 和运行时长，再返回人脸验证。不要把短测试换算成绩称为正式长跑。

**上述是实际 QG 系统的操作顺序，当前公开包的 demo_console 离线入口并未具备全套新板启动能力。**
`reference/serve_qg38.py`（实际文件位置以 reference 目录为准）依赖原私有交接记录；不能伪造记录来连接新板。原图库、个人面部特征和凭据不会作为“补全工程”发布。

## 8. 故障定位

| 现象 | 先看什么 |
|---|---|
| 依赖检查非零退出 | 查看具体 MISSING/HASH_MISMATCH；先补文件，不删除断言 |
| 编译 ROM 哈希不同 | GCC 版本、libgcc、完整编译参数；保留日志比较 |
| PDS 没继续运行 | 许可证、实际成功标记、缺失输入；参考 Tcl 的停止是刻意设置 |
| 没有 UART 端口 | USB-C 是否接 UART、线是否支持数据、驱动和供电 |
| 串口拒绝打开 | 是否已有其他服务独占；不要并开测试脚本 |
| 没有 HDMI 图像 | IN/OUT、Windows 扩展屏、EDID和实际帧计数/像素；不要只凭单个状态码 |
| 有框但不认识 | 是否登记、登记是否提交、同版模型、采光/人脸占比；余弦不是概率 |
| 网页有画面但无硬件结果 | 先分清离线预览与实板服务；主机不会代替 FPGA 推理 |
| 断电后模型消失 | DDR 易失，按清单重新上传；不是每轮任务都上传 |

## 9. 一次交付应保存的记录

记录 commit ID、依赖检查结果、工具版本、ROM与位流哈希、板版本、模型包哈希及实测结果。
公开性能请区分主机预览FPS、完成识别FPS、RTL周期和STA频率。这里的历史约3.14FPS来自指定实板摄像头样本，不是所有场景的承诺。
完整的干净环境 QG 位流重建、可移植新板启动入口以及合法模型资产分发仍是待完成项；本指南不把这些缺口写成已经通过。
