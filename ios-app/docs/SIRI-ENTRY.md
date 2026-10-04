# Siri → PhoneAgent 会话入口

## 基线与范围

- 独立 worktree：`/Users/developer/Developer/AI/ios-use/with-esp-siri`。
- 分支：`feature/siri-agent-entry`，基于当前已提交 main `b3724382d5161555f0130fa984f72f251e7a07d8`。
- 核查时 main 已提交会话列表微调；未跟踪 ESP 探测记录留在主仓。Live Activities worktree 基于 `40fc17c`，本功能不依赖它。
- 主 Bundle 保持 `com.ja1chen.PhoneAgent`，显示名统一为 `PhoneAgent`，供 `.applicationName` 替换和 Siri 识别。
- 在原 App target 内接入 App Intents / App Shortcuts。没有 SiriKit extension、新 App ID、App Group、SiriKit entitlement、录音/语音识别/后台音频权限或后台 agent loop。
- 实际最低部署版本为 iOS 17。构建 SDK 为 Xcode 27 / iOS 27。

## 使用方式

1. 打开本 worktree 的 `ios-app/PhoneAgent.xcodeproj`，选择 `PhoneAgent` scheme，在已授权的设备上构建安装。无需手动在“快捷指令”里创建捷径。
2. 对 Siri 说“用 PhoneAgent 创建任务”。必填 `String` 参数让系统追问“你想让 PhoneAgent 做什么？”。英文短语为“Create a task with PhoneAgent”。
3. 听写 1–2000 字任务。App 保存草稿并打开对应的新会话，显示识别文本与“尚未开始”提示。可编辑或取消。
4. 点击“确认开始”后，才会调用既有 `AgentViewModel.send(..., cloudConsent: true)` → SwiftAgentKit。任务发送给当前模型；设备动作仍逐次审批。键盘 Return 不会跳过 Siri 草稿确认。
5. “查询 PhoneAgent 任务状态”仅返回未运行、草稿待确认、运行中、待工具批准、正在停止等概括状态。
6. “停止 PhoneAgent 当前任务”只针对调用时捕获的唯一当前 session/run，调用原 runner/coordinator 停止流程。对已经发出的设备动作不承诺回滚。

Siri 的应用名称解析、口述体验和锁屏行为必须在真机验证。固定短语中不嵌入自由文本槽位；不承诺任意一句话尾缀都能可靠匹配。也可从系统“快捷指令”直接选择上述三个动作。

## 已实施的独立方案

```text
Prepare / Status / Stop AppIntent
  → PhoneAgentRuntime.shared.commands
  → SessionCommandService
      prepare → ConversationStore 原子保存会话 + 草稿 + SessionEntry
      open    → ContentView 前台导航 → ConversationView 待确认
      status  → SessionCommandRunning 的有限状态枚举
      cancel  → 捕获的 sessionID/runID → AgentViewModel.stop
  用户点击确认开始
  → AgentViewModel.send → SwiftAgentKit → ActionCoordinator → 逐次审批
```

`PhoneAgentRuntime` 为 App 与 Intents 提供同一个 model、store 和 command service。创建动作只触达存储和导航；不会连接模型、读取 API key、启动 bridge 或批准工具。

`SessionCommand` 含 commandID、sessionID、runID、source、createdAt、action。持久化的 `SessionEntry` 与会话共享 `conversations-v1.json` 的一次原子写入，并包含 createdAt、updatedAt、pendingConfirmation/submitted/dismissed、routePending 及确认后的 runID。老 v1 会话通过可选字段保持兼容。

### 持久与重复调用

- 先写盘再报告“已保存”；损坏、锁定或无法写入的存储会返回错误。原始损坏文件保留。
- 草稿存储使用 complete file protection，目录排除备份。任务文本留在应用私有会话归档，不作为 Siri 的返回值或实体索引内容。
- 同一 commandID 重投只返回原会话；不同调用即使文字完全相同，也创建不同草稿。不存在文本 hash 去重。
- App Intents 没有在这里提供可跨系统重新实例化的调用 ID，所以每次 `perform()` 生成新 UUID。若系统重新调用 `perform()`，可能多留一份待确认草稿，但任何一份都不会自动执行。
- `Task.checkCancellation()` 在持久化前执行；之后无异步间隙。取消早于保存则没有草稿；取消晚于保存可能留下草稿，仍必须手动确认。
- 最新待确认请求作为导航目标，较早草稿仍在会话列表中；确认或取消后清除其 routePending。冷启动从磁盘恢复路由，不依赖 NotificationCenter 或易丢失的通知。
- 已提交的运行在冷启动时沿用原 store 的 interrupted 恢复规则，不重放任务或工具。

### 忙碌与停止

- runner 运行、正在清理或 listener 忙碌时，open 返回 deferred。准备新草稿不会调用 selectConversation，因此不会触发原有的“离开会话即停止”规则。
- 清理完成且回到前台时可导航到待确认草稿，但不会自动开始。手动切换已有会话仍沿用原 App 行为。
- Siri 本身若导致 scene 离开 active，原有前台限定策略可能中断当前任务。这是保留的生命周期边界，不是新草稿抢占。
- cancel 先捕获 RunIdentity，再同步分发到 runner。旧 runID、旧 sessionID、无当前 run 或重复停止均不会停止后来的运行。停止命令不会写入待执行队列，也不会在冷启动后重放。
- UI 停止与拒绝继续走原逻辑；没有给听写或设备解锁额外的工具批准权。

### 认证与系统可见数据

三个 intent 均显式声明 `requiresLocalDeviceAuthentication`。本机认证允许访问这项入口，不代替用户对模型请求或工具动作的同意。状态和停止对话只使用固定公开文案，不包含任务全文、API 密钥、端点、截图、模型输出或完整结果。

创建动作在 iOS 17–25 使用 `openAppWhenRun = true`；iOS 26+ 用 `supportedModes = .foreground(.immediate)`。查询和停止为短时 `.background` 动作，它们不会启动后台 agent loop。iOS 27 显式限定 `.main` execution target。无需 `continueInForeground` 或 `LongRunningIntent`。

## 集成位置

| 文件 | 责任 |
| --- | --- |
| `PhoneAgent/Intents/AgentIntents.swift` | 三个薄 Intent 和 AppShortcutsProvider |
| `PhoneAgent/Intents/AppShortcuts.xcstrings` | zh-Hans/en 固定短语，保留 applicationName 占位符 |
| `PhoneAgent/Intents/Localizable.xcstrings` | 参数追问、动作名称、公开返回和错误文案 |
| `PhoneAgent/SessionCommands/SessionCommand.swift` | command、持久 entry、mockable runner 协议和服务 |
| `PhoneAgent/SessionCommands/PhoneAgentRuntime.swift` | App 与 Intent 共享唯一 runner；DEBUG 离线 UI fixture |
| `PhoneAgent/Storage/ConversationStore.swift` | 原子保存草稿、拒绝恢复执行、确认关联 runID |
| `PhoneAgent/App/ContentView.swift` | 前台路由和忙碌延期 |
| `PhoneAgent/App/ConversationView.swift` | 识别文本、编辑、取消、明确确认开始 |
| `PhoneAgentTests/SessionCommandTests.swift` | 持久、隔离、mock runner 和真实离线 loop 测试 |
| `PhoneAgentUITests/SiriEntryUITests.swift` | 冷/热路由、忙碌延期、确认、拒绝和 UI 停止 |

基线工程引用但未跟踪 `PhoneAgent/Security/SecretStore.swift`（误匹配 `secrets*` 忽略规则）。本分支补齐等价的小型 Keychain 适配器并显式取消该源码的忽略；保留原服务命名空间，不读取或迁移实际密钥。生成器支持 `.xcstrings`；检查入库的工程保留原签名配置，只增加新文件与显示名。

## 可重复验证

所有构建和依赖检出位于本 worktree 的 `ios-app/.build/`。本机默认 xcode-select 指向 CommandLineTools，XcodeBuildMCP 因此无法发现 simctl；使用下列进程级环境，不修改全局开发目录。

```sh
cd /Users/developer/Developer/AI/ios-use/with-esp-siri/ios-app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'platform=iOS Simulator,id=4105EC0E-1638-46A6-9E87-FB57B4A3E739' \
  -derivedDataPath .build/SiriEntry -clonedSourcePackagesDirPath .build/SiriPackages \
  -parallel-testing-enabled NO \
  -only-testing:PhoneAgentTests -only-testing:PhoneAgentUITests/SiriEntryUITests \
  CODE_SIGNING_ALLOWED=NO test
```

上述 UI 测试仅使用 DEBUG fixture 和 DemoProvider/DemoBridge，不访问真实模型或 ESP。`--ui-testing --ui-test-siri-seed` 可展示持久草稿确认页；`--ui-test-siri-restore` 用同一临时测试目录恢复；`--ui-test-siri-warm` 在前台直接调用真实 Intent.perform；`--ui-test-siri-busy` 在离线工具审批期间调用它。生产 Release 不包含这些入口。

测试结果、截图和尚未验证项见 [SIRI-VALIDATION.md](SIRI-VALIDATION.md)。

## Apple 依据

- [Configuring runtime behavior](https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents)：运行模式与前台切换；availability 同时核对本机 Xcode 27 SDK 的 AppIntents.swiftinterface。
- [Spotlight your app with App Shortcuts · WWDC23 10102](https://developer.apple.com/videos/play/wwdc2023/10102/)：applicationName、必填参数追问、固定触发短语、自由文本参数限制。
- [Intent authentication policy](https://developer.apple.com/documentation/appintents/appintent/authenticationpolicy)：显式身份认证策略。
- [Main execution target](https://developer.apple.com/documentation/appintents/intentexecutiontargets/main)：本 App 的执行目标。
