# ESP32 控制 iPhone：源码与方案检查点

这里集中保存 ESP32-S3 固件 v0.3 和配套 Phone Agent iOS 源码候选版。**两份工程尚未完成联调，也没有实体 ESP32-S3 / iPhone 全链路成功记录。** `../app-only` 使用其他方案，独立维护，本次未修改。

## 目录与入口

```text
with-esp/
├── firmware/                      # ESP-IDF 工程：CMake、components、main
├── ios-app/                       # SwiftUI 源码、Xcode 工程、XCTest、协议文档
├── tests/                         # 固件宿主机测试、模拟 USB 对端、合成数据
├── tools/                         # 原固件构建/测试脚本与导入校验工具
├── docs/                          # 固件协议资料、导入说明与本次验证记录
│   └── local-validation/          # 本次 Mac 检查原始输出
├── archives/                      # 两份未经修改的 Library 版本 2 原始包
├── README.firmware.md             # 固件包原始 README，内容保持不变
├── SOURCE_MANIFEST.firmware.json  # 固件包原始源文件清单
├── THIRD_PARTY.md
└── LICENSE                        # 固件包原有许可证
```

固件的 `firmware/`、`tests/`、`tools/` 保留原相对位置，因此没有多套一层 `firmware/firmware`，也不需要修改原构建脚本。运行固件脚本时以本目录为根；iOS 操作以 `ios-app/` 为根。

- [固件原始说明](README.firmware.md) · [iOS 工程说明](ios-app/README.md)
- [Xcode 工程与状态 PiP 原型验证](ios-app/docs/XCODE-PIP.md)
- [方案与未完成项](docs/STATUS.md) · [App 桥接协议](ios-app/docs/BRIDGE_PROTOCOL_V1.md)
- [导入来源、哈希和映射](docs/IMPORT.md) · [本次 Mac 验证](docs/LOCAL-VALIDATION.md)

## 实现与验证范围

| 部分 | 源码包含 | 验证状态与缺口 |
| --- | --- | --- |
| ESP32 固件 | ESP-IDF/C、USB Host/mux、已有配对身份下的 TLS/lockdown、CDTunnel、lwIP、RSD/RemoteXPC、截图与 Home 请求路径 | 此前通过云端分层/模拟对端测试及 S3 交叉编译；本次通过部分 Mac 宿主机测试。没有真实 iPhone/S3 联通；首次配对与身份配置、触控媒体流安全启停、固件 App 通道、硬件 RAM/PSRAM/栈水位尚未完成 |
| iOS App | SwiftUI、SwiftAgentKit、视觉模型适配、逐动作确认/停止、Keychain、实验 TLS-PSK 桥接协议，以及 Xcode 工程和只读状态 PiP 原型 | 12 项 Python 协议测试、SPM 解析及核心状态/PiP 文件类型检查通过；完整 Xcode 构建受阻于 SwiftAgentKitMacros 信任要求，XCTest、界面和真机验证未运行；未启用跨 App PiP 后台能力 |
| 两端联调 | 拟由 S3 经 usbmux 连接 App 的 NWListener，独立于 CoreDevice 通道 | 固件尚无 App 通道，协议约定不等于已连接；模型 API 与硬件端到端尚未验证 |

**App 离开前台即停止，不能宣称同一台 iPhone 跨 App 持续自动化。** 独立的 Mac 历史基线曾在 iPhone 15 Pro / iOS 27.0、Xcode 27 DDI、USB 进程内 userspace RSD、无 WDA 的条件下完成截图、触控和 Home，文字输入字符错误；这不代表 ESP32 已成功。见[原始基线记录](https://chatgpt.com/space/page_6abf8257931881918f961de7bba04aeb)。

## 本地离线校验

在 `with-esp` 运行，不联网、不接设备、不读取配对材料：

```sh
python3 tools/verify_import.py
python3 ios-app/scripts/test_contract.py
CC=clang bash tools/test_host.sh
CC=clang bash tools/test_usb_descriptors.sh
CC=clang bash tools/test_lockdown_probe.sh
CC=clang bash tools/test_lockdown_session.sh
```

`verify_import.py` 比较当前文件与原始归档，会报告后续有意修改的 iOS 文件和 `.gitignore`；原始清单保留为导入时的历史证据。这些测试会在本目录 `.build/` 生成合成数据和测试二进制。其他原始脚本的完整依赖和平台限制见[导入时验证记录](docs/LOCAL-VALIDATION.md)；不要把这些检查当作完整构建或真机验收。

Git 版本管理范围仅为本目录，`../app-only` 独立维护。当前检查点包含原始归档、导入源码、Xcode 工程、状态 PiP 原型和验证记录；构建缓存与 Xcode 个人状态不纳入版本管理。后续 Xcode 验证已解析并下载固定依赖，详情见上述验证文档。未推送代码、刷机、安装手机 App、调用模型或创建、读取真实配对凭据。
