# 构建与复现边界

## 1. 源码身份

唯一板级 top 为 `mini_face_demo_top`，实际 PDS 入口 165 项，清单在 `hardware/design_files.json`。
项目 RTL 保持 QB 冻结字节；控制台只作路径移植，原文件与打包文件哈希在 `source_provenance.json`。
QG 只对已完成的 QB 路由作两个网络的 ECO，未采用 QG source01 的新增寄存器 RTL。

## 2. 外部资产

运行 `python scripts/check_dependencies.py`，逐项补充 `docs/external_files.json` 中的输入。
默认严格核对 SHA-256；缺件时停止，不偷偷用仿真桩替代真实 DDR、不把不同权重/库认作同版。
模型包的大小、DDR 地址和哈希另见 `model_contracts.json`。

这次发布不包含完整模型转换/量化工具链。仅取得原始 ONNX 并不等于生成了固定 ABI 的六份模型包。
现阶段重现推理仍需合法取得这些精确模型派生资产；这项缺件不能由 README 掩盖。

## 3. CPU 固件

```powershell
python scripts/build_firmware.py face --cc C:/your-toolchain/bin/riscv-wch-elf-gcc.exe
python scripts/build_firmware.py coremark --cc C:/your-gcc15/bin/riscv32-wch-elf-gcc.exe
```

人脸固件原编译器为 WCH GCC12；优化 CoreMark 为 WCH GCC15，均链接固定 Debian GCC12 RV32IM ILP32 libgcc。
原参数保留，尤其 `-ffp-contract=off` / `-fno-fast-math` / `-fno-strict-aliasing`（人脸）和优化 CoreMark 参数。
脚本在独立 `build/` 中输出 ELF/ROM 或 CoreMark 上传镜像，并检查 ELF32、RISC-V 和地址范围。
人脸 ROM 需要与外部清单中的预期 ROM 哈希完全一致；否则不是已上板版本的等价重建。
生成后手动将 `build/face/application_rom.hex` 放入 `hardware/`，再次核对依赖。

## 4. PDS

原工具 **PDS 2022.2-SP6.1**，器件 **Logos2 / PG2L200H / -6 / FBB676**。
不要把 PDS2025 结果或新格式数据库混入本版。

```powershell
python scripts/prepare_pds.py --out build/pds
# 然后仅在自己的合法 PDS 环境运行生成的 synth.tcl / map.tcl。
```

生成器只产生独立的综合 / Map 入口，不启动 PDS。外部输入未满足时拒绝生成。
这是源码重建，不是从一个全新网表自动复现 QG 原路由的承诺。

`reference/pds` 保存实际 seed1 / decongestion1、hold 优化、两网 ECO 等历史配方和原生站点约束。
这些 Tcl 入口带显式停止：它们引用原合格 Map/Place/Route 阶段，不可对任意新网表盲跑。
原生实例/站点、有限 CDC 例外和时钟关系需对实际新映射审查；不能用错误例外制造 STA 通过。
不得在 PG2L200H 上宣称未被工具支持的 Fast Router 生效。

精确已布线路由数据库未公开；重新编译后的布局/布线不保证逐字节生成同一位流。
125 MHz 仍有残余 setup/hold，因此本仓库**不提供自动刷板或 Flash 固化命令**。

## 5. 测试

```powershell
python scripts/run_rtl_smoke.py --iverilog C:/iverilog/bin/iverilog.exe --vvp C:/iverilog/bin/vvp.exe
python scripts/prepare_test_assets.py
python scripts/run_host_tests.py
```

上述短测不接串口/JTAG，不运行整链长仿真或 PNR。
`tests/full_application_driver.cpp` 是真实整机驱动源码，依赖供应商仿真原语、Verilator、固定模型、测试输入和参考数值；这些外部数据未随包发布。
不能把模块短测或主机假板测试说成完整应用 RTL 通过。
