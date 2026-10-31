# 第三方与分发边界

根目录 MIT 仅适用于本项目有权发布的代码，不重新许可下列依赖。

| 依赖 | 发布处理 | 来源 / 限制 |
|---|---|---|
| Pango DDR PHY / controller，`.vp` / 原语库 | 未包含；逐文件大小/哈希已列出 | 本地源码标注 PANGO MICROSYSTEMS ALL RIGHTS RESERVED；通过合法 PDS / 板卡渠道获取 |
| HDMI MS7200 初始化表 | 未包含；原常量表身份列在外部清单 | [n111116/CNN_FPGA](https://github.com/n111116/CNN_FPGA)，原引用提交 `81424bdfc4d7f7c1950811b71e94300ef02c0307`；仓库许可证不能替代逐文件来源审查 |
| RetinaFace 模型 / 派生包 | 权重和模型字节未上传 | [biubug6/Pytorch_Retinaface](https://github.com/biubug6/Pytorch_Retinaface)，代码许可与数据/权重许可分别核对 |
| w600k_mbf / InsightFace 权重及派生包 | 未上传；保留接口与哈希 | [InsightFace license policy](https://github.com/deepinsight/insightface#license)：代码 MIT，训练数据及基于其训练的模型限非商业研究，另有授权渠道 |
| CoreMark 上游 | 未包含；仅含本项目移植层和逐文件身份 | [EEMBC/CoreMark](https://github.com/eembc/coremark)，需原版本及其许可/商标条款；不声称官方登记 |
| libgcc | 未包含，精确库 SHA-256 在外部清单 | GCC runtime 及相关许可；软件数值路径依赖此固定库，禁止静默换成任意库 |
| OpenBLAS 参考求和树 | 保留算法出处；无 OpenBLAS 二进制 | `firmware/face/norm512_skylakex.c` 描述固定 0.3.29 SkylakeX DDOT 顺序；[OpenBLAS](https://github.com/OpenMathLib/OpenBLAS) 为上游参考 |
| Python / Pillow / NumPy / OpenCV / pyserial | 使用各自包管理器，不复制本机环境 | 依赖各自许可证；主机不包含推理运行时或权重 |

实际分发清单为 `source_provenance.json` 和根目录 `MANIFEST.json`；
`external_files.json` 是重现所需文件的清单，**不是已提供这些文件的声明**。
不公开个人面部照片、512 维特征、登记姓名/ID记录或正在运行控制台的会话凭据。
