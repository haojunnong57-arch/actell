# USB 免 PSK · PA2 · 2026-10-04

用户明确选择“USB 免 PSK：接受同机其他程序可能访问，不再使用通信密钥”。已在 `<workspace>/with-esp` 的 `main` 完成实现，基线提交 `883d0e8e61e62b2c9db3361985dc43c9db45ed9a`。没有切换其他 worktree；代码、测试与脱敏说明纳入本次本地提交，原始日志仅留本地。

## 行为与兼容性

- USB App 客户端删除 PSK/Keychain 读取、challenge/HMAC；设备删除 NVS 初始化与凭据读取。连接直接返回 `PA2 READY 0/1`，PING 校验双向通信。没有硬编码密钥。
- 设置页说明 USB 无需配对，旧 Host PSK 收进折叠项。模型 API key、旧 Host TLS PSK 与签名配置不变，未读取或删除已有钥匙串内容。
- 新版本不访问 NVS、不写 eFuse、不配置安全启动/Flash 加密；普通固件替换即可更换通信行为。并非不可逆的硬件设置。
- PA1 与 PA2 不兼容，需更新 App 和固件。新 App 收到旧板的 `PA1 LOCKED` 会报协议不匹配，不把它显示成已连接。
- 命令 ID、有限去重、received/executed 两阶段回执、超时撤销、单 STOP 与断连释放保留。每次新连接都必须先收到 PING，才允许输入。
- 系统采集/本地网络权限、帧有效性、实际发送处的一次性许可、逐动作确认和上传截图的选择继续有效。无 PSK 的设备本身不能核实人工批准，其他客户端可直接调用它。
- 仍为 USB 本地静态 IP，不加 Wi-Fi/BLE、DHCP、默认网关、VPN 或调试 CDC。

详细线格式见 [PROTOCOL.md](PROTOCOL.md)。

## 本机验证

| 验证 | 结果与范围 |
| --- | --- |
| C 协议/幂等/HID 时序 | 严格编译，AddressSanitizer + UndefinedBehaviorSanitizer，通过原有解析/回执/释放检查 |
| 生产 C server 的 localhost TCP | 14 项通过：无凭据 PING/STOP、NCM-only 拒绝输入、旧 AUTH/签名拒绝、分片/合并行、首次输入需 PING、ACK 并发、重复/过期/冲突 ID、心跳丢失、USB epoch 撤销、超长/异常格式 |
| iOS Simulator | 115 项单元测试 + 1 项设置/控制调试页 UI 回归通过。新增 PA2 greeting 版本隔离、严格 ACK 格式测试；既有帧/动作许可/后台/停止测试通过 |
| iPhoneOS | iPhoneOS 27.0 无签名构建通过；没有安装 App 或调整签名账户 |
| 固件 | NCM-only 与 NCM+HID 均构建通过，描述符与 build graph 核对通过：分别 2/3 个接口，3/4 个端点，没有 Wi-Fi/BLE、DHCP、转发 |

实际工具版本：Xcode 27.0 / 27A266a，iPhoneOS SDK 27.0 / 24A430，Swift 6.4（项目 Swift 5 模式）；ESP-IDF 5.5.5，Xtensa GCC 14.2，Python 3.12.13；锁定 esp_tinyusb 2.2.0、TinyUSB 0.21.0~2。没有安装新依赖，SPM 缓存从既有 integration 目录只读复制到本 worktree。

现有构建警告仍包括 StatusPiP 的弃用 API、旧 TLSBridge 的 Swift 6 并发迁移提示和界面旋转配置；构建结果成功，不声称零警告。

日志：`.build/validation/no-psk/{build-ncm.log,build-hid.log,ios-tests.log,ios-device-build.log,descriptors.json}`。测试包：`.build/ios/Logs/Test/Test-PhoneAgent-2026.10.04_19-14-04-+0800.xcresult`。可追踪摘要见 no-psk-validation-20261004.log（本地文件 `evidence/no-psk-validation-20261004.log`，已忽略）。

用户原有 `project.pbxproj` 与 `Localizable.xcstrings` 未提交改动保持不变，前后 combined diff SHA-256 均为 `542493a165474b6bc45b2f2c8781129fabc8af1f8037e5ad32fd28912bf7f27f`。

## 新 NCM-only 候选镜像

已冻结到 `.build/device-candidates/pa2-no-psk-20261004/`，含三段镜像、逐文件摘要、源码 patch 和原始准备清单 `flash-review.json`。后续用户批准并完成烧录；实际执行清单位于 `.build/device-backups/pa2-ncm-flash-20261004-rwj12ctt/flash-review.json`，状态为 `flashed_com_startup_verified`。原始候选清单保留准备时状态供追溯。

| 镜像 | Offset | 字节 | SHA-256 |
| --- | --- | --- | --- |
| bootloader.bin | 0x0 | 20832 | `36648b8a0d4337a3ee76d162d25ba8cf340d8b8ad28f0bf030d08b8949cbaaae` |
| partition-table.bin | 0x8000 | 3072 | `7f00b6c042a89b15b0cac534f82ed988caf29278ff5700b0c511eb1b5bb7c820` |
| phoneagent_usb_device.bin | 0x10000 | 353984 | `1cb9c43a136a252f91a2586f22a1a5d7697469bfafa1295b59995b404d8ee741` |

按扇区计算的写入范围为 `[0x0,0x6000)`、`[0x8000,0x9000)`、`[0x10000,0x67000)`，不覆盖 NVS/PHY 分区。NCM+HID 仅编译检查，不在本次候选目录中；其 App 为 357072 字节，SHA-256 `0da58a455b818d57741b707b96afad1c1fc6ebe42afed1449afd8be8cc11e55a`。

## 真机状态与下一步

**2026-10-04 19:34（Asia/Shanghai）PA2 免 PSK NCM-only 已通过 COM 烧录，并通过启动检查。** 用户先明确确认“只有 COM 接 Mac，同意烧录免 PSK 版”。目标与首次 PA1 烧录是同一块 ESP32-S3 rev v0.2、16 MB Flash，串口 `/dev/cu.usbserial-<port>`。

先读取当前 `[0,0x80000)` 的 512 KiB 原始备份并完成设备端摘要校验。115200 首次读取在约 56% 处遇到损坏数据，改用 57600 后重新完整读取、校验成功。备份包含本次全部写入区域及原有 NVS，保存在 Git 忽略的执行目录内，没有解析或展示其中的凭据内容。

用户在此次烧录后调整了后续流程：已知且可由源码重建的固件，不再每次读回备份；按 [固件 README 的烧录约定](../../firmware-device/README.md)执行。本页的备份步骤仅记录此次实际操作，不是未来每次烧录的要求。

57600 下首次压缩写入完成 bootloader、分区表及各自校验，但 App 在约 8% 处报设备停止响应。保留已验证备份后，使用同一镜像、同一 App 范围，以 **57600、ROM `--no-stub --no-compress`** 恢复完整 App 写入，设备端摘要校验通过。没有扩大擦写范围、全片擦除、写 NVS 或修改 eFuse。后续串口写入优先沿用此次成功的 ROM 小块方式；当前不能把 115200 称为稳定速率。

UART 115200 捕获 15 秒：TinyUSB 正常启动，日志包含 `NCM only; 192.168.7.1:28766; PA2 no PSK; no radio/DHCP/default route`，未观察到 panic。监视器正常退出（exit 0），COM 已无打开进程。App version 仍是 ESP-IDF 从历史 tag 生成的截断 Git describe；镜像身份以本页摘要、执行清单及启动 ELF 摘要 `d3d1b6077...` 为准。

本地摘要见 pa2-ncm-flash-20261004.log（本地文件 `evidence/pa2-ncm-flash-20261004.log`，已忽略）。烧录当时手机未接入板，未发送 HID 输入或上传屏幕。随后用户手动构建安装 App，并报告 PA2 下以太网存在且配置为 `192.168.7.2 / 255.255.255.0`；TCP 连接仍失败，具体状态见下节。

1. NCM-only 烧录及 UART 检查已完成，HID 仍未烧录。
2. 配套 App 需使用 PA2 新构建；签名安装按用户已批准的流程处理，不能因无签名构建成功就声称已安装。
3. COM 断开后再接 iPhone 原生 USB，保持既有固定 IP；App 前台处理本地网络权限，点“连接 USB NCM”，以“USB NCM 双向 PING 已验证（免 PSK）；固件未启用 HID”为首次网络验收目标。无需配置 PSK、无需采集授权或模型调用即可验证 PING。
4. 后续才进行 HID 与实际采集/Agent 验收。已有重复 STOP 覆盖回执的竞争问题未在本次修复，须在 HID 验收前修复并回归；重复心跳和旧 checkpoint 迁移审计事项也不属于此次免 PSK 改动。

本机通过不等于手机已受控。iPhone 上的 PA2 TCP、系统采集、HID 映射、拔线/睡眠恢复、蜂窝/VPN 共存及后台闭环仍未验证。

## iPhone 首次连接诊断 · 2026-10-04

用户已自行重新构建并安装 App。当前手机报告 USB 以太网存在，固定 IP 为 `192.168.7.2 / 255.255.255.0`，但 PhoneAgent 不在“隐私与安全 → 本地网络”列表中。App 显示 `POSIXErrorCode(rawValue: 50): Network is down`，尚无 PA2 greeting/PING 成功证据。以太网枚举不等于 TCP 可达；这条 POSIX 错误单独不能确定是权限、接口选择还是路由问题。

本次只修改 App 的连接与诊断流程：

- 连接进度、失败和 PING 结果直接显示在 USB 按钮下方；不再显示到旧 Host 卡片或仅藏在页面底部。等待时有取消按钮。
- 原先首次 `NWConnection.waiting` 立即取消；现在仅在 TCP **从未接通**且无待处理命令时保留本次连接，最多等待 30 秒。TCP ready 后才开始 3 秒 PA2 greeting 计时。没有重建连接、回退到无线或自动重放输入。
- 初次连接/PING 期间允许系统弹窗引起的短暂 inactive。真正进入 background、锁屏、手动取消，以及已连接会话原有的失效条件仍会停止；工具与截图授权不变。
- 网络回调取消前保存 `currentPath`，显示 status、unsatisfiedReason、可用接口名/类型与 IPv4 能力。`localNetworkDenied` 文案为“尚未获准”，不把未决定误称为用户拒绝；`notAvailable` 也不直接归因于线材故障。
- 输入已发送时，网络失败和并发 PING/STOP 超时仍保留“执行结果未知”，不误报未执行。

依据 [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)：首次本地访问可能在用户回答前进入等待；Network framework 支持等待连通性，并通过 `currentPath.unsatisfiedReason` 报告 `localNetworkDenied`。文档也说明 Simulator 不支持本地网络隐私验证。以上代码问题已修正，但尚不能认定它们就是这台 iPhone 的全部故障原因。

下一步：用户重新 Run 安装本次 App，保持原生 USB 接 iPhone、COM 断开及现有固定 IP；在前台点“连接 USB NCM”。如出现系统权限提示，选择允许；若仍失败，提供按钮下方完整路径诊断。目标仍是“USB NCM 双向 PING 已验证（免 PSK）；固件未启用 HID”。无需重新烧录固件或为 PING 开启屏幕采集/模型上传。

本次最终验证：119 项单元测试 + 1 项 USB/采集 UI 回归通过；iPhoneOS 27.0 `CODE_SIGNING_ALLOWED=NO` 构建通过。单元测试覆盖初次 inactive 允许/后台禁止、已有会话 inactive 禁止、未发送输入的网络错误与已发送输入的未知结果、并发心跳超时。UI 核实状态紧邻连接按钮、采集/上传默认许可关闭。中间一次 UI 检查因新增文本选择扩大可访问性边框而失败，移除该可选功能后完整重跑通过，没有放宽断言。

最终日志为 `.build/validation/no-psk/usb-connectivity-final-tests.log` 与 `usb-connectivity-device-build.log`，测试结果包 `.build/ios/Logs/Test/Test-PhoneAgent-2026.10.04_20-08-40-+0800.xcresult`；可追踪摘要见 usb-connectivity-20261004.log（本地文件 `evidence/usb-connectivity-20261004.log`，已忽略）。实际构建 Info.plist 的 Bundle ID 为 `com.ja1chen.PhoneAgent`，包含 `NSLocalNetworkUsageDescription`；没有新增权限、Bonjour 发现或更改网络路由。

本次没有手工编辑或回退用户的工程/本地化文件。诊断开始及模拟器测试后的 combined diff SHA-256 为 `8bf1d76df83f1c855fc022c74782a35c35158fc9c65edaa14649c72c1ab85d5e`；最终构建期间又观察到 project.pbxproj 在 20:10:22（Asia/Shanghai）更新，摘要变为 `566b2f4cf85cfd108cd88027ce1c38a2575e39263bc9cdb33f38bd3ff66efd4a`，该现场变化已保留。Localizable.xcstrings 的修改时间仍为 19:40:28，未回退。此阶段的源码修改保留在 `with-esp/main`，未推送。此次没有烧录、安装真机 App、系统权限操作、HID 输入或屏幕上传。Simulator 测试不能证明真机授权弹窗、30 秒等待期间的系统网络恢复或 iPhone PA2 收发成功。

## 可复制 USB 诊断日志 · 2026-10-04

用户仍遇到超时，Xcode 控制台还有 `nw_connection_copy_current_path_block_invoke ... Connection has no endpoint handler`。这条日志不足以确定网络失败原因。本次删除 USB 客户端所有主动 `currentPath` 读取，改为缓存 `NWConnection.pathUpdateHandler` 回调；不再在 setup/cancelled 回调中查询尚未建立或已拆除的 endpoint handler。

重新安装 App 后，在“设置 → 控制调试 → 真实模型”点“连接 USB NCM”，复现失败，再点按钮下方的 **复制 USB 日志**，即可整段粘贴。也可点“查看日志”，查看快照并刷新/复制。复制和查看日志本身不会发起连接、执行输入或启动采集。首次导出的标识应为 `revision=usb-diag-20261004-1`。

日志包含：

- App Bundle/版本、诊断代码版本、真实 OS/build、SDK 和用途说明是否存在；用途说明存在不等于系统已经授权。
- UTC 毫秒时间、进程内单调耗时、事件序号、每次连接编号，以及实际连接参数。
- NWConnection 全部状态、viability/betterPath 回调，connection/system.default/system.wired 三种路径来源。两个系统路径监视器只作对照，不是设备端点可达性证明。
- 接口名和 up/running/broadcast/pointToPoint 标志；显示 `192.168.7.0/24` 与 IPv4 link-local 地址/掩码，其他 IPv4 地址脱敏。不读取或输出 MAC、SSID、IPv6 或系统 VPN 配置。
- PA2 greeting 校验、命令 ID/类别、本地 send completion 与设备 ACK 的区别、回执阶段/耗时、超时位置、未完成请求、停止/前后台/锁屏事件与关闭时收发计数。

只记录元数据，不记录命令参数/坐标、原始接收内容、任务正文、模型请求、截图或密钥。初始几个及每第 25 个 PING 记录详细收发，其余由关闭时计数概括；错误/超时始终记录。单行长度及最近 600 条事件均有上限，丢弃数量在头部显示。

复制缓冲保存在本次进程内，重启 App 会清空，复现后应先复制。相同安全事件也写入系统 `OSLog`，subsystem=`com.ja1chen.PhoneAgent`，category=`USBNetwork`，方便 Xcode/Console 查看；系统日志保留行为由 OS 管理。日志记录安排在健康失效处理之后，动作发送日志在最终许可的加锁区域之外；诊断不改变超时/授权/断连停止、接口绑定或 PA2 协议。

本次仅修改 App，ESP32 不需重烧。真实 iPhone 路径、权限状态、PA2 收发和超时根因仍待用户导出的日志确认。

该日志版本已通过最终 122 项单元测试、1 项 USB/采集/日志 UI 回归，以及 iPhoneOS 27 无签名构建。新增回归覆盖并发日志写入与有界保留、跨连接编号、单行控制字符处理、命令参数/无关 IP 脱敏，以及连接被前台限制拒绝时仍可导出日志。UI 测试实际点击复制/查看，验证日志内容与版本标识、并确认导出不建立连接；已检查模拟器截图。没有真机网络成功证据。

最终日志：`.build/validation/usb-diagnostics/ios-final-retest.log`、`ios-device-build.log`；结果包 `.build/ios/Logs/Test/Test-PhoneAgent-2026.10.04_20-26-31-+0800.xcresult`。摘要见 usb-diagnostics-20261004.log（本地文件 `evidence/usb-diagnostics-20261004.log`，已忽略）。本次开始即保存工程、Info.plist、Localizable.xcstrings 的已有状态，最终按字节核对均未变化；没有切分支或覆盖这些用户改动。代码保留在 `with-esp/main`。

## VPN 对比与具体接口绑定 · 2026-10-04

**后续真机反馈：用户确认新版 App 已显示“USB NCM 双向 PING 已验证”。** 这为当前手机与固件的 PA2 双向收发提供了用户观察证据；尚未收到成功连接的完整日志，因此实际 `binding.selected` 类型和权限过程未核实。也未单独验证本次改动中“去除类型限制”“指定接口”“指定本地地址”各自的影响。不能仅凭成功断言旧代码把 USB 误识别为 other。下文保留修正时的验证状态；HID、拔插/睡眠恢复、VPN 共存和后台闭环仍待验证。

用户先后提供 21:08:39 与 21:11:54（Asia/Shanghai）的控制台日志，后一次由用户手动关闭 VPN、重启 App 后连接。两次均能通过 `getifaddrs` 看到 `en3` 已启用、运行中，地址为 `192.168.7.2/24`。默认路径从包含 `utun5` 变为 Wi-Fi/蜂窝；但 `system.wired` 和实际 connection 仍为 `unsatisfied/notAvailable`，连接仍报 ENETDOWN，未出现 `tcp.ready`。因此关闭该 VPN 没有解决问题；日志没有报告 `localNetworkDenied`，不能据此认定用户拒绝了权限，也不能证明固件 TCP 服务异常。附件只有连接初始片段，没有本次 30 秒超时的尾部。

新诊断版本为 **`usb-diag-20261004-2`**。App 将笼统的 `requiredInterfaceType = .wiredEthernet` 改为解析本地固定 IP 所属的具体接口，并设置 `requiredInterface` 和 `requiredLocalEndpoint`。这是针对接口枚举与 Network 路径结果不一致的修正尝试，尚未证明是故障根因或已在 iPhone 接通。

- 按 `192.168.7.2` 找唯一接口，不写死 `en3`；检查 `/24`、有效索引、UP/RUNNING/BROADCAST、Ethernet 链路类型，拒绝 loopback/point-to-point。缺失、歧义或状态不符均明确失败。
- 通过公开的 `IPv4Address` 字符串初始化器解析带 `%接口名` 的地址，再核实远端/本地地址关联的接口名和索引均匹配。Network 类型只接受 wiredEthernet 或通过上述链路检查的 other；拒绝 Wi-Fi、蜂窝与 loopback。链路类型检查不是 USB 硬件身份认证，PA2 仍为用户选择的免 PSK 协议。
- scoped 字符串行为已在本机 Network runtime 和 iOS Simulator 回归验证。Apple 的初始化器文档未明确描述 `%接口名` 语法；因此运行时必须检查解析结果，失败时不回退成无接口约束的连接。仍需 iPhone 实测。
- 不修改系统默认路由、IP、网关、VPN 或权限设置。系统策略仍可拒绝连接；初次等待、之后的断连停止、输入审批和 ACK 语义保持原有规则。
- 日志新增 `binding.candidate`、`binding.selected`、`binding.rejected`，包含接口索引、类型和选择原因，帮助区分接口选择失败与后续 TCP/PA2 失败；不记录 MAC 或实际屏幕。

最终验证：**127 项单元测试 + 1 项 UI 测试通过，iPhoneOS 27 无签名构建通过**。5 项新增单元测试覆盖固定 IP 选择、缺失/歧义/错误链路拒绝、无线类型拒绝、scoped 地址与参数对象、过期索引及伪造链路标志拒绝。参数测试不建立 socket，不访问设备。工程文件、Info.plist、本地化文件相对本次开始时快照按字节未变化。

构建日志：`.build/validation/usb-interface-binding/{ios-tests.log,ios-device-build.log}`；结果包 `.build/ios/Logs/Test/Test-PhoneAgent-2026.10.04_21-16-48-+0800.xcresult`。证据摘要见 usb-interface-binding-20261004.log（本地文件 `evidence/usb-interface-binding-20261004.log`，已忽略）。改动位于 `with-esp/main`，实现基线 `883d0e8e61e62b2c9db3361985dc43c9db45ed9a`；未推送。

下一步由用户重新构建并安装 App，COM 断开后接原生 USB 到 iPhone，保留既有固定 IP。在前台点“连接 USB NCM”，如有本地网络提示则由用户确认；等成功或本次 30 秒等待结束，点“复制 USB 日志”，在重启 App 前提供完整报告。报告应含新版 revision 和 binding 结果。无需重烧 ESP32，也无需开启屏幕采集或模型上传。实际手机 TCP/PING、HID、VPN 共存与后台闭环仍未验证。

## App 截图与 USB 输入分离 · 2026-10-04

用户在确认双向 PING 后，让 Agent“查看屏幕”，仍收到“设备未连接……连接桥接”。代码检查发现：`AgentViewModel.send` 原先用 `usbClient` 是否存在决定是否选择 App 采集路径；客户端不存在就回退到旧 TLS/UnavailableBridge，即使 App 已有采集帧也不能单独截图。另一个状态问题是任务结束清空了客户端，但没有清除“PING 已验证”的界面状态。这些是已确认的代码缺陷；未读取本次真机事件日志，不能确定用户此次客户端失效的具体时点。

修正后，每轮分别选择本机读取与 USB 输入能力：

- 系统采集已授权时优先读取 App 的 `LatestScreenFrame`，不需要 ESP32 或 HID 固件，也不会为了截图发送 USB 命令。无 USB、NCM-only 或输入健康条件失效均可选择只读路径。
- 按用户后续要求移除独立截图上传开关：用户开始模型任务后，screenshot 可按需发送系统已授权的画面。系统采集授权仍必须由用户确认；授权本身不会调用模型，仅本机预览也不会上传。
- 只读路径拒绝点击/拖动，并在动作审批前说明 USB/HID 尚未就绪。允许后台时可申请仅用于截图任务的有限执行资格，不授予 USB 输入能力。
- 已就绪的 HID 控制任务沿用原 `ScreenUSBExecutionContext`，保留逐动作批准、帧/会话校验、动作后新帧屏障和 USB 失效停止。不会在运行中自动把只读任务升级为控制任务。
- 读取器绑定本次采集会话，拒绝过期画面、换代采集和取消后的读取。停止本轮读取不关闭用户的系统采集会话；系统采集丢失则停止使用该画面的任务。
- 任务结束明确关闭其 USB 客户端并更新界面为已断开。授权不足时引导“授权全屏采集”，不再笼统要求连接桥接；系统提示词同步区分截图与输入来源。

真机操作：安装更新后的 App，在“设置 → 控制调试 → 真实模型”授权全屏采集，先点“仅在本机预览截图”确认画面。要让模型查看时，返回会话发送“查看屏幕”。此步骤无需重烧 ESP32 或连接 USB，也无需再开截图上传开关。真正的 iPhone ScreenCaptureKit 授权、采集与跨 App 行为仍需由用户验证，不能用模拟器合成帧替代。

本次回归与编译输出仅保留在 Git 忽略的 `.build/validation/local-screen-route/`；可读结果见 [VALIDATION.md](VALIDATION.md)。没有访问设备串口、上传实际屏幕、更改签名设置或新增系统权限。


## 首帧等待、后台偏好与停止采集 · 2026-10-04

用户报告已授权但“采集尚未提供画面”、返回设置后开关关闭，以及停止时系统报 `SCStreamErrorDomain -3808`。此次检查确认以下代码路径，实际 iPhone 样本是否还存在其他问题需新版日志判断：

- 旧只读桥在初始化时调用要求已有帧的 `sessionID()`，并永久保存失败的 nil；之后首帧到来也无法恢复。现在绑定已授权的采集 epoch，截图/本机预览最多等待 5 秒，停止、取消、换代立即失效。首次等待不会放宽 USB 输入所需的新帧校验；已观测到的失效不会被迟到帧恢复。
- 接收器原先只接受 `.complete`，忽略 `.started`。本地 iOS 27 SDK 将 `.started` 定义为首帧，现在两者均需有效像素、PTS 和 `videoOrientation` 才入缓存，仍不把 idle 当新帧或猜测方向。状态区分“启动完成等待首帧”和“已收到画面”。
- “切换 App 后继续采集任务”现在是保存到本机 UserDefaults 的偏好，对下一轮生效；停止或完成只撤销执行资格，不改用户选择。纯截图任务无需 USB 也可使用有限后台资格，每段最多 60 秒、总计 300 秒。锁屏/会话丢失/画面过期仍终止，偏好不等于永久后台许可，也不会自动重启任务。
- 旧系统 `didStopWithError` 回调、启动失败清理又调用 `stopCapture()`；用户停止还先关闭 picker，可能与流停止竞争。现在用共享生命周期状态区分系统已停止、启动中待停止、正在停止，SDK stop 每个流至多请求一次，且流停止后才关闭 picker。系统停止/启动失败只清理，不再次 stop；旧回调不能结束新流。无法消除系统自主停止恰好与唯一一次请求同时发生的竞争；此时 -3808 作为已结束处理，不重试，其他停止错误仍显示错误码。
- “复制诊断日志”保留最近 600 条采集/USB 元数据；采集每 2 秒汇总 `samples`、`accepted`、`sequence`、`age` 及 `missingAttachments` / `missingStatus` / `missingPixelBuffer` / `missingVideoOrientation` / `invalidTimestamp` / `idle` 等原因。记录 start、stop 和系统错误码，不记录像素、附件原文、任务正文或模型密钥；导出不会建立连接或上传屏幕。

复测只需重建安装 App，不烧录 ESP32。授权全屏采集后先点本机预览，再发送看屏任务；切换设置检查后台偏好保留，最后测试停止采集。若仍无画面，在重启 App 前复制诊断日志。iPhone 真正的 `.started`/`.complete` 附件、方向、静态屏幕、锁屏恢复及跨 App 执行尚需实测，模拟器合成帧与编译不能替代。


## videoOrientation 附件读取修正 · 2026-10-04 22:29

本次用户的完整诊断中，采集启动后持续收到样本，最终累计 `samples=781 accepted=0`，全部被旧 `missingVideoOrientation` 分支丢弃。该分支已经经过状态和像素缓冲检查，所以可确定拒绝发生在 App 的方向解析环节；不能再解释为系统没有送帧。旧日志把字段不存在与无法解析混为一种原因，尚不能仅凭该日志判定手机实际把方向放在哪一层。

检查发现旧接收器只查 `CMSampleBufferGetSampleAttachmentsArray` 的每 sample 字典，漏查 `CMSampleBuffer` 自身附件。CoreMedia 的这两类附件存储不同；[CMGetAttachment](https://developer.apple.com/documentation/coremedia/cmgetattachment(_:key:attachmentmodeout:)) 从目标缓冲区取得附件，[SCK videoOrientation](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/videoorientation) 的值使用 CGImagePropertyOrientation。

现在使用同一个公开 `SCStreamFrameInfo.videoOrientation.rawValue` 同时查询 sample 字典和 `CMGetAttachment(buffer, ...)`。只采用该帧有效的 1…8 整数方向；缺失、非法类型/数值、两处方向冲突分别拒绝。不使用 UIKit 当前方向、缓存上一帧方向、默认竖屏、私有键或 ReplayKit 采集。

启动日志版本为 `metadataReader=sck-orientation-2`。每次既有汇总新增类似 `orientation=[sample=absent buffer=number:6 source=buffer]`；source 可以是 buffer / sample / both。拒绝分为 missing / invalid / conflictingVideoOrientation。仅输出方向值、类型和来源，不输出附件字典、任意字符串、屏幕内容或新增设备标识。

四项新增回归使用真实 CoreMedia `CMSampleBuffer` 与 `CMSetAttachment`，验证：buffer-only 方向在旧 sample 查找中确实不可见但可被新读取器编码，全部 8 种方向的输出尺寸；sample-only 与双层相同值；冲突/非法值不得回退；诊断脱敏及采集换代隔离。**完整 144 项单元测试一次通过，iPhoneOS 27 无签名编译通过。** 本轮未改 UI 操作流程，未重跑 UI 测试。日志与结果包见 [VALIDATION.md](VALIDATION.md)。

真机需用户重新构建安装后授权、点本机预览，成功标准是 `accepted` 和 `sequence` 增长且预览方向正确。若仍 accepted=0，应复制带 metadataReader / orientation 字段的完整新报告；它能区分键缺失、值格式不符或来源冲突。当前已证明代码能处理 buffer-level 方向，尚无新版 iPhone 接收成功证据。无需烧录 ESP32。
