# 第三方组件

| 组件 | 来源与许可 |
|---|---|
| DDR 控制器、PHY、FPGA 原语及调试核 | 紫光同创厂商 IP，随 PDS 授权使用；源码声明及加密模块保留 |
| CoreMark | [EEMBC/CoreMark](https://github.com/eembc/coremark)，Apache-2.0，许可见 `CoreMark_LICENSE.txt` |
| RetinaFace | [Pytorch_Retinaface](https://github.com/biubug6/Pytorch_Retinaface)，许可见 `RetinaFace_MIT.txt` |
| w600k_mbf | [InsightFace](https://github.com/deepinsight/insightface#license)，代码采用 MIT，预训练模型按上游条款限非商业研究使用 |
| GCC 运行库 | [GCC](https://gcc.gnu.org/) 及 [RISC-V 工具链发行包](https://packages.debian.org/gcc-riscv64-unknown-elf)，GPLv3 与 GCC Runtime Library Exception；许可文本随附 |

本包保存当前部署的模型字节。固件使用的 `libgcc_rv32im_ilp32.a` 与原构建一致，编译参数和 ABI 见各固件目录。

Python、OpenCV、NumPy、Pillow、pyserial、Node.js、Verilator 和 Icarus 作为外部依赖安装，分别遵循各自许可。固定测试图片及派生数值用于回归验证；演示人员图库由使用者自行登记。
