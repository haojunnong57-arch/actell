# 本地验证与真机验收边界 · 2026-10-04

2026-10-04 22:29（Asia/Shanghai）最新方向元数据修正：用户日志显示 781 个样本全部因方向检查被丢弃。已补上同一公开 SCK 方向键的 CMSampleBuffer 级附件读取，保留 per-sample 兼容；不猜方向，冲突和非法值仍拒绝。实现及下一次日志判读见 [附件读取修正](NO-PSK.md#videoorientation-附件读取修正--2026-10-04-2229)。

**本轮完整 144 项单元测试、iPhoneOS 27 无签名构建通过。** 新增四项真实 CoreMedia 缓冲/附件回归，覆盖 buffer-only、sample-only、双层冲突、全部 EXIF 方向编码及诊断脱敏。未调用真实模型或手机采集；本轮没有 UI 流程修改，UI 测试仍为下面上一轮结果。日志在 `.build/validation/capture-orientation/{ios-unit.log,ios-device-build.log}`，结果包为 `.build/ios/Logs/Test/Test-PhoneAgent-2026.10.04_22-27-59-+0800.xcresult`，均已忽略。公开 Apple 文档本地副本也仅存忽略目录。

Xcode 工程/Info.plist 与本轮开始快照字节一致，签名、依赖、固件未变更；未烧录或安装真机 App。本机工具链仍为 Xcode 27.0 (27A266a) / iPhoneOS 27.0，既有 TLSBridge 并发警告未扩展到新代码。本轮修复按用户要求提交至 `with-esp/main`，未推送。新版真机方向字段来源及实际有效帧仍需用户复测，旧日志不足以证明字段所在层级。


上一轮更新：首帧等待、后台偏好持久化与停止采集修正已在 `with-esp/main` 完成，当前基线 `01541620dae4e8399b2af11ecc6960223548e3e2`，本轮未提交/推送。见 [实现与复测步骤](NO-PSK.md#首帧等待后台偏好与停止采集--2026-10-04)。用户已要求始终允许任务按需发送系统授权的截图，原独立上传开关已移除；后台偏好不再随停止/结束清空，只读截图也支持有限后台资格。下文旧上传开关与仅前台描述是先前版本记录。

验证结果：**最终完整 140 项单元测试通过，2 项相关 UI 测试通过，iPhoneOS 27 无签名构建通过。** 新增回归覆盖首帧延迟到达、超时诊断、取消/换代、方向元数据、只读后台新帧与输入拒绝、停止期间启动竞争/重复停止，以及偏好在停止/结束/新 ViewModel 后保留。UI 核实上传开关已移除、后台偏好离开再进设置仍开启、采集元数据可复制，以及缺少系统授权时准确报错且模型继续解释。

首轮完整回归有一个原有后台 HID/Siri 审批用例提前中断（3 个断言失败）；给断言补充停止原因后，后台集成组 9 项和最终完整 140 项均通过。该首次中断未稳定复现，保留失败日志，不将其归因于已证实的 SDK/调度原因，也没有放宽帧校验、发送栅栏或测试断言。

本次本地日志（均由 Git 忽略）：`.build/validation/capture-startup/ios-tests.log`（含首次失败及两项通过的 UI）、`background-retest.log`、`ios-unit-final.log`、`ios-device-build-final.log`。结果包在 `.build/ios/Logs/Test/`；单元最终包时间 `2026.10.04_22-16-27-+0800`，UI 包时间 `2026.10.04_22-12-23-+0800`。工具链沿用 Xcode 27.0 / 27A266a、iPhoneOS 27.0 / 24A430、Swift 6.4（项目 Swift 5 模式）；依赖未更改。已有 TLSBridge 严格并发等编译警告仍在，没有新增采集编译警告。

工程及 Info.plist 与本轮开始快照按字节一致，签名 Team 保留原状；字符串目录同步了对应说明。未访问串口/刷写、安装真机 App、调整系统授权或上传实际屏幕。Simulator SDK 没有 ScreenCaptureKit：真正首帧内容/附件、正常与系统停止回调、静态屏幕和后台 Agent 行为仍待用户在 iPhone 复测。系统独立停止与 App 唯一一次 stop 请求仍可能同时发生；-3808 不能被当作首帧成功证据。


上一轮截图链路修正：Agent 的全屏读取已与 USB 输入分离，见 [截图链路说明](NO-PSK.md#app-截图与-usb-输入分离--2026-10-04)。无 USB、NCM-only 或输入健康条件失效时，前台只读路径仍可读取已授权的新帧；上传许可、过期/换代/取消检查和输入拒绝均有回归。**133 项单元测试、2 项 UI 测试、iPhoneOS 27 无签名构建全部通过**。UI 核对未授权错误、模型继续解释错误、仅本机预览/上传许可默认状态及日志导出；只使用合成帧和离线 provider。XCTest 在错误消息用例中出现三次动画完成通知等待，之后断言及整轮测试通过。真实 iPhone 全屏授权、画面采集和模型看屏结果仍需用户安装后验证，不能用本次模拟器结果替代。

本次日志和截图位于 `.build/validation/local-screen-route/`，由 Git 忽略；结果包位于 `.build/ios/Logs/Test/`。Xcode 工程与 Info.plist 相对开始时按字节不变，本机签名 Team 保留原状；字符串目录仅新增对应的采集说明文案。没有刷写固件、操作真机系统授权或上传实际屏幕。

更新（18:47，Asia/Shanghai）：main 的 NCM-only 镜像已获用户确认并通过 COM 烧录，写入校验和 UART 启动检查通过，服务报告 `auth LOCKED`。尚未连接 iPhone 验证枚举或通信；NCM+HID 未烧录。见[实机记录](NCM-BRINGUP.md)。下文保留首阶段验证时的历史状态。

后续用户观察：PA1 的 iPhone 以太网接口出现，固定 IP 已配置。用户随后选择 USB 免 PSK，2026-10-04 19:34 已完成 PA2 NCM-only 的 COM 烧录、设备摘要及启动检查；详见 [NO-PSK.md](NO-PSK.md)。PA2 手机端网络收发、HID 和后台闭环仍待验证。以下 PA1/PSK 测试结果为历史记录。

后续连接诊断：用户已自行安装 App，确认 PA2 USB 以太网存在、IP 为 `192.168.7.2/24`；App TCP 报 ENETDOWN，本地网络权限列表尚无 PhoneAgent。App 首次连接等待与路径诊断修正已通过 119 项单元测试、1 项 UI 回归和 iPhoneOS 27 无签名构建，详见 [NO-PSK.md 的连接诊断](NO-PSK.md#iphone-首次连接诊断--2026-10-04)。还没有手机 PING 成功证据。 后续增加可复制 USB 诊断，已通过 122 项单元测试、1 项 UI 回归及 iPhoneOS 构建，见 日志版本验证（本地文件 `evidence/usb-diagnostics-20261004.log`，已忽略）。

最新接口诊断：用户关闭 VPN 后默认路径变化，但 `en3=192.168.7.2/24` 与 connection `notAvailable/ENETDOWN` 同时存在的现象未变。App 已改为按该固定 IP 解析并绑定具体接口，新增选择/拒绝日志，版本 `usb-diag-20261004-2`；127 项单元测试、1 项 UI 测试和 iPhoneOS 无签名构建通过。尚未在手机验证新版 TCP/PING，详见 证据（本地文件 `evidence/usb-interface-binding-20261004.log`，已忽略） 和 [当前操作步骤](NO-PSK.md#vpn-对比与具体接口绑定--2026-10-04)。此次没有烧录或修改 VPN。

最新真机反馈：用户随后确认界面出现“USB NCM 双向 PING 已验证”。这是 PA2 网络往返的用户报告，成功日志尚未提供；实际接口类型及旧路径失败的精确机制仍未核实。HID、拔插/睡眠恢复、VPN 共存、采集/后台闭环没有新增验收证据。

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
| 模拟器 | 已运行的 iPhone 18 Pro / iOS 27，`<SIMULATOR_ID>` |
| S3 NCM-only | build 成功；app .bin 389568 bytes |
| S3 NCM+HID | build 成功；app .bin 392736 bytes |

两种固件均有实际 bootloader、partition-table、app `.bin`、ELF 和 `flash_args`，位于 worktree 的 `.build/device-{ncm,hid}/`。这些是编译产物，不是源码包，也不是已验证可用的成品固件。没有为方便测试加入默认 PSK，默认输入锁定。

首阶段 `.bin` SHA-256（不是本次 main 已烧录镜像，后者见实机记录）：

```text
NCM: a77bf535e677c583eff6c4c2f44f5fd39092c178b3e80e97aed77a8e57c7a1f4
HID: 1e3ab40aa4eaea07a03a93d41c59083bf7a470d91eea344c7b8fc2c7fde5b2b6
```

构建于提交前的工作目录，IDF app version 因此可能包含基线 `-dirty`；这不是烧录证据。后续重新构建的版本串/镜像 hash 可以变化。

## 测试和证据

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| iOS XCTest | 53 项通过，包含新增 8 项采集/USB 安全测试 | 测试日志（本地文件 `evidence/ios-tests-summary.log`，已忽略） |
| 离线 UI | 1 项通过，上传许可默认关、Simulator 采集不可用 | 截图（本地文件 `evidence/simulator-usb-capture.png`，已忽略） |
| C 状态机 | 严格解析、幂等表、反重放、未完成项不逐出、tap/drag/释放顺序、完成/超时隔离通过；ASan/UBSan | 宿主机日志（本地文件 `evidence/host-protocol-tests.log`，已忽略） |
| C 生产 server localhost | 10 项通过：认证、无 PSK、NCM-only 往返与拒绝输入、HID/PING 并发、重复/冲突 ID、错误签名、超长行、心跳丢失、STOP、USB epoch 撤销 | 同上（本地文件 `evidence/host-protocol-tests.log`，已忽略） |
| 原 Python wire contract | 12 项通过 | 日志（本地文件 `evidence/legacy-contract-tests.log`，已忽略） |
| ELF 描述符/依赖 | 实际符号中核对 IAD class、接口数、端点、bus power、HID report IDs；build graph 无 esp_wifi/bt，DHCP/forwarding 关闭 | 描述符日志（本地文件 `evidence/device-descriptors.log`，已忽略） |
| 真机 App 构建 | 成功；Bundle ID 固定；仅新增 screen-capture 后台模式，无麦克风/相机/照片声明 | 构建日志（本地文件 `evidence/ios-device-build-summary.log`，已忽略）、实际 Info.plist 摘要（本地文件 `evidence/built-info.json`，已忽略） |
| 固件构建 | 两种配置通过 | NCM（本地文件 `evidence/device-ncm-build-summary.log`，已忽略）、HID（本地文件 `evidence/device-hid-build-summary.log`，已忽略） |

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
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
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
6. 最后由用户开始模型任务，按需发送已授权的截图，验证现有逐动作审批、停止和新帧闭环。第二阶段已经实现有限后台资格、审批往返和安全事务，详见 [BACKGROUND.md](BACKGROUND.md)。真机仍需验证：后台实时帧、有效网络 / 心跳、前台审批后返回匹配画面、到期取消与输入释放；不能根据 screen-capture 后台模式或编译成功作出闭环成功结论。

未验证项还包括实物供电电流/启动浪涌、iOS NCM 休眠恢复、持续运行稳定性、真实转屏映射、Local Network 拒绝/再授权、现有 VPN 对有线私网的处理，以及模型视觉能力。未推送、未合并主分支。
