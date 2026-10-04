# 有限后台运行片段 · 2026-10-04

本分支完成 App 侧租约、检查点、审批和取消状态机。它不构成真实 ESP / 同机跨 App 后台控制闭环；模拟器结果不能证明系统会在真机授予或维持后台时间。

## 隔离与构建基线

- 分支：`feature/background-runs`
- 工作树：`/Users/developer/Developer/AI/ios-use/with-esp-background-runs`
- 基线：主仓库已提交 `b3724382d5161555f0130fa984f72f251e7a07d8`
- 主线 ESP 未提交文件、`feature/siri-agent-entry` 和 `feature/live-activities` 工作树未修改；没有 merge/push、账户资源注册、真机安装或设备烧录。
- Xcode 27.0 (`27A266a`)，iPhoneSimulator 27 SDK，最低部署 iOS 17。BackgroundTasks adapter 使用 SDK 中标注 iOS 26.0 可用的 API；更旧系统仅前台执行。
- 构建使用本工作树的 `ios-app/DerivedData`，模拟器使用 `com.ja1chen.PhoneAgent.BackgroundValidation`，生产 Bundle ID 仍是 `com.ja1chen.PhoneAgent`。
- 默认 `xcode-select` 是 CLT，XcodeBuildMCP 的 simctl 查询失败，因此构建/测试以命令局部 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 运行，没有改变全局开发者目录。

## 实现边界

`RunLifecycleCoordinator` 由 App 根部 `AgentViewModel` 持有，独立于会话 View。后台调度和存储均可注入；SwiftAgentKit、模型 provider、工具确认和 TLS 继续使用现有实现。

| 条件 | 行为 |
| --- | --- |
| 用户前台开始一轮 | 落盘新 run/generation，注册唯一片段 ID，立即提交请求 |
| 提交成功但 handler 未到 | 仅前台执行；离开即暂停并撤销请求 |
| 请求拒绝或 iOS <26 | UI 明确提示仅前台继续；不排队、不重试申请 |
| 实际 handler 授予有效 lease | 模型 CPU/网络可继续；每个工具仍需独立后台能力检查 |
| 当前工具未验证后台能力 | 即使有 lease，离开前台或后台准备此工具也暂停 |
| 等待单次批准 | 持久化 prepared 工具、摘要/参数哈希和 pending call ID，结束片段，整体状态仍 waitingApproval |
| 前台批准 | 再检查 45 秒截图有效期、桥接会话、image ID、参数哈希，才申请新片段并发送 |
| 拒绝、Stop、系统取消/过期 | fence 旧 generation、取消模型/Agent、同步关闭真实传输、保存检查点；lease completion 幂等 |
| 发送后失联 | tap/drag 记 outcomeUnknown 并暂停；不能自动重放 |
| 进程恢复 | 不恢复 lease/Agent/continuation；显示核对提示，等待新指令与新截图 |

桥接协议目前只提供 screenshot/tap/drag；没有新增 typing、Siri、LongRunningIntent、APNs、GPU、音频保活或自定义岛。已有 PiP 仍未启用后台音频模式。

### SDK / 标识规范

`Info.plist` 的 `BGTaskSchedulerPermittedIdentifiers` 是数组 `$(PRODUCT_BUNDLE_IDENTIFIER).backgroundRun.*`；`UIBackgroundModes` 只有 `processing`。每次片段使用新的 UUID 后缀；register 和 submit 使用完全相同的具体 ID，绝不只 register 通配字符串。每个具体 ID 仅注册一次。

`BGContinuedProcessingTaskRequest.strategy = .fail`，`requiredResources = []`。提交只代表请求被接受；只有真实 launch handler 返回的对象才设置 `hasLease`。旧片段迟到的 handler 会立即结束，不会重启 Agent。仅取消本片段 ID，不调用 cancelAll 影响其他功能。

依据：本机 `BackgroundTasks.framework/Headers/BGTaskRequest.h`、`BGTaskScheduler.h`、`BGTask.h`，以及 Apple 的 [Performing long-running tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados/) 与 [BGContinuedProcessingTaskRequest](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest)。当前 adapter 保持 iOS 26 提交接口；SDK 27 新的异步提交接口尚未迁移。

### 事务与恢复

检查点 `run-checkpoint-v1.json` 存在 Application Support/PhoneAgent，原子保存、首次解锁后可用且排除备份。包含 runID、conversationID、generation、segment/segmentID、工具 callID/name、数值参数摘要、参数 SHA-256、delivery、pendingApproval、最后已确认步骤和实际完成响应计数。没有模型文本、截图、purpose 原文、密钥或原始网络响应。

输入事务：`prepared → dispatching → acknowledged → observedResult`。`dispatching` 保存失败时不允许发送。只有 bridge 返回成功才确认 delivery；新截图可以推进已确认步骤到 observedResult，但它仅表示已有新的观察，不能证明目标 UI 效果成功。截图没有副作用，其普通失败会返回模型说明；无法确认的 tap/drag 直接暂停。进程中断的 dispatching 恢复为 outcomeUnknown。

重启后保存的 waitingApproval 是核对材料，不是可执行队列。不存在跨进程恢复旧审批或直接重放的按钮；必须重新获取截图与授权。运行中的真实 TLS 在等待审批且 App 离开前台时关闭；返回后旧连接/截图无法通过会话校验，因此需要重新连接与新截图。演示/fake bridge 可在同一进程、仍有效的合成截图上验证重新批准路径。

UI 历史继续使用完全文件保护；锁屏期间历史写入可能失败，返回前台会重试保存内存状态。最小运行检查点使用首次解锁后保护，避免降低完整对话或密钥的保护级别。原文件无法解码时保留并禁用执行；发送前存储失败则暂停。

### 进度与时间上限

系统 BGContinuedProcessingTask 的内建 UI 与本分支 App 状态文案同步，不依赖自定义 Live Activity。未知总步骤时使用 indeterminate Progress，副标题报告真实收到的模型响应/工具结果个数；不伪造百分比。只有模型完整响应和工具成功返回增加完成单位；实际非空文本只更新最后活动时间。SSE 注释心跳不产生事件，不增加完成单位。重复回调的 milestone 去重。

默认 60 秒无有效活动即暂停（协调器初始化参数可配置），不循环续租。现有单轮 300 秒总上限和 45 秒截图有效期仍保留；等待审批不占用后台片段，但过期的截图/任务不能直接继续。系统也可能比这些上限更早取消。indeterminate Progress 在真实系统 UI 的显示与系统停滞判定尚需真机确认。

### 截图能力核对

`TLSBridge.screenshot` 从已认证 ESP 通道请求 PNG、组装分块并校验，不使用 UIKit/ReplayKit 获取当前 App 屏幕。当前固件 v0.3 尚未实现这个 App TLS 通道；真正 CoreDevice 截图、目标锁屏状态和后台隐私限制未验证。因此 TLSBridge 的 `supportsBackgroundExecution` 明确返回 false；DemoBridge 的 UIKit 合成图片也默认仅前台。后台模型与纯本地 wait/finish 可在 lease 下执行，真实设备工具保持关闭后台能力，直到独立验收通过。

## 已完成验证

最终结果与可复现命令见 [验证摘要](background-runs/validation.txt)。新增 `RunLifecycleTests` 和 `BackgroundRunIntegrationTests` 使用 fake lease/model/ESP，并通过真实 SwiftAgentKit run loop 测试：申请拒绝、submit != lease、无租约暂停、工具能力门禁、过期/停止、重复/迟到回调、新 run 隔离、审批等待/拒绝/设备变更、进度冻结/超时、模型断网、dispatch 失联、磁盘失败、恢复不重放、completion 一次。ModelStreamTests 另验证 SSE 心跳不释放工具或响应。

UI 截图：[等待审批且片段已结束](background-runs/waiting-approval.png)。这是 Simulator 的离线合成演示界面，与 ESP 的远程截图工具无关。

复现（参数必须是已启动的 simulator UDID）：

```sh
ios-app/scripts/test_background_runs.sh <booted-simulator-UDID>
# 同时运行 UI 回归：
RUN_UI_TESTS=1 ios-app/scripts/test_background_runs.sh <booted-simulator-UDID>
```

脚本不启动/擦除模拟器，不安装真机，结果写入本工作树 `.build/background-runs/run.*/Tests.xcresult` 和 `tests.log`。

基线还缺失被 `secrets*` 规则忽略的 Keychain wrapper。本分支从已提交 `archives/PhoneAgent-iOS-source.zip` 恢复 `SecretStore.swift`，SHA-256 `0702d14580a628524801731819608c3f5e325dcce9c7165396fd0ef13ffcfdd2` 与原 SOURCE_MANIFEST 完全一致，并加精确源文件例外；没有从主工作区搬移未提交内容或读取账户密钥。

## 尚未验证与下一步

1. 未验免费开发者账号签名/entitlement 与真机 BackgroundTasks 实际授予、系统 UI/cancel、可持续时长；模拟器不能提供这些证据。
2. 未验 ESP App TLS 握手、真实远程截图、点击效果或后台网络会话；当前硬件通道缺失，不能声称同机后台控制闭环。
3. 未做真机安装、注册 App ID/App Group、读取凭据、烧录设备、自动创建资源。后续真机测试须另获授权。
4. 授权后，脱离 debugger 在 iOS 26+ 真机测：前台开始→handler 到达→切 App/锁屏；系统取消、强退、网络切换/断网、发送后丢 ACK、长模型无响应、审批等待/返回/超时、冷启动恢复；每项核对检查点、无重放和传输关闭。
5. UI 测试通过但日志有现有 SwiftUI “Modifying state during view update” 警告；全量首次编译也见 Swift 6 迁移相关的现有 TLS continuation / SafetyTests 参数传递警告，当前 Swift 5 模式构建通过。未据此宣称 UI/并发零警告。
6. iOS 27 LongRunningIntent 可后续调用同一协调器，本分支未改 Siri 工作树；自定义岛也未接入。
