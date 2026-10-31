# 主机控制台与隐私

`host/console` 对应 QG38 的功能源码：串口单所有者、图像管线、相机帧准备、图库事务、结果解码及同 CPU CoreMark 模式。
没有 CPU/GPU 人脸推理代码。HTML / JavaScript 用于取像与显示，硬件返回结果用于画框。

## 无板离线预览

安装 `host/requirements.txt`，然后：

```powershell
python scripts/prepare_test_assets.py
python host/console/demo_console.py --source host/source/assets_reference01 --port 8784
```

默认仅绑定 127.0.0.1。测试源为生成的彩条，不含真人照片。
缺少合格的本地发布记录时禁止连接真实串口；不会因为打开网页而自动刷板、连接或上传模型。

## 与原上板环境的差异

原 `serve_qg38.py` 依赖一次性交接状态、原板 generation、计数和私人图库。
这些记录不能作为公共启动配置，因此仅在 `reference/` 中保存启动器源码用于审阅，未复制其私有状态。
当前公共入口仅支持离线预览；完整实板启动器的可移植配置尚待后续发布。
不得伪造 `SRAM_REVIEW_PASS` 或板测回执来绕过当前入口的检查。

`host/native_display/` 还保留实际独立 Windows HDMI 图像窗口源码。它使用 Win32 显示枚举及 Tk，
寻找已有的 640×480 非主屏，连接本机 8783 源服务；不会自动调整 Windows 显示模式。
它不应在离线短测中运行，也不执行人脸识别。

模型上传需要六份固定资产；不能用空文件或另一版 OY 的程序资产替代。
`docs/model_contracts.json` 提供地址 / 长度 / 哈希，不包含权重。
生成公开模型清单时应使用自己的本地绝对路径；图库从空库开始，只登记本人同意提供的数据。

一次仅一个进程拥有串口。连续识别中不要同时运行板测脚本、重置序号或强行覆盖仍被消费的帧。
用户数据、照片、特征、串口记录应留在忽略的本地目录，不能提交进公共仓库。
