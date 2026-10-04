# 本地验证与真机验收边界 · 2026-10-04

独立分支 `feature/ios27-usb-device-capture` 已实现采集、认证 NCM TCP、HID 复合固件及现有 Agent 接口；下列本地检查通过。**未烧录 S3、未安装/签名真机 App、未授权真机全屏采集、未控制 iPhone。第二阶段已补齐 SCK / USB 专属有限后台执行代码与离线测试；后台全屏采集和完整后台 Agent 闭环仍没有真机证明。**

第二阶段复用分析、补充验证和 PSK 配置授权范围见 [BACKGROUND.md](BACKGROUND.md)。下表的 53 项 XCTest 与固件记录为首阶段结果，第二阶段独立记录见该文。

## 工具链与真实构建

| 项 | 实际版本 / 结果 |
| --- | --- |
| Xcode | 27.0，27A266a |
| iPhoneOS SDK | 27.0，24A430；包含 iOS ScreenCaptureKit |
| iPhoneSimulator SDK | 27.0；不含 ScreenCaptureKit，采集 UI 明确禁用 |
| Swift | 6.4，swiftlang-6.4.0.34.1；App 保留 Swift 5 模式 + complete concurrency |
| ESP-IDF | 5.5.5，原已安装 SDK commit `b774170ff46c393eeb5e495ea37936038d3f4f4f` |
| Xtensa GCC | 14.2.0，esp-14.2.0_20260121 |
| IDF Python | 3.12.13；pyelftools 0.33 |
| esp_tinyusb / TinyUSB | 2.2.0 / 0.21.0~2，manifest exact pin + dependencies.lock component hash |
| 真机目标 App | `generic/platform=iOS` 无签名 build 成功，未注册/更改签名账户 |
| 模拟器 | 已运行的 iPhone 18 Pro / iOS 27，`CBC53192-188D-4FC1-818C-36EC433418FF` |
| S3 NCM-only | build 成功；app .bin 389568 bytes |
| S3 NCM+HID | build 成功；app .bin 392736 bytes |

两种固件均有实际 bootloader、partition-table、app `.bin`、ELF 和 `flash_args`，位于 worktree 的 `.build/device-{ncm,hid}/`。这些是编译产物，不是源码包，也不是已验证可用的成品固件。没有为方便测试加入默认 PSK，默认输入锁定。

当前 `.bin` SHA-256：

```text
NCM: a77bf535e677c583eff6c4c2f44f5fd39092c178b3e80e97aed77a8e57c7a1f4
HID: 1e3ab40aa4eaea07a03a93d41c59083bf7a470d91eea344c7b8fc2c7fde5b2b6
```

构建于提交前的工作目录，IDF app version 因此可能包含基线 `-dirty`；这不是烧录证据。后续重新构建的版本串/镜像 hash 可以变化。

## 测试和证据

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| iOS XCTest | 53 项通过，包含新增 8 项采集/USB 安全测试 | [测试日志](evidence/ios-tests-summary.log) |
| 离线 UI | 1 项通过，上传许可默认关、Simulator 采集不可用 | [截图](evidence/simulator-usb-capture.png) |
| C 状态机 | 严格解析、幂等表、反重放、未完成项不逐出、tap/drag/释放顺序、完成/超时隔离通过；ASan/UBSan | [宿主机日志](evidence/host-protocol-tests.log) |
| C 生产 server localhost | 10 项通过：认证、无 PSK、NCM-only 往返与拒绝输入、HID/PING 并发、重复/冲突 ID、错误签名、超长行、心跳丢失、STOP、USB epoch 撤销 | [同上](evidence/host-protocol-tests.log) |
| 原 Python wire contract | 12 项通过 | [日志](evidence/legacy-contract-tests.log) |
| ELF 描述符/依赖 | 实际符号中核对 IAD class、接口数、端点、bus power、HID report IDs；build graph 无 esp_wifi/bt，DHCP/forwarding 关闭 | [描述符日志](evidence/device-descriptors.log) |
| 真机 App 构建 | 成功；Bundle ID 固定；仅新增 screen-capture 后台模式，无麦克风/相机/照片声明 | [构建日志](evidence/ios-device-build-summary.log)、[实际 Info.plist 摘要](evidence/built-info.json) |
| 固件构建 | 两种配置通过 | [NCM](evidence/device-ncm-build-summary.log)、[HID](evidence/device-hid-build-summary.log) |

完整构建日志与 `.xcresult` 留在 `.build/validation/`、`.build/ios/Logs/Test/`。仓库内保存摘要与测试结果。UI 截图来自测试模式，没有真实屏幕内容。没有调用模型服务、读取用户 PSK/API key，或接触真实设备连接。

新增测试核实：序号递增/只留最新帧、epoch 隔离、旋转缩放、过期拒绝、ACK 后新帧屏障、旋转后拒绝输入、未知结果只发送一次、停止封锁、HMAC 跨语言向量/篡改检测、received 与 executed 的区别。TCP 宿主测试编译生产 `main.c` / `protocol.c` / `hid_motion.c`；POSIX/USB/NVS/crypto 平台层用夹具替代，**不模拟真实 NCM 枚举或 HID 驱动**。

过程中修正了 simulator 缺少模块、picker config 的 Swift value 语义、原归档 Keychain 源码漏跟踪、TinyUSB header 的 FreeRTOS 包含顺序，以及测试启动同步问题。最终日志无新增采集/USB 编译警告；原 TLSBridge Swift 6 严格并发预警、旧 PiP API 弃用和工程方向配置警告不属于本次修复。全局 xcode-select 未变更，命令用局部 `DEVELOPER_DIR`；XcodeBuildMCP 当前默认开发者目录为 CommandLineTools，故构建/模拟器检查使用显式路径 CLI。

## 重现命令

```sh
# 位于本 worktree 根目录；均无设备烧录操作
./tools/build_usb_device.sh ncm
./tools/build_usb_device.sh hid
./tools/test_usb_device.sh # macOS CommonCrypto + localhost；沙箱可能需网络批准
./tools/with_device_idf.sh python tools/verify_usb_device_builds.py
python3 ios-app/scripts/test_contract.py

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'generic/platform=iOS' -derivedDataPath .build/ios-device \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -skipPackageUpdates -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'platform=iOS Simulator,id=CBC53192-188D-4FC1-818C-36EC433418FF' \
  -derivedDataPath .build/ios -clonedSourcePackagesDirPath .build/SourcePackages \
  -skipPackageUpdates -disableAutomaticPackageResolution \
  -only-testing:PhoneAgentTests \
  -only-testing:PhoneAgentUITests/ConversationUITests/testUSBScreenCaptureRemainsExplicitAndSimulatorReportsUnsupported \
  CODE_SIGNING_ALLOWED=NO test
```

已有 SPM 固定依赖缓存复制到新 worktree，未修改其他工作树的缓存。新的克隆首次需正常解析 Package.resolved 后再使用禁止自动解析的命令。

## 后续真机最小操作与验收顺序

以下尚未执行，需要人工授权/硬件信息；不能用本地编译替代：

1. 确认实际板型/原生 USB 口（GPIO19/20，而非 COM/CH340）、Type-C 受电/数据线和 VBUS 路径。此次目标是 iPhone 供电 S3；不同时接 COM/Mac 电源。主 Host 分支正在使用的设备保持原状，先协调释放设备。
2. 用户明确批准后，使用已保留的设备备份和确认的串口/烧录流程，先刷 **NCM-only**；独立确认 PSK 的安全配置/NVS 写入。当前默认镜像不会接收输入。此次未生成凭据或烧录配置。
3. iPhone 上确认以太网枚举，手动固定 IP、空 Router/DNS；在 App 前台处理 Local Network 授权，验证认证 PING 往返。核实蜂窝及现有 VPN 的模型 HTTPS 路径仍可用；失败时记录路由，不修改 VPN 或填写假网关。发现和 DHCP 尚未实现。
4. 按现有签名流程安装 App（如涉及账户/App ID 变更须另获明确同意），在系统 picker 中由用户确认全屏采集。先使用“仅在本机预览”，检查切 App、旋转、锁屏/取消、静态画面/idle、帧时延与内存；此步骤不需要模型或上传许可。
5. 再经明确批准刷 NCM+HID，验证绝对鼠标与 iOS/AssistiveTouch 的兼容和坐标，使用无害画面测试点击/拖动、并发 PING、拔线、睡眠/恢复和释放。不能把 HID executed ACK 当作视觉成功。
6. 最后启用本次模型截图上传许可，验证现有逐动作审批、停止和新帧闭环。第二阶段已经实现有限后台资格、审批往返和安全事务，详见 [BACKGROUND.md](BACKGROUND.md)。真机仍需验证：后台实时帧、有效网络 / 心跳、前台审批后返回匹配画面、到期取消与输入释放；不能根据 screen-capture 后台模式或编译成功作出闭环成功结论。

未验证项还包括实物供电电流/启动浪涌、iOS NCM 休眠恢复、持续运行稳定性、真实转屏映射、Local Network 拒绝/再授权、现有 VPN 对有线私网的处理，以及模型视觉能力。未推送、未合并主分支。
