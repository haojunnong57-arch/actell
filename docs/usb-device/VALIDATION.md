# 本地验证与真机验收边界 · 2026-10-04

## 最新状态 · 2026-10-05（Asia/Shanghai）

用户确认“开启辅助触控后可以了”，对应此前点击收到回执但无可见效果的问题。此前提供的真机日志显示 PA3/HID greeting 正常，两次 TAP 均收到 received → executed，任务结束释放 HID 后 TCP 与 PING 继续；开启辅助触控后点击生效是用户报告的真机结果，没有新增固件改动或烧录。使用前需打开“设置 → 辅助功能 → 触控 → 辅助触控”；出现“触控板与鼠标”设置或收到 executed 本身不等于已经产生可见点击。

最新 App 另已移除强制 finish 收尾要求：设备任务可由模型最终文字结束，finish 不再要求持有截图，诊断版本 `usb-diag-pa3-input-4`。iPhoneOS 无签名编译通过，日志为 `.build/validation/optional-finish-20261005/ios-device-build.log`；此修复之后的 App 重装与真机复测尚未确认。按用户要求未更新或重跑测试，下面各阶段测试结果不代表最新放宽策略已完成全量回归。拖动、旋转、长期后台连续运行、锁屏/拔插恢复仍未完整验证。

以下按实施阶段保留历史记录，“尚未验收”“未烧录”等表述仅描述对应阶段。

> 2026-10-05 输入策略更新：按用户要求，允许在 PhoneAgent 自身及其他 App 输入，删除 PNG 内容比对、方向/尺寸变化拒绝、15 秒匹配等待和发送时新帧序号/场景一致性拦截。停止、锁屏、采集结束、USB 故障仍撤销输入。诊断为 `usb-diag-pa3-input-3`，本次只需更新 App。最终版本仅验证 iPhoneOS 无签名构建；按用户要求测试用例保留本轮开始状态，不更新或重跑，旧拒绝策略测试暂不代表当前行为。

本轮最终构建：`.build/validation/input-preflight-20261005/ios-input-relaxed-build.log` 为 BUILD SUCCEEDED，既有 TLSBridge Swift 6 并发警告仍在。签名工程、Info.plist、固件源码和测试文件与本轮开始摘要一致，未烧录或安装真机 App。此前 `ios-tests.log` 的 169 单元及 1 UI 通过属于扩大修改范围之前的错误提示修正阶段，不作为最终放宽输入策略的测试结果。

最新烧录（2026-10-04 17:24 UTC）：用户授权更新并确认仅 COM 接 Mac后，PA3 NCM+HID 冻结候选已烧录成功，三段设备摘要全部通过；复位后 15 秒 UART 检查确认 PA3/TinyUSB 启动、ELF 匹配且未观察到崩溃，COM 已释放。未重复备份旧固件，未写 NVS/PHY/eFuse；未安装 App 或验收 iPhone 常连/HID。执行日志仅存忽略目录 `.build/device-flashes/pa3-hid-20261004-70wnxwe3/`，详见 [实际烧录记录](PERSISTENT-USB.md#实际烧录--2026-10-04-1724-utc)。以下“未烧录”是准备阶段历史状态。

最新 PA3 常连实现：USB 连接独立于 Agent 任务，任务结束/取消/采集失效只释放 HID；旧任务清理与迟到命令通过内部输入代号隔离。单条请求取消保留回执槽，真实传输/释放失败才关闭连接。App 与固件必须一起更新，不兼容 PA1/PA2。详见 [常连升级与镜像](PERSISTENT-USB.md) 和 [PA3 协议](PROTOCOL.md)。

**最终 166 项 iOS 单元测试、1 项 UI 回归全部通过，iPhoneOS 27 无签名构建通过；C 协议/HID 时序检查与 24 项 TCP 回归通过，NCM-only/NCM+HID 固件构建及 ELF 描述符验证通过。** iOS 包含 5 项真实 NWConnection localhost 回归。日志在 `.build/validation/persistent-usb/`，HID 三段升级候选在 `.build/device-candidates/pa3-ncm-hid-persistent-20261004/`。原始日志/产物均由 Git 忽略。

本轮未烧录、安装真机 App、上传屏幕、提交或推送。Xcode 签名配置、Info.plist 与依赖版本保留原状；之前的未提交修改仍在。下面按阶段保留历史记录，其中“结束后关闭 TCP”“本轮未实现常连”“无需烧录”只描述相应旧版本，不是 PA3 升级指引。

上一轮截图策略：已移除工具层 45 秒、USB 输入层 5/45 秒、采集/执行资格层 2 秒图片年龄检查；模型 `tap` / `drag` 不再包含 `based_on_image_id`，由 App 自动关联最近截图。旧 Host/演示的确认请求改为从请求创建时计时，与截图年龄解耦。诊断版本为 `usb-diag-20261004-6`，见 [IMAGE-POLICY.md](IMAGE-POLICY.md)。

**本轮最终完整 160 项单元测试、1 项诊断 UI 回归均通过，iPhoneOS 27 无签名构建通过。** 日志在 Git 忽略的 `.build/validation/no-image-expiry/ios-tests-final.log`、`ios-device.log`。覆盖无图片 ID 参数的 tap/drag、超过一小时的截图与静止后台帧、审批请求不随旧图片过期、停止/采集换代/USB 丢失及一次性许可和动作后观察屏障。

首轮 `ios-unit.log` 为 159 通过、1 失败：新增旧帧输入夹具使用具体 actor 类型调用审批，落到协议扩展默认实现，没有真正授权。夹具改为与 ActionCoordinator 一致的 `any DeviceBridge` 协议分派；`ios-regression.log` 单项回归通过，随后完整测试通过。首次失败日志保留，没有改弱生产授权检查。构建仍有既有 TLSBridge 并发等警告，未声称零警告。

本轮只改 App、测试与文档，未提交或推送；Xcode 工程、Info.plist、固件 main.c 与本轮开始摘要一致，保留原有未提交改动。工具链为 Xcode 27.0（27A266a）与 iOS 27.0 SDK，依赖未更新。未访问串口、烧录、安装真机 App 或上传屏幕。需用户重新构建安装 App 进行实际采集/HID 复测；本轮未实现 USB 常连。

上一轮前台截图修复：两次真机失败日志均显示采集与 PING 正常，App 在约 15 秒后主动 STOP 并关闭连接。根因是 HID 桥截图错误复用了仅后台可用的输入观察条件；已改为前台/后台都可读取，保持输入场景及新帧保护。同时保存首次停止原因，避免 STOP ACK 等待期间被 watchdog 覆盖为笼统健康错误。诊断升级为 `usb-diag-20261004-5`，见 [FOREGROUND-CAPTURE.md](FOREGROUND-CAPTURE.md)。

**最终完整 156 项单元测试通过，诊断 UI 回归 1 项通过，最终 iPhoneOS 27 无签名构建通过。** 证据位于 `.build/validation/foreground-capture/`：`ios-unit-release.log`、`ios-device-release.log`；UI 成功位于 `ios-tests-final.log`，该次组合运行的单元部分曾有一项失败，后续单元完整重跑通过。前序失败/进程异常与夹具调整均保留并在说明中记录，不将全程描述为一次通过。工程签名、Info.plist、固件 main.c 与本轮开始摘要一致，未操作设备、上传屏幕、提交或推送。后续另一条健康检查错误仍缺对应停止窗口及构建版本；静止画面超过 2 秒没有新帧时仍会停止输入，未声称该边界已在真机解决。

最新 App 行为：按用户要求移除 USB 普通动作逐次回前台批准、后台每段 60 秒、任务总计 5 分钟。普通 USB tap/drag 由任务开始授权，持久记录标记 `task`，保留每次发送前校验及故障停止；旧 Host/演示仍逐动作批准，调用/输入/token 预算及停滞超时保持。SCK 后台采集此前已经启用，非 SCK 任务使用现有 BGContinuedProcessing；没有增加额外保活通道。机制和验收步骤见 [CONTINUOUS-RUNS.md](CONTINUOUS-RUNS.md)。

**最终 151 项单元测试、1 项模拟器 UI 回归及 iPhoneOS 27 无签名构建通过。** 首轮有 1 项旧 Siri 用例因等待已移除的逐动作审批失败；更新为任务确认后直接后台完成，并保留导航/草稿隔离/旧请求防重放验证，随后完整回归通过。日志在 `.build/validation/background-continuous/`：`ios-unit.log`（首轮）、`ios-unit-final.log`、`ios-ui.log`、`ios-device-final.log`。UI 核实系统采集显式启动、新授权说明、旧时限和后台开关不存在，以及 `usb-diag-20261004-4` 诊断导出。Xcode 工程签名配置和 Info.plist 与本轮起始摘要一致；本轮未接触设备、上传屏幕、提交或推送。需重新安装 App；持续后台 HID/Agent 真机闭环尚未验收。

上一轮 App 输入路由修正：HID 烧录后用户报告只读截图路由的点击错误；从错误原文可确定本轮开始时 USB 客户端为空，原始断开触发原因仍缺真机日志。已修复系统授权界面引起短暂 inactive 时误关空闲 USB 的代码路径。真正进入后台时关闭连接仅适用于 `!running` 的空闲状态；运行中的采集/HID 任务继续，锁屏/采集丢失等失效停止保持有效。新增路由与断开原因日志，版本 `usb-diag-20261004-3`。**147 项单元测试、1 项诊断导出 UI 回归及 iPhoneOS 27 无签名构建通过**，包含后台继续任务、回前台批准再返回目标发送输入并观察结果的回归；本轮首轮全部通过。日志在 `.build/validation/usb-input-route/`；工程签名及 Info.plist 摘要未变，未接触设备或上传屏幕，未提交/推送。详见 [输入路由说明](NO-PSK.md#hid-点击入口与空闲连接修正--2026-10-04)。需用户重新安装 App 验证，HID/Agent 真机闭环尚未验收。

23:03（Asia/Shanghai）最新烧录：用户确认仅 COM 接 Mac、原生 USB 断开并批准 NCM+HID。冻结候选以 57600、ROM 无 stub/无压缩方式成功写入；三段设备摘要全部匹配。UART 15 秒观察确认 TinyUSB、PA2 NCM+HID 服务正常启动，冻结 ELF 摘要匹配，未观察到 panic/重启；监视器正常退出、COM 已释放。按用户约定未重复备份，没有触及 NVS/PHY 或 eFuse。详见 [实际烧录记录](HID-BRINGUP.md#本次实际烧录)。本次没有连接 iPhone 或验证真实 HID/Agent 闭环，App 签名未改，未提交/推送。

最新用户反馈及 HID 准备：用户确认最新版 App 的“仅在本机预览截图”已正常显示画面；此前已确认 PA2 双向 PING。这是用户报告的真机结果，不代表 HID 输入或完整 Agent 闭环通过。已在 `with-esp/main` 基线 `dfa3d2d` 上修复固件 STOP 回执竞争：4 项新增用例在旧代码均失败，修复后 18 项 TCP 测试及 C 协议/HID 时序检查通过，NCM-only、NCM+HID 构建和 ELF 描述符检查通过。冻结候选、摘要及待验证项见 [HID 联调准备](HID-BRINGUP.md)。本轮没有烧录、打开串口、操作手机或上传屏幕；App 签名改动保留原状。

2026-10-04 22:41（Asia/Shanghai）最新设置简化：按用户要求将采集任务后台继续能力固定开启，移除设置开关及 UserDefaults 偏好读写。旧的关闭值不再参与路由选择；生产 SCK 路由固定 `backgroundEnabled: true`。系统授权、用户开始任务、时限、采集失效停止和 HID 逐动作审批保留。详见 [固定后台行为](NO-PSK.md#采集任务固定允许后台继续--2026-10-04)。

**最终 143 项单元测试、1 项采集设置 UI 测试和 iPhoneOS 27 无签名构建通过。** 删除了一项已失去适用对象的偏好持久化单元测试；更新现有 UI 测试，核实开关不存在、固定后台说明显示、系统采集仍需明确授权。首轮有一项既有后台 HID 审批往返用例提前中断（3 个断言失败）；补充断言的停止原因后完整单元回归通过，未复现原因，也未放宽输入检查。首次失败和重跑结果均保留在本地。

本轮日志：`.build/validation/capture-background-default/ios-tests.log`、`ios-unit-retest.log`、`ios-device-build.log`；单元最终结果包时间为 `2026.10.04_22-40-40-+0800`，UI 包为 `2026.10.04_22-38-32-+0800`，均在 Git 忽略的 `.build/` 下。Xcode 工程与 Info.plist 与本轮开始快照按字节一致；本机签名设置、固件及系统权限未改变。本轮按用户要求提交至 `with-esp/main`，基线 `d177ca2`，未推送；实际 iPhone 跨 App 采集与 Agent 闭环仍待验证。


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
