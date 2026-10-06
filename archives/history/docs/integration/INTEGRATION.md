# PhoneAgent 主线集成 · 2026-10-04

本次把四个独立 feature 整合进一个 App，保留主线 ESP Host 的工程、板级资料和实测证据。iOS 27 采集、USB Device、Siri、Live Activities 和有限后台运行共用同一执行实例。**源码与本地测试不等于 iPhone + S3 真机控制成功。**

## 工作树、基线和合并

实际主仓库为 `<workspace>/with-esp`，主分支 `main`。临时集成位于同级 `with-esp-integration`，分支 `integration/phoneagent-features-20261004`，从干净的 `main@45f0186c9e7808c104822a7e23e9a738938fe329` 创建，没有从较旧 feature 覆盖主线。

| 来源 | 集成的 feature HEAD | 合并提交 |
| --- | --- | --- |
| USB Device / SCK | `d326ea8b0c2f2b5eebd3468d6f12dffcfa31b0d4`，含 `18fac115` | `4c58e55e3af64c02155125f05791987910447930` |
| Live Activities | `57acc61620c155c1b24bf727fd845583aa752e21` | `f968f08459e3f34495298b7a8f2b60cd003a11e6` |
| Siri | `e5b1aca72e1d2c9bedec23b613f4c3dbc584660f` | `458b89728962d81f163331b823ab5dac852f6390` |
| 通用后台片段 | `2509d7098fc8a3af4c62bd8fc20e911df4aa4933` | `b0e9a7b234982de99607ea33f88b8736e0dceef8` |

开始时的状态（本地文件 `baseline.json`，已忽略）记录所有 HEAD、工作区状态和差异摘要。USB feature 的 `project.pbxproj` 和 `Info.plist` 有用户未提交的 Xcode 格式/签名选择改动；保留在原 worktree，未带入集成、未 stash 或提交。其他 feature 和 `app-only` 未修改。未推送。

当前主线提交、快进结果、各来源最终状态及后台分支归档参见 交接记录（本地文件 `handoff.json`，已忽略）。

## 旧后台分支退役与恢复

旧后台源码已完整合并，通用能力和回归测试已复用。相关任务处于 idle；删除前再次核对 HEAD、干净状态、合并祖先关系及归档摘要。已使用不带 force 的 `git worktree remove` 删除 `with-esp-background-runs`，并用 `git branch -d` 删除 `feature/background-runs`。其他 feature 工作树保留。

恢复点为 `archive/background-runs-20261004`，指向 `2509d7098fc8a3af4c62bd8fc20e911df4aa4933`。完整归档位于 `<workspace>/worktree-archives/background-runs-20261004.tar.gz`，330,080,348 bytes，保留忽略的 DerivedData 等构建输出；9,013 个文件/链接均与原工作树逐项核对。见 归档哈希（本地文件 `background-archive.json`，已忽略）。没有强删未提交内容。

需要恢复源码时，在主仓库运行：

```sh
git worktree add -b feature/background-runs ../with-esp-background-runs archive/background-runs-20261004
```

需要历史构建产物时，先将 tar 解压到新的临时目录，再选择性复制 `ios-app/DerivedData`；不要用归档中的旧 `.git` 指针覆盖新 worktree 的 `.git`。历史 DerivedData 仅作证据，新代码仍应重新构建。

## 冲突处理与复用

- `AgentViewModel` 仍是 Agent、审批、连接与停止的所有者。`PhoneAgentRuntime.shared` 给 App 和 App Intents 提供同一 model、ConversationStore、SessionCommandService。未创建第二个后台 Agent。
- `RunLifecycleCoordinator` 统一状态、世代标识、有限执行资格、事务检查点和停止。`RunExecutionScheduler` 每轮只选一个来源：用户本次启用的 SCK/USB 上下文，或系统实际交付的 `BGContinuedProcessingTask`。USB 未启用后台时不回退为通用系统片段。
- 保留旧后台分支的通用模型处理、wait/finish、任务到期、无进展超时、TLS 同步取消、设备会话复验与未知结果恢复测试。SCK 只替代一种执行来源，未删除通用 BGContinuedProcessing 能力。
- 采用 iOS 27 SDK 的异步 `submitTaskRequest`，处理异步拒绝及提交/取消竞态。注册、提交使用相同的唯一片段 ID；Info.plist 只允许既定 wildcard 前缀。提交成功不是执行许可，必须收到系统 launch handler。SCK 不同时申请系统片段。
- `UIBackgroundModes` 合并为 `screen-capture` 和 `processing`；保留 Live Activity 声明及 `phoneagent://` 深链。没有 Broadcast Upload Extension、音频/麦克风/相册权限、后台音频或 VPN 保活。
- `ApprovalRecordStore` 管一次性审批身份、参数摘要、期限、批准和消费；生命周期 journal 管 prepared → dispatching → acknowledged → observedResult / outcomeUnknown。两个记录职责不同，不把界面批准当作设备执行。
- 通用检查点文件 `run-checkpoint-v1.json` 可在首次升级时读取旧 `usb-run-checkpoint-v1.json`，保留旧文件。恢复只展示记录；未确认的已发送动作标为 outcomeUnknown，不自动重放，旧审批不可恢复。
- `ContentView` 保留 Siri 草稿路由和 Live Activity 精确会话/轮次/审批路由。活跃任务期间新 Siri 草稿延后展示；旧链接不能切换到或批准新轮次。控制调试页因同轮审批深链关闭时不停止该轮；普通手动离开仍停止，旧跳转不能豁免将来的退出。
- 合并 XcodeGen / Python 工程来源后重新生成 pbxproj。App 和 Widget 随主工程使用 iOS 27；App Bundle ID `com.ja1chen.PhoneAgent`，Widget `com.ja1chen.PhoneAgent.LiveActivity`。Team 保持空白。重复 Keychain 实现合并到原有 `SecretStore`，保留原 service/account 和 `WhenUnlockedThisDeviceOnly`，没有扩大凭据权限。

## 执行与授权边界

Siri 创建任务只保存待确认草稿，识别或解锁不表示同意模型上传或工具动作。用户在会话里确认后才开始；设备 tap/drag 继续逐动作批准。状态/停止 Intent 使用同一 runtime，停止绑定已捕获的 run ID，不能停止后来创建的另一轮。

Live Activity 只呈现结构化概括状态和有限计数，不显示任务文字、截图、密钥或模型内容。锁屏上的链接只导航，不能批准、发送或重启。`approved` 状态明确提示批准不等于已执行；只有后续 ACK 和新截图才能推进相应状态，视觉效果仍需核对。

SCK/USB 路线需用户在系统 picker 授权全屏采集、前台允许 Local Network，并在 App 为本次任务启用后台及截图上传。最新帧留在 iPhone 内存；按需缩放编码，携带序号、时间、尺寸和方向。输入前必须有健康采集与认证心跳；前台批准后返回目标 App，重新取得匹配画面，才可消费一次输入许可。实际发送前再次检查状态和帧版本。

每后台片段最长 60 秒，总运行最长 5 分钟；截图过期、采集丢失、USB 失联、锁屏、系统片段到期或停止会取消输入并请求释放。连接已断时 App 不能保证 STOP 送达，S3 端超时/断连释放机制独立兜底。结果未知不自动重发。

通用系统片段允许模型/本地步骤有限继续；TLS 与 Demo 的设备工具保持前台限制，待审批时退到后台会失效。系统调度不保证立即授予时间。后台采集能力与 Agent 真机后台闭环仍是两个需要分别验证的事实。

USB 固件固定为无无线本地 netif / TCP 服务：S3 `192.168.7.1/24:28766`，初验手机手动 `192.168.7.2/24`，Router/DNS 留空。不桥接 Wi-Fi、不另建 Wi-Fi/BLE、不填假网关、不新建或修改 VPN。DHCP/发现后续再做。HID 与 NCM 共用原生 USB；没有额外 CDC。

PSK 是输入服务的应用层 HMAC 认证，不是 Apple 配对文件或采集授权；命令、方向、会话与 ACK 均绑定认证。未配置则锁定，无默认密钥。此阶段没有读取、生成、打印或写入真实 PSK；将来配置会覆盖既有 bridge account，须单独确认目标设备和密钥。详见 [协议](../../../../docs/usb-device/PROTOCOL.md) 与 [PSK 配置范围](../usb-device/BACKGROUND.md#psk-为什么存在配置需要哪些授权)。

## 本地验证

**114 项单元测试、16 项 UI、10 项 USB Device 协议测试、12 项 App Python 协议测试通过，完整 Host suite 和四种固件配置编译通过，最终无签名 iPhoneOS 27 build 通过。** UI 回归之后补充了冷恢复取消旧系统请求的内部修复，随后重跑全部 114 单元及设备 build；UI 源码未再改变。

最终结果和日志摘要见 验证清单（本地文件 `validation.json`，已忽略） 与 `evidence/`。完整日志和 xcresult 留在 `with-esp-integration/.build/validation`、`.build/ios/Logs/Test`。

- 单元测试覆盖实际 Agent loop、系统片段拒绝/到期、SCK 与系统来源互斥、Siri 草稿/停止、Live Activity 一次审批、深链跳转、审批后回到目标、旧检查点迁移、断连/锁屏/采集丢失及未知结果不重放。
- UI 测试使用合成屏幕、离线 provider 和隔离状态，涵盖 Siri 冷/热入口、运行中草稿延后、确认与拒绝、停止/历史、Live Activity 系统展示和精确历史链接、控制调试退出、模拟器采集不可用提示。
- USB Device 协议测试编译生产 C 代码，平台层为宿主夹具；原 App Python wire-contract 测试保留。完整 Host suite 包含实际 mbedTLS↔独立 OpenSSL、本地 TCP、固定上游 HTTP/2/XPC/RSD、实际 lwIP packet tests、zlib、分配故障及 ASan/UBSan；没有连接实体设备。
- 修复宿主测试的 Darwin 编译参数、ASan Python 注入、pthread 特性宏和 GNU linker wrap 替代方案。Darwin 对测试静态对象编译时重定向分配函数，独立真实分配器 translation unit，保留故障注入而非跳过；Linux 原 GNU wrap 仍保留。补齐固定提交/哈希的 RSD 公开 oracle，去除对未跟踪 research 目录的依赖。
- 两种 Device 固件、原 Host 默认固件和 Host USB-enable compile-only 配置均已编译。真实 bootloader、partition-table、app bin / ELF / flash_args 保存在 `.build`；镜像大小及哈希（本地文件 `firmware-artifacts.json`，已忽略）。Host compile-only 的 GPIO 配置是编译占位值，不是确认过的板级接线，不能直接刷写。

工具链：Xcode 27.0 (`27A266a`)、iPhoneOS 27.0 (`24A430`)、Swift 6.4 (`swiftlang-6.4.0.34.1`)，App 仍为 Swift 5 language mode + complete concurrency。iPhoneSimulator 27 SDK 没有 ScreenCaptureKit，UI 明确禁用，真机分支通过无签名设备 build 验证编译。ESP-IDF 5.5.5 (`b774170ff46c393eeb5e495ea37936038d3f4f4f`)、Xtensa GCC 14.2.0 (`esp-14.2.0_20260121`)、Python 3.12.13；esp_tinyusb 2.2.0、TinyUSB 0.21.0~2，组件哈希在 lockfile。Host oracle 独立 venv 固定 construct 2.10.70、hyperframe 6.1.0。

保留的警告：旧 PiP API 弃用、TLSBridge 在 Swift 6 language mode 下的并发预警、工程屏幕方向警告；UI 测试可见原有 SwiftUI “Modifying state during view update” 警告。全局 xcode-select 仍指向 CommandLineTools，测试收集诊断阶段可能提示找不到 simctl；构建/运行命令使用局部 DEVELOPER_DIR，不改变用户全局设置。不要把这些警告藏为零警告验证。

## 打开与复现

集成完成后应打开 **`<workspace>/with-esp/ios-app/PhoneAgent.xcodeproj`**，共享 scheme `PhoneAgent`。旧 feature 工程是独立快照。Simulator 不需 Team；此阶段未改签名账户或安装真机。

在集成 worktree 根目录，可复现：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
  -derivedDataPath .build/ios -clonedSourcePackagesDirPath .build/SourcePackages \
  -skipPackageUpdates -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO test
# 设备 SDK 编译：destination 改 generic/platform=iOS，动作改 build。
./tools/test_usb_device.sh
python3 ios-app/scripts/test_contract.py
PYTHON="$PWD/.build/host-test-venv/bin/python" ./tools/with_device_idf.sh ./tools/test_all.sh
./tools/build_usb_device.sh ncm
./tools/build_usb_device.sh hid
./tools/with_device_idf.sh python3 tools/verify_usb_device_builds.py
```

SPM/IDF 使用本机已安装的锁定依赖；新克隆需先正常解析/安装相同版本。所有运行产生的测试数据均为合成内容。没有向外部模型发送实际屏幕。

## 真机仍需完成

协调释放原 Host 调试设备，核对具体板型、原生 USB GPIO19/20 口、Type-C 角色、线材和供电；N16R8 本身不是板型。此次未增加设备，未触碰原调试连接。另行授权烧录/PSK 配置及 App 签名安装后，先 NCM-only 固定 IP 双向认证，再 HID 复合并发，最后 Agent。

人工确认 Local Network 和 SCK 全屏权限；先本地预览，再授权模型上传。真机验证需覆盖静态/动态帧、旋转、后台时间、审批往返、锁屏/拔线/睡眠/恢复释放、HID 坐标/AssistiveTouch、蜂窝与现有 VPN 共存、Siri 语音/锁屏策略、系统 BGContinuedProcessing 实际授予与 Live Activity 展示。当前精确画面匹配与帧过期策略可能保守拒绝输入，需以实测调整，不能放宽为盲发。

官方依据：[iOS ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios)、[BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)、[Local Network TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。系统后台 API 的实际签名与异步行为另直接核对本机 iPhoneOS 27 SDK headers；本地构建并不证明系统授予执行时间。
