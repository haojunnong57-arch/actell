# PhoneAgent Live Activities / 灵动岛

本分支基于 `40fc17cda997af6bb5374be05f02a845ec12edca`，在 `feature/live-activities` 独立 worktree 开发。保留 SwiftAgentKit、AgentUI、逐次审批、前台执行限制和原 PiP。没有合并或推送。

## 实现范围

- 主 App ID：`com.ja1chen.PhoneAgent`。
- Widget extension ID：`com.ja1chen.PhoneAgent.LiveActivity`，固定不随构建变化。
- iOS deployment target 17.0。`Activity.request/update/end` 完全本地，`pushType: nil`；没有 APNs、App Groups、后台模式、LongRunningIntent 或 BGContinuedProcessingTask。
- 锁屏布局、紧凑/最小/展开灵动岛只显示应用定义的状态、演示标识、已返回工具数量及“查看并确认／查看记录”入口。没有百分比、假进度或定时保活。
- 系统 payload 只含会话/轮次 UUID、可选审批 UUID、枚举、计数和更新时间。不含目标、对话、工具参数、截图或图像 ID、模型响应、主机地址及凭据。

## 状态与生命周期

| 实际事件 | 系统状态 |
| --- | --- |
| 新运行 / 模型请求 | 正在请求模型 |
| 工具开始 | 正在处理工具 |
| 审批记录成功落盘且 continuation 已建立 | 等待确认 |
| 原子接收批准 | 已收到批准（尚未发送） |
| 执行器通过有效期和单次领取检查 | 正在发送动作（不等于设备成功） |
| 工具返回（包含失败结果） | 已返回步数增加，不代表任务完成 |
| 运行正常结束 | 本轮已结束，请核对结果 |
| 用户停止 / 拒绝 | 已停止 / 需要查看 |
| 离开前台 / 审批过期 / 进程恢复 | 已中断，回到 App 查看 |

`AgentLiveActivityController` 用 FIFO 串行处理所有 ActivityKit 写入。过时排队更新不能在取消后重新创建活动；新进程会结束旧活动，不接管旧 continuation。常规运行状态 30 秒后可标记 stale，等待审批以截图的实际截止时间为 staleDate；Widget 显示“请回到 App”，不会继续冒充新鲜执行状态。没有用定时器刷新活动以获得后台时间。

前台离开仍立即停止执行与连接。离开前台时只提交一次真实“已中断”状态，使灵动岛仍有返回入口；返回 App 或下次启动再 `end`，用户/系统也可随时移除。这不是后台执行或保活，没有定时刷新。前台的正常结束、拒绝和停止直接 `end`，可在锁屏/通知中心保留约 5 分钟，具体呈现和存活上限由系统控制。正常结束后灵动岛可消失。突然被杀时无法保证立即更新系统卡片，stale 和下次启动清理是后备措施，不承诺继续执行。

## 深链与审批边界

地址格式：`phoneagent://activity/session/<UUID>/run/<UUID>?approval=<UUID>`。链接只导航，不授权、拒绝、发送或重启任务。严格拒绝未知 query、重复 approval、无效 UUID、额外路径、fragment、用户名/密码和端口。

- 校验持久会话中真实存在的 run，审批 UUID 必须映射到相同 session/run/callID 的记录。
- 跳到对应工具消息；没有审批参数时跳到该轮消息。
- 其他运行尚在进行时不切换会话、不取消新运行、不借用新运行的审批。
- 相同 run 的旧动作链接也不能定位另一个当前动作。
- 已处理、过期、取消或恢复后的审批只显示历史与失效说明；删除/不存在的会话显示错误。

`ApprovalRecordStore` 是 **App 沙盒内**的权威记录。记录包含 session/run/callID/approvalID、由原始工具参数与工具名生成的 SHA-256 摘要、版本、截止时间和状态；不存截图或公开目的原文。截止时间取截图有效期与运行时限的较早值。

所有 compare-and-transition 在 MainActor 同步完成，以原子且完整文件保护的写入先持久化，再释放批准。顺序为 `pending → accepted → executing → finished`；拒绝、取消、过期、中断不可再消费。执行前再次检查原截图、运行 token 和任务取消；不改变原有未知设备结果禁止重发规则。存储损坏、不可写或写入失败均不释放批准，原损坏文件保留。重启将所有 unfinished 记录作废。

本轮**没有 LiveActivityIntent 直接批准/拒绝按钮**，也没有共享容器授权。用户通过系统链接返回 App，查看参数/截图后使用现有单次审批卡。后续若增加 LiveActivityIntent，必须先明确其执行进程与前台恢复策略，复用相同持久校验、单次消费和过期边界；若确需扩展进程共享存储，再单独确认 App Group，不自动注册能力或选择 Team。

## 工程入口

- `Shared/AgentActivityAttributes.swift`：系统状态白名单与 URL 解析。
- `PhoneAgentLiveActivity/PhoneAgentLiveActivity.swift`：系统界面与查看链接。
- `PhoneAgent/LiveActivity/AgentLiveActivityController.swift`：ActivityKit 生命周期。
- `PhoneAgent/LiveActivity/ApprovalRecordStore.swift`：App 内持久审批权威。
- `AgentViewModel`：真实事件接线、过期取消与深链校验；`ConversationView` 定位对应消息。
- `project.yml` 与 `scripts/generate_xcode_project.py`：扩展 target、共享源码、嵌入阶段和 Info.plist。生成器会重写 pbxproj 格式，语义修改为新 target/源码/嵌入/URL 配置，签名 Team 留空。

基线遗漏修复：`PhoneAgent/Security/SecretStore.swift` 在主 checkout 已存在，但被 `ios-app/.gitignore` 的 `secrets*` 规则误忽略，未进入基线提交。新 worktree 原样补入此 Keychain 封装源码，并加精确忽略例外。它不含密钥；SHA-256 与原文件一致：`0702d14580a628524801731819608c3f5e325dcce9c7165396fd0ef13ffcfdd2`。没有读取或复制 Keychain 值。

## 截图证据

实际模拟器原始截图，已逐项目视检查。数据均为离线演示；通知中心截图不代表真机已经锁定或认证通过。

- [App 内待确认](live-activity-screenshots/live-activity-01-pending-in-app.png)
- [紧凑灵动岛：中断](live-activity-screenshots/live-activity-01b-interrupted-compact.png)
- [长按展开灵动岛](live-activity-screenshots/live-activity-01c-interrupted-expanded.png)
- [通知中心低敏卡片](live-activity-screenshots/live-activity-02-interrupted-notification-center.png)
- [深链回到原轮次](live-activity-screenshots/live-activity-03-linked-history.png)

[来源与 SHA-256 清单](live-activity-screenshots/manifest.json)对应原始 xcresult。首次系统“允许实时活动”前，紧凑岛可能还不显示；测试只处理模拟器内本 App 的显示许可，不涉及签名、凭据或开发者能力授权。

## 验证（2026-10-04）

使用原已启动的 iPhone 18 Pro / iOS 27 模拟器，Xcode 27.0。所有输出、依赖副本、DerivedData 和测试证据均在本 worktree 的 `ios-app/.build/`。使用 `CODE_SIGNING_ALLOWED=NO`，实际 App 没有 `_CodeSignature`；产物验证两个固定 Bundle ID、`NSSupportsLiveActivities = true`、Widget 扩展点、URL scheme 和 iOS 17 最低版本均正确，无 `UIBackgroundModes`。

- 首轮无签名单元：57/57 通过；随后补充同轮不同动作链接和运行时自动过期用例。
- 完整无签名回归 **59/59 单元 + 9/9 UI** 通过（0 failures）；结果见 [测试日志](../.build/validation/full-unsigned.log) 与 [xcresult](../.build/validation/full-unsigned.xcresult)。
- 最终生命周期调整后，相关 **20/20 单元 + 1/1 系统 UI** 再次通过，见 [island-final.log](../.build/validation/island-final.log)。增加紧凑岛文字和长按展开断言后，系统 UI **1/1** 通过，见 [island-expanded.log](../.build/validation/island-expanded.log)。首次显示许可兼容逻辑补齐后，最终系统 UI **1/1** 再次通过，见 [island-permission-ready.log](../.build/validation/island-permission-ready.log)。本机实际复验走已允许分支，首次许可分支的每个系统操作在此前运行中分别验证过，未重置用户模拟器权限来重跑整段首次安装流程。没有把先前完整回归冒充为最终代码下再跑全部测试。
- Python wire contract：12/12 通过，`python3 scripts/test_contract.py`。
- 审批单测覆盖重复、过期、参数/版本/截止时间变化、跨 session/run、拒绝/取消、进程恢复、损坏文件及持久化失败。
- 真实 SwiftAgentKit 离线运行覆盖状态映射、批准接收与执行的先后、实际返回步数、后台取消、截图过期自动中断；原未知输入结果不重发、会话及 PiP 测试保留。
- 系统 UI 测试从真实离线运行创建 Live Activity，切回桌面并打开通知中心，确认状态变成中断、无直接批准按钮，点击查看记录回到原轮次且不能重启或再次审批。
- 测试数据为内存会话 + DemoProvider/DemoBridge，不读真实 API/桥接密钥，不调用云模型或操作 ESP32/真实 iPhone。

复现（从 `ios-app` 运行，重新测试时更换 resultBundlePath）：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project PhoneAgent.xcodeproj -scheme PhoneAgent \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=CBC53192-188D-4FC1-818C-36EC433418FF' \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -scmProvider system -disablePackageRepositoryCache -skipPackageUpdates \
  -parallel-testing-enabled NO \
  -resultBundlePath .build/validation/live-activities-rerun.xcresult \
  CODE_SIGNING_ALLOWED=NO test
```

编译日志保留原有 `TLSBridge.swift` / `SafetyTests.swift` Swift 6 并发警告与 AppIntents 元数据跳过提示；UI 回归日志出现 `Modifying state during view update` 警告，测试断言均通过，但不宣称零运行警告。

系统默认 xcode-select 指向 Command Line Tools，XcodeBuildMCP 的模拟器发现/构建因此不可用。本轮仅为命令指定 DEVELOPER_DIR，未修改系统 Xcode 选择。Xcode 的测试后诊断收集仍报告找不到 simctl；XCTest 本体退出码 0、结果包及截图均已成功导出。`check_source.py` 的 Python 环境缺 PyYAML，未把该语法脚本当作编译证据；以实际 Xcode 编译和 XCTest 为准。

### 仍需用户验证的范围

真机签名、固定 Widget App ID 的可用性、锁定状态认证、真实锁屏/常亮显示、系统强杀时机、跨 iOS 17–26 版本、多个实时活动时的最小岛及不同屏幕/辅助功能尚未验收。通知中心模拟器截图不代表锁定真机验证。没有自动注册 App ID、选择 Team、创建凭据、安装真机或授予 App Group；若后续需要这些操作，应单独明确授权。

参考 Apple 官方 [ActivityKit 展示 Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)、[Widget / Live Activity 交互](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities) 与 [LiveActivityIntent](https://developer.apple.com/documentation/appintents/liveactivityintent)。本轮只使用现有前台执行能力，系统展示不授予后台执行能力。

开发期间主分支由其他工作推进到 `b372438` 并继续修改 ESP32 相关文件，本分支仍保持原基线；没有同步、切换、stash/reset 或改写主 checkout。初次交付为 worktree 内改动；测试通过后，按用户授权提交到 `feature/live-activities`，不合并或推送。
