> 后续主线集成已保留通用 BGContinuedProcessing 能力，并与 SCK 共用一个生命周期协调器；当前范围见 [集成记录](../integration/INTEGRATION.md)。本文保留该阶段的设计与验证历史。

# 有限后台执行与已有 worktree 复用 · 第二阶段

> 历史记录：本文的 PSK 设计已被用户 2026-10-04 的“USB 免 PSK”选择取代。当前 USB 使用 [PA2 协议](PROTOCOL.md)，无需配置 NVS/Keychain，测试与升级状态见 [NO-PSK.md](NO-PSK.md)。本文旧测试数据与授权记录保留供追溯，不再作为当前配置指引。

首阶段 `18fac1158b35951aa531cdf1b214087f93b4e990` 保留前台限制的原因是**尚未接入后台执行资格**，不是发现 ScreenCaptureKit 禁止该用途，也不是缺少用户对代码修改的授权。本阶段在同一 `feature/ios27-usb-device-capture` worktree 补齐衔接。没有烧录、签名、安装真机 App、读取或生成密钥、改变其它 worktree，或上传真实屏幕。

## 只读比较与选择性复用

来源：`<workspace>/with-esp-background-runs`，`feature/background-runs`，提交 `2509d7098fc8a3af4c62bd8fc20e911df4aa4933`，共同基线 `b3724382d5161555f0130fa984f72f251e7a07d8`。比较时源 worktree 干净；通过读取该提交的文件选择性移植，未合并分支、切换源分支或改动源文件。

| 已有模块 / 行为 | 本阶段处理 |
| --- | --- |
| RunLifecycleCoordinator、RunBackgroundLease / Scheduler 接口 | 移植并继续作为唯一的运行生命周期和事务协调器。以 ScreenCaptureRunScheduler 适配 SCK / USB 有效上下文。 |
| RunCheckpoint、Store、prepared → dispatching → acknowledged / observedResult | 移植；发送调用前必须保存 dispatching，写失败禁止继续。文件改为 `usb-run-checkpoint-v1.json`，保留完整文件保护、排除备份，不扩大锁屏访问。 |
| 进程退出后的 dispatching → outcomeUnknown | 移植；启动仅展示记录，不恢复 lease、审批 continuation 或动作，不自动重放。 |
| callID、参数摘要 / SHA-256、generation、设备上下文复验 | 移植到 ActionCoordinator；保留本分支帧序号、时间戳、尺寸和方向元数据。 |
| 审批等待结束执行片段、前台明确批准再申请片段 | 移植；SCK 流及健康检查可继续，但 Agent 等待 continuation，不发送输入。审批只能在前台且受保护数据可用时接受。 |
| 到期、60 秒无有效模型 / 工具响应、停止、迟到回调隔离 | 移植。USB 额外受单调时间的每段后台 60 秒 / 总计 300 秒、帧和心跳期限约束。 |
| 生命周期安全测试 | 移植原 12 项协调器 / 检查点测试。原 FakeScheduler Agent 集成测试没有冒充 SCK 测试；另增真实 Agent + 合成采集 / USB 夹具的适配测试。 |
| ContinuedProcessingScheduler / BGContinuedProcessingTask、Info.plist 注册 | **不移植**。此路线使用用户授权的全屏采集上下文，无 BGTask 注册、额外权限或后台音频。 |
| 原 TLSBridge 的取消传输与设备上下文实现 | 不覆盖本分支既有 Host 路线；TLS、Demo、Unavailable 路线仍前台限定。 |

原分支的 BGContinuedProcessingTask 是系统实际回调授予的有限处理片段：成功 submit 不等于 lease，模型处理能否后台继续与设备工具是否支持后台是两项独立判断。原 TLSBridge 没有覆写默认 `supportsBackgroundExecution = false`，所以该分支不能被描述为已经支持真实 TLS 工具后台控制。

新的 ScreenCaptureRunLease 则是**App 内部可撤销的执行资格**：适配器核验 SCK 会话和 USB 后交给同一个协调器；它不是新的系统后台任务，也不能让已挂起的进程恢复调度。`UIBackgroundModes=screen-capture` 支持全屏流不等于已证明模型请求、TCP 心跳、Swift Agent 全部能在真机持续运行。

## 执行资格和审批往返

1. 用户在前台通过系统 picker 确认全屏采集，建立经过 PSK 认证的 USB NCM 连接。后台开关和截图上传开关默认关闭、只作用于本次运行、停止后清空。开始时必须有活动采集和新帧，USB 最近一次认证 PING ACK 不超过 750 ms。
2. 开启本次后台路线后，第一张 Agent 截图等待用户切到目标 App（15 秒上限），并等切换后至少 200 ms 到达的新 complete 帧。不会把刚开始时 PhoneAgent 自身画面作为后台目标截图。
3. 模型提出一次 tap / drag 后，协调器保存待批准工具，结束输入执行片段；Agent 在 continuation 等待。之前的动作只有完成释放并收到 executed ACK 才会进入下一步，所以等待期间没有允许保持按下的动作。PING 仅保留健康检测，不构成输入授权。
4. 用户返回 PhoneAgent 前台查看该工具和截图，批准绑定的 callID / 参数 digest / imageID。后台调用 approve、旧 generation、锁屏或保护数据不可用均不能批准。拒绝和停止终止本轮。
5. 批准后台画面动作时，仍**不立即发送**。桥等待用户在 15 秒内返回目标画面，批准帧总年龄不能超过 45 秒；重新取得新 complete 帧并比较旋转缩放后的完整 PNG SHA-256、源尺寸和 orientation。只有匹配才准备一次性输入许可。实际 NWConnection.send 前再核对 epoch、场景代际、单调时限、USB 心跳以及匹配帧仍为当前最新帧；场景改变、停止或更新帧抢先到达会拒绝发送。
6. 发送前检查点为 dispatching；只有协议的 received → executed 顺序才算送达。下一张截图要求到达时间和序号均在 executed ACK 之后；observedResult 表示取得了后续画面，不证明目标业务操作成功。

完整 PNG 匹配非常保守：时钟变化、动画、视频、转屏、目标画面变化或编码期间到达更新帧都可能阻止发送。这不是通用的前台 App 身份识别；两个完全相同的画面也不能证明来自同一个 App。必须在真机评估这些拒绝条件和输入延迟，不能为提高通过率跳过审批或使用旧画面。屏幕内容不能扩大工具权限，高风险操作仍由现有工具策略拒绝。

ScreenUSBExecutionContext 是线程安全的可撤销能力及最后发送栅栏，不持有第二份 run / checkpoint 状态。USBInputPermit 只能消耗一次。观察到失效后，迟到的新帧或 PING 不会恢复旧上下文。

## 停止与故障

- blank / suspended / stopped 回调立即清空帧；2 秒没有新 complete 帧、采集 epoch 改变、USB 失败或超过 750 ms 无有效 PING、后台 60 秒 / 总计 5 分钟到期都撤销执行资格。静态画面只收到 idle 时也会停止，不把 idle 当新帧。
- App 内健康检查间隔 100 ms，桥接检查 200 ms；每次发送还有同步最终检查。这里“停止”指一旦观测到失效立即封锁新输入；不能保证系统不调度 App 时仍按这些时间运行。
- 停止先撤销许可并取消 Agent / 模型工作，再写历史、异步发送 STOP 和断开。固件维持已有的 750 ms 输入心跳约束、2500 ms 动作上限及失联后全释放逻辑。USB 总线不可用时不能声称已经物理释放，恢复后必须先发送中性报告。
- 锁屏通过保护数据通知 / 状态和 SCK blank / suspended、帧期限封锁；解锁、回前台或重连不自动恢复。准确通知时序和 App 挂起期间行为仍需真机验证。
- 结果未知会持久化并终止本轮。`dispatching` 在进入桥调用前保存，包含尚在等待返回画面的窗口，因此中断后可能保守标为 unknown，即使没有真正入队；不会把它当执行成功或自动重发。
- 前台批准最长仍受 45 秒截图年龄限制；即使用户迟迟不批准，后台 60 秒、整体 5 分钟及采集 / 连接检查继续生效。审批不会无界续期后台执行。

## PSK 为什么存在、配置需要哪些授权

PSK 不是 USB NCM 或 iOS ScreenCaptureKit 的系统要求，是这个 HID 输入服务的应用层认证选择。网卡枚举和私有 IP 本身不能证明对端是用户指定的 App / S3；本地可达的程序也可能尝试发指令。每连接 challenge + 双向 HMAC 认证命令和 ACK，并绑定方向、会话与命令 ID，防止未认证调用、伪造回执和旧会话重放。也可以另行设计证书 / 公钥配对，但当前实现没有无认证降级。HMAC 不加密坐标；截图不走 USB。

本阶段只实现与测试代码，**没有生成、读取、打印、回传或写入用户真实 PSK**。将来配置需用户明确选择 / 提供 32 字节随机 PSK，并分别批准：

| 配置动作 | 精确范围 |
| --- | --- |
| App 前台“仅保存桥接 PSK” | 在既有 `SecretStore` service `dev.dotprototype.PhoneAgent`、account `bridge-psk-v1` 保存 64 位十六进制值。保持 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`；不增加 Keychain access group、共享 entitlement 或账号访问权限。空输入不覆盖。 |
| 设备 PSK 配置 | 对已确认物理板和端口，在用户批准的烧录 / NVS 配置流程中写 `pa_usb/psk` 的 32 字节 blob。涉及设备写入、备份及固件覆盖，当前没有获得执行授权。不得把密钥放源码、命令日志、构建包或回复里。 |
| 系统权限 / 签名 | Local Network 与全屏采集由用户在 iPhone 系统界面确认，与 PSK 相互独立。PSK 不需要新 App ID、签名账户、VPN、相册、音频或麦克风权限。真机安装 / 签名仍需按用户批准的既有流程处理。 |

当前复用了既有桥接 account；保存新 PSK 会替换该 App 的桥接值，可能影响原 Host 调试路线。因此未来配置前须明确确认所用桥接密钥 / 目标板，不能擅自覆盖现有配置。没有创建第二个凭据权限或修改主 worktree 正在调试的设备。

## 验证记录

工具链沿用首阶段：Xcode 27.0 (27A266a)、iPhoneOS 27.0 (24A430)、Swift 6.4 / Swift 5 language mode。Simulator SDK 没有 ScreenCaptureKit，因此全屏授权 / SCStream 真正回调不能在模拟器测试。固件与依赖未变更，首阶段两种真实 bin 和 ESP-IDF / TinyUSB 锁定版本仍有效；本阶段未重新包装或烧录固件。

最终设备目标无签名 build 成功；**75 项单元测试（含 12 项移植协调器测试、10 项新适配测试）和全部 9 项 UI 回归通过，0 失败**。摘要见 测试日志（本地文件 `evidence/ios-background-tests-summary.log`，已忽略） 与 设备构建日志（本地文件 `evidence/ios-background-device-build-summary.log`，已忽略），模拟器 UI 截图（本地文件 `evidence/simulator-usb-background.png`，已忽略） 显示两个许可开关均默认关闭。完整日志及 `.xcresult` 位于当前 worktree `.build/validation`、`.build/ios/Logs/Test`。新增用例只使用 CoreVideo 合成像素、DemoProvider 的内存脚本和假 USB transport，不访问外部模型、用户屏幕或真实 S3。

测试日志仍出现已有界面路径的 SwiftUI “Modifying state during view update” 警告，尚未定位；UI 用例通过并不消除该运行时警告。Xcode 在测试完成后收集额外模拟器诊断时提示其子进程找不到 simctl（全局 xcode-select 为 CommandLineTools），主 xcodebuild 返回 0 / TEST SUCCEEDED，xcresult 与截图均成功导出；未为此更改全局 Xcode 配置。设备 build 仅提示无 AppIntents 元数据可提取。

最终复核还修正了主动关闭竞态：先结束监视片段再撤销资格 / 等 STOP，以免延迟回执把正常完成误报为失联。已用 STOP 延迟 350 ms 的 Agent 集成用例验证，修正后重跑全部 75 单元测试及设备 build；9 项 UI 回归位于此内部关闭顺序修正之前，之后 UI 源码未变。

实际 iPhone 验收仍需要：先确认原生 USB 板口 / 供电路径并协调释放现有调试设备；用户另行批准 NCM-only / HID 烧录与 PSK 配置、App 签名安装；人工确认系统采集和 Local Network 权限。之后在无害测试画面上检查后台帧与 TCP 连续性、审批往返、精确画面匹配、旋转 / 锁屏 / 拔线 / 到期释放及现有 VPN / 蜂窝网络共存。编译与模拟器测试通过不等于 iPhone 已成功控制。
