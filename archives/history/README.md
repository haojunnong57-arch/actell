> **主线集成版（2026-10-04）**：保留 ESP Host 工程与已有板级实测记录，整合 iOS 27 ScreenCaptureKit、无无线 USB Device NCM/HID、Siri 草稿入口、Live Activities 及统一有限后台生命周期。新 USB Device 路线尚未完成真机联调。最新构建、测试、分支和恢复说明以 [集成记录](docs/integration/INTEGRATION.md) 为准；各历史阶段文档保留原有时间与验证范围。

# ESP32 控制 iPhone：源码与方案检查点

这里集中保存 ESP32-S3 固件 v0.3 和配套 Phone Agent iOS 源码候选版。**两份工程尚未完成联调，也没有实体 ESP32-S3 / iPhone 全链路成功记录。** `../app-only` 使用其他方案，独立维护，本次未修改。

## 目录与入口

```text
with-esp/
├── firmware/                      # ESP-IDF 工程：CMake、components、main
├── firmware-device/               # 同线 NCM / NCM+HID 独立 USB Device 工程，无无线
├── ios-app/                       # SwiftUI 源码、Xcode 工程、XCTest、协议文档
├── tests/                         # 固件宿主机测试、模拟 USB 对端、合成数据
├── tools/                         # 原固件构建/测试脚本与导入校验工具
├── docs/                          # 固件协议资料、导入说明与本次验证记录
│   └── local-validation/          # 本地检查输出（原始日志忽略，可读总结保留）
├── archives/                      # 两份未经修改的 Library 版本 2 原始包
├── README.firmware.md             # 固件包原始 README，内容保持不变
├── SOURCE_MANIFEST.firmware.json  # 固件包原始源文件清单
├── THIRD_PARTY.md
└── LICENSE                        # 固件包原有许可证
```

固件的 `firmware/`、`tests/`、`tools/` 保留原相对位置，因此没有多套一层 `firmware/firmware`，也不需要修改原构建脚本。运行固件脚本时以本目录为根；iOS 操作以 `ios-app/` 为根。

- [固件原始说明](../../README.firmware.md) · [iOS 工程说明](ios-app/README.md)
- [Xcode 工程与状态 PiP 原型验证](ios-app/docs/XCODE-PIP.md)
- [iOS 编译修复与最新验证](ios-app/docs/IOS-BUILD-FIX.md)
- [方案与未完成项](docs/STATUS.md) · [App 桥接协议](ios-app/docs/BRIDGE_PROTOCOL_V1.md)
- [导入来源、哈希和映射](docs/IMPORT.md) · [本次 Mac 验证](docs/LOCAL-VALIDATION.md)

## 实现与验证范围

| 部分 | 源码包含 | 验证状态与缺口 |
| --- | --- | --- |
| ESP32 固件 | ESP-IDF/C、USB Host/mux、已有配对身份下的 TLS/lockdown、CDTunnel、lwIP、RSD/RemoteXPC、截图与 Home 请求路径 | 云端分层测试及本地 S3 编译通过；2026-10-04 实体 N16R8 的原生 USB / COM 烧录、16 MB Flash 检测、8 MB PSRAM 初始化与基础自测通过。COM 使用 115200，高速传输仍有错误。没有真实 iPhone/S3 联通；首次配对、触控媒体流启停、固件 App 通道及负载下的内存/栈峰值仍待完成 |
| iOS App | SwiftUI、SwiftAgentKit、视觉模型适配、逐动作确认/停止、Keychain、实验 TLS-PSK 桥接协议，以及 Xcode 工程和只读状态 PiP 原型 | 集成版的无签名 iPhoneOS 27 构建、单元及 UI 测试见最新集成记录；真机系统授权、Siri 语音入口、后台执行时间和 USB 闭环未验证；未启用 PiP 保活 |
| 两端联调 | 原 Host 路径仍拟经 usbmux；Device 路径为 iPhone USB Host → S3 NCM+HID，App 通过 [PA2 免 PSK TCP](../../docs/usb-device/PROTOCOL.md) 收发命令及分阶段 ACK | PA2 NCM-only 已烧录并通过设备摘要/UART 检查；用户确认 iPhone App 已显示 USB NCM 双向 PING 已验证。HID 输入、系统采集、网络共存与模型端到端尚未验证；见 [当前状态](docs/usb-device/NO-PSK.md) |

**后台执行有边界：SCK / USB 需本次用户启用并持续满足采集、连接与时限检查；普通模型任务需系统实际授予有限片段。TLS 和演示设备工具保持前台限制。尚未证明同机跨 App 自动化闭环。** 独立的 Mac 历史基线曾在 iPhone 15 Pro / iOS 27.0、Xcode 27 DDI、USB 进程内 userspace RSD、无 WDA 的条件下完成截图、触控和 Home，文字输入字符错误；这不代表 ESP32 已成功。见[原始基线记录](https://chatgpt.com/space/page_6abf8257931881918f961de7bba04aeb)。

## ESP32-S3 本地构建与基础实测（2026-10-04）

本次基础测试没有修改固件源码，板上仍为项目默认诊断固件。

本机已将 ESP-IDF v5.5.5（`b774170ff46c393eeb5e495ea37936038d3f4f4f`）、Xtensa GCC 14.2.0、Python 3.12、CMake 和 Ninja 安装在 `.build/toolchains/`，未修改 shell 启动文件。[环境入口](../../tools/with_esp_idf.sh)仅适用于这份已安装的本地环境；新克隆需要先按[官方说明](https://docs.espressif.com/projects/esp-idf/en/v5.5.5/esp32s3/get-started/linux-macos-setup.html)安装相应工具链。

在项目根目录运行：

```sh
./tools/with_esp_idf.sh idf.py --version
./tools/with_esp_idf.sh ./tools/build_firmware.sh
# 以下会烧录开发板；先确认实际串口名和已保留的备份
ESPPORT="/dev/cu.usbserial-REPLACE_ME" # 替换为当前 COM 串口路径
./tools/with_esp_idf.sh idf.py -C firmware -p "$ESPPORT" -b 115200 flash
./tools/with_esp_idf.sh idf.py -C firmware -p "$ESPPORT" monitor
```

实测时 COM 串口为 `/dev/cu.usbserial-<port>`，原生 USB 曾枚举为 `/dev/cu.usbmodem<port>`，重接后名称可能变化。使用 ESP-IDF 配套 esptool 4.12.0；COM 460800 / 921600 曾出现传输错误，已验证的烧录速度是 115200，保留了460800 失败证据（本地文件 `docs/local-validation/esp32-com-460800-failure.log`，已忽略）。原生 USB 同样已通过标准 `idf.py flash` 流程。

实际烧录产物位于 `firmware/build/`：`bootloader/bootloader.bin`、`partition_table/partition-table.bin`、`esp32_iphone_bridge_diagnostics.bin` 和配套 `flash_args` / `flasher_args.json`。应用镜像为 448016 字节。默认固件输出 COM 日志及原生 USB 辅助日志，USB Host 仍关闭。

首次烧录前的完整 Flash 备份保存在 `device-backups/20261004/factory-flash-16mb.bin`，共 16777216 字节，已与设备端摘要核对一致；同目录的 manifest 保存 SHA-256。后续逐字节核验发现 **整份镜像全部为 `0xFF`，即备份时 Flash 为空白状态，不含厂家演示固件**；写回它只会恢复空白 Flash。文件名中的 `factory` 沿用最初命名。该目录被 Git 忽略，独立于可清理的 `.build/` 缓存，请保留备份。

可直接复制独立备份包 `device-backups/esp32-s3-n16r8-preflash-backup-20261004.zip` 到项目外或其他磁盘。包内含完整镜像、原始 manifest、设备摘要校验日志、恢复说明及 `SHA256SUMS`；包外另有同名 `.zip.sha256`。ZIP 已逐项解压校验一致；由于镜像全为 `0xFF`，压缩后约 20 KB 属正常现象，不是只备份了部分 Flash。

证据见实测摘要（本地文件 `docs/local-validation/esp32-bringup-summary.json`，已忽略）、Hello World 启动日志（本地文件 `docs/local-validation/esp32-hello-runtime.log`，已忽略）、原生 USB 诊断日志（本地文件 `docs/local-validation/esp32-diagnostics-usb-runtime.log`，已忽略）和COM 诊断日志（本地文件 `docs/local-validation/esp32-diagnostics-com-after-flash.log`，已忽略）。PSRAM 已通过 IDF 启动时的步进地址测试和项目的 16 KiB 读写测试，尚未进行持续负载或全容量多模式压力测试。

阶段证据、构建环境限制、高波特率与 USB 读取试错，以及本次归档校验见[会话整理记录](docs/local-validation/ESP32-SESSION-REVIEW.md)。

## 这块开发板的 USB 接线依据

完整的原理图分析、J4 测量证据、USB-C 角色说明和扩展配件清单见[板级 USB 与 Host 方案](../../docs/hardware/ESP32-S3-USB.md)。COM 对应 CH340C 串口；原生 USB 对应 GPIO20/D+、GPIO19/D-。图中 CC1/CC2 固定下拉，J4 仅旁路供电二极管；改 Host 固件或短接 J4 不会改变 CC 角色。

用户报告焊盘双向电阻与表笔短接基线均为 1.7 Ω、COM 供电时两端各 4.95 V。前者支持低阻通路判断，后者为空载电压；均未定位实物 J4 的短接方式，也未证明对外供电或 iPhone 接法已通过验证。无需再短接焊盘。

原 Host 分支后续计划采用 GPIO19/20/GND 接外部 USB-A 母口、独立受保护 5V 给该口供电的原型方案，板载原生 USB 留空，COM 保留日志。配件尚未组装或联调，USB Host 仍关闭。此段保留 Host 调试路线；新 Device 路线不新增配件或无线通道，使用现有板原生 USB，接入前仍须核对接口与供电并释放原调试连接。

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

Git 版本管理范围仅为本目录，`../app-only` 独立维护。当前检查点包含原始归档、导入源码、Xcode 工程、状态 PiP 原型和验证记录；构建缓存与 Xcode 个人状态不纳入版本管理。后续 Xcode 验证已解析并下载固定依赖，详情见上述验证文档。2026-10-04 已执行上述 ESP32 备份和诊断固件烧录；这不代表已连接或控制 iPhone。

原始构建/串口/网络日志、测试结果包、抓包、设备探测 JSON 和 `docs/**/evidence/` 等生成目录仅保留在本地，由 `.gitignore` 排除。仓库保留脱敏的结论、重现方法和明确的验收范围；历史文档中标注“本地文件，已忽略”的材料不会出现在新克隆中。已审核的合成 UI 示例仍可作为文档素材。分享新诊断前需去除设备标识、个人路径和屏幕内容；不要强制添加原始输出。取消跟踪不会删除本地副本，也不会清除旧提交中的文件。
