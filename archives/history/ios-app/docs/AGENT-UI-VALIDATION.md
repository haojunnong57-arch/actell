# AgentUI 本地验证 · 2026-10-04

范围：`with-esp/ios-app`，基于 `e183d6d` 的会话 UI 与工具错误处理改动。以下记录描述提交前的验证工作区。固定 Bundle ID `com.ja1chen.PhoneAgent`。未改 `app-only`、固件或 SwiftAgentKit 核心快照；验证期间未提交、推送、刷机或安装真机。本轮接续此前已存在的会话 UI 改动。

## 后续调整：移除列表时间并压缩行高

按后续反馈，将上下 inset 从各 6 pt 增加到各 **10 pt**，每行比前一版增加 8 pt 留白。最终增量编译和现有新建会话 UI 用例 **1/1 通过**，0 failures；日志见 list-balanced-spacing.log（本地文件 `../.build/validation/list-balanced-spacing.log`，已忽略）。已实际查看增加留白后的列表（本地验证附件，已忽略），无日期、标题与单行预览布局正常。未新增测试、未重跑单元测试，`git diff --check` 通过。

基于已提交的 `40fc17c` 调整会话列表：移除日期，预览限制为一行，标题与预览间距由 7 pt 改为 3 pt；移除额外的上下 padding，明确列表行上下 inset 各 6 pt。行高由内容及系统字号自然撑开，不固定高度。

增量编译及已有“会话执行后重开历史”“新建真实会话”两条 UI 回归 **2/2 通过**，0 failures，日志见 dense-list-no-date.log（本地文件 `../.build/validation/dense-list-no-date.log`，已忽略）。已实际查看有消息的列表（本地验证附件，已忽略）和两条会话的列表（本地验证附件，已忽略），确认无日期、两行紧凑布局及正常截断。本次未新增测试，未重跑单元测试；使用已有模拟器与隔离数据，不调用真实模型或设备。`git diff --check` 通过，未提交本次样式改动。

## 后续调整：工具错误作为正常结果返回

原“工具执行失败，后续动作已停止”来自 `AgentEventProjection` 的固定失败文案；现改为对应工具的具体错误结果。`DeviceTool` 对普通运行错误返回匹配 callID 的 `AgentToolResult.error`，不再设置停止标记。模型在下一次请求中收到 `role=tool` 的 ERROR 结果，可继续解释或选择有效步骤。该工具错误及拒绝说明不再重复插入 notice；配置/模型服务错误等没有对应工具的通知保持独立。

保留显式停止、拒绝、前台和运行上限。输入传输出错后，本轮进一步 tap/drag 被禁用，防止重复发送可能已经执行的动作；Agent 仍可继续观察和回答。若模型收到错误后返回空白，不使用调用前的叙述作为最终回答，也不追加重复错误通知。“已结束”表示本轮对话结束，不代表设备任务完成。

- 第一轮完整编译、单元 **44/44**、UI **8/8** 通过，0 failures，日志见 tool-errors-as-results.log（本地文件 `../.build/validation/tool-errors-as-results.log`，已忽略）。包含新错误 UI 流程和现有批准、拒绝、停止、历史、新会话、Return、设置与调试回归。
- 随后补充空回复边界并调整结束日志；最终编译、单元 **45/45**、错误展示 UI 复验 **1/1** 通过，0 failures，日志见 tool-errors-as-results-final.log（本地文件 `../.build/validation/tool-errors-as-results-final.log`，已忽略），结果包见 tool-errors-as-results-final.xcresult（本地文件 `../.build/validation/tool-errors-as-results-final.xcresult`，已忽略）。已实际查看工具错误及后续 Agent 回复（本地验证附件，已忽略）：具体原因在展开的工具详情内出现一次，保留失败标签，后面为正常助手回复；截图回复由离线测试 provider 提供，不是云模型联调证明。
- 新增运行测试经真实 SwiftAgentKit 循环：离线 provider 只有收到正确 `toolCallId`、`role=tool` 和完整错误内容后才会回答；断言失败工具详情、后续助手消息、无 notice、正常结束。另验证空白后续回复不冒充完成。
- 新增工具边界用例：参数错误后可以执行修正后的调用；不确定输入返回错误，重新截图后仍禁止重复点击/拖动；显式停止仍终止执行。既有拒绝与后台取消测试保持通过。
- 使用已有 iPhone 18 Pro / iOS 27 模拟器和隔离内存数据；不调用真实模型，不读真实密钥，不连接设备。首轮重编译显示既有 `TLSBridge.swift` 和 `SafetyTests.swift` Swift 6 并发警告，以及 AppIntents 元数据跳过提示；未改相应并发实现。
- `git diff --check` 通过；改动限于 `ios-app`，未提交。既有历史消息保留原文，新工具调用使用新结果逻辑。

## 后续调整：简化会话列表

列表去掉模式图标、真实模型/离线演示文案和第三行状态，仅保留标题/日期与消息预览。标题后的“待确认”标签仅在 `.awaitingApproval` 且当前会话仍有有效审批请求时显示；`.blocked` 等普通错误状态不当作 HIL。保留离开会话即中断运行的既有行为，已清除审批的历史不会显示待确认标签。

增量编译及完成后重开历史、离开调试页中断、新建真实会话三条现有 UI 流程 **3/3 通过**，0 failures，日志见 compact-conversation-list.log（本地文件 `../.build/validation/compact-conversation-list.log`，已忽略）。断言验证模式文案、空闲/完成/中断状态和非 HIL 标签不出现在列表，并保留新建真实模式及历史状态验证。已实际查看有消息的列表（本地验证附件，已忽略）和新会话列表（本地验证附件，已忽略）。本次未构造列表中的活跃审批快照，未调用真实模型；`git diff --check` 通过。

## 后续调整：隐藏工具成功标签

成功工具不再显示“已返回”标签，保留图标、名称和详情展开；其余状态标签沿用原样式。增量编译及成功/拒绝两条现有 UI 流程 **2/2 通过**，0 failures，日志见 hide-tool-success-chip.log（本地文件 `../.build/validation/hide-tool-success-chip.log`，已忽略）。已实际核对成功结果（本地验证附件，已忽略）没有成功标签，拒绝结果（本地验证附件，已忽略）仍保留“已拒绝”标签。未重跑单元测试或调用真实模型；`git diff --check` 通过。

## 后续调整：工具图标尺寸与名称颜色

消息流和授权卡片的工具图标改用小号符号，仍随正文字号缩放；工具名称与图标统一使用次要文字颜色，保留正文字号及常规字重。增量编译及现有会话批准→结果→历史 UI 流程 **1/1 通过**，0 failures，日志见 subtle-tool-labels.log（本地文件 `../.build/validation/subtle-tool-labels.log`，已忽略）。已实际核对消息流（本地验证附件，已忽略）和授权卡片（本地验证附件，已忽略）截图。未重跑单元测试或调用真实模型；`git diff --check` 通过。

## 后续调整：输入框上方的授权卡片

待授权操作改为输入框上方的独立卡片，消息流中只保留简洁工具状态行；拒绝/批准按钮右对齐。卡片默认展示最多三行摘要，完整说明、参数和截图可在固定高度的详情区展开滚动。卡片只取当前有效审批对应的步骤与图像，沿用完整 ID 校验；批准、拒绝、停止后移除，历史会话不展示可操作授权卡。

增量编译、`AgentPresentationTests` **7/7** 及批准/拒绝/停止三条 UI 流程 **3/3** 均通过，0 failures。新增断言覆盖卡片与当前步骤/审批/图像对应、授权消费后清空、跨会话隔离，以及 UI 中审批按钮仅有一份、位于消息流之外、卡片在输入框上方且按钮右对齐。日志见 composer-approval-card.log（本地文件 `../.build/validation/composer-approval-card.log`，已忽略），结果包见 composer-approval-card.xcresult（本地文件 `../.build/validation/composer-approval-card.xcresult`，已忽略）。

已实际查看默认授权卡（本地验证附件，已忽略）、展开参数（本地验证附件，已忽略）、合成截图预览（本地验证附件，已忽略）及拒绝后的消息流（本地验证附件，已忽略）。验证使用现有 iOS 27 竖屏模拟器、内存演示数据，不调用真实模型或设备；未重跑全部单元测试。既有 `SafetyTests.swift` 并发警告仍在，`git diff --check` 通过。

## 后续调整：统一工具消息样式

所有工具状态共用前置工具图标、普通正文标题和末尾状态标签；移除成功勾选、标题加粗/蓝色强调、卡片底色与边框。参数、截图、结果展开及单次审批行为保留。

增量编译及现有批准→结果→历史、拒绝结束两条 UI 用例 **2/2 通过**（0 failures），日志见 plain-tool-rows.log（本地文件 `../.build/validation/plain-tool-rows.log`，已忽略），结果包见 plain-tool-rows.xcresult（本地文件 `../.build/validation/plain-tool-rows.xcresult`，已忽略）。实际查看了成功结果（本地验证附件，已忽略）、待批准（本地验证附件，已忽略）、拒绝状态（本地验证附件，已忽略）截图，确认名称使用普通正文颜色、各状态保留工具图标、没有卡片底色/边框。失败与拒绝/取消使用同一视图及标题组件，未调用真实模型制造失败场景。本次没有重跑全部单元测试；`git diff --check` 通过。

## 后续调整：直接新建真实会话与 Return 发送

首页及工具栏的新建入口直接创建真实模型会话，已删除模式选择面板及首页演示提示；已有演示历史保留。输入框 Return 与发送按钮共用校验，空白、超长、运行/停止处理中不发送；发送成功清空输入。多行编辑采用 `UITextViewDelegate` 处理 Return，保留自动换行和最多五行显示。

- 最终增量编译与两条新增 UI 测试 **2/2 通过**：两个新建入口均进入真实模型；空白 Return 不启动、非空 Return 发送且消息仅出现一次、输入清空。日志：live-new-keyboard-send-verified.log（本地文件 `../.build/validation/live-new-keyboard-send-verified.log`，已忽略），结果包：live-new-keyboard-send-verified.xcresult（本地文件 `../.build/validation/live-new-keyboard-send-verified.xcresult`，已忽略）。
- 原有五条 UI 流程均在同一版应用代码下通过，见 live-new-keyboard-send-fixed.log（本地文件 `../.build/validation/live-new-keyboard-send-fixed.log`，已忽略）；该轮结果包还包含键盘用例的一次定位失败：把导航标题和用户消息一起计数。随后限定消息区域重新验证通过，未移除消息数量断言。
- 首轮测试发现 SwiftUI 多行 `TextField` 的 Return 仍插入换行，因此改用原生编辑器处理提交。没有将仅编译通过视为键盘功能通过。
- 已导出并实际查看新建真实会话（本地验证附件，已忽略）和 Return 发送结果（本地验证附件，已忽略）。后者来自测试专用内存演示历史，不是正式新建入口。
- 未调用真实模型、读取真实配对凭据或连接实体设备；未重跑全部单元测试。构建仍有既有 `SafetyTests.swift` Swift 6 并发警告及 AppIntents 元数据跳过提示。`git diff --check` 通过。

## 后续调整：会话直接发送

按用户要求移除会话页“发送到模型服务”确认弹窗。点击发送直接提交本轮请求；设备输入的逐次审批仍保留。底层 `cloudConsent` 参数由显式发送操作传入，未授权的程序调用仍被阻挡。

本次增量编译及现有 `testConversationListChatApprovalAndResult` UI 用例通过（1/1，0 failures），覆盖离线发送、工具批准、结果与历史重开。日志见 chat-direct-send.log（本地文件 `../.build/validation/chat-direct-send.log`，已忽略），结果包见 chat-direct-send.xcresult（本地文件 `../.build/validation/chat-direct-send.xcresult`，已忽略）。未调用真实模型服务，未重跑全部单元测试。下方完整测试及截图为此前 AgentUI 验证记录。

## 此前完整验证结果

| 检查 | 结果与范围 |
| --- | --- |
| Xcode 编译 + XCTest | **通过**，Xcode 27.0 / iOS 27.0 SDK，Debug arm64 Simulator |
| 单元测试 | **40/40 通过**，0 failures；含真实 Agent 离线循环、流式片段、工具审批、运行隔离、存储恢复、协议和原状态 PiP 测试 |
| 模拟器 UI 流程 | **5/5 通过**，0 failures；使用用户原已启动的 iPhone 18 Pro / iOS 27.0 |
| Python wire-contract | **12/12 通过**，`python3 scripts/test_contract.py`；纯本地合成数据 |
| 展示源码来源 | 两份原始 Swift 文件 + LICENSE 的 SHA-256 与固定提交摘取清单逐项一致 |
| App 资源 | 完整 ManifoldKit / MarkdownUI MIT 许可已打包，内容与源码许可文件一致 |
| 配置范围 | 实际产物 Bundle ID 正确，无 UIBackgroundModes；未加入 Manifold SPM/Runtime 依赖 |
| Diff | `git diff --check` 通过；改动限于 `ios-app/`；固件、宿主机测试/工具及 Vendor/SwiftAgentKit 无 diff |

最终完整测试日志：agentui-verified.log（本地文件 `../.build/validation/agentui-verified.log`，已忽略）。结果包：agentui-verified.xcresult（本地文件 `../.build/validation/agentui-verified.xcresult`，已忽略）。40 项单元测试约 8.2 秒，5 条 UI 用例约 90.9 秒；日志终止为 `** TEST SUCCEEDED **`，进程退出码 0。构建日志保留 AppIntents 元数据提取跳过提示，本 App 未依赖 AppIntents；不将增量构建视为全项目零警告证明。

### 关键验证内容

- `AgentPresentationTests` 7 项：session/run/step/approvalID 任一不匹配都拒绝；单次批准只消费一次；拒绝与停止状态不同；停止解除等待并阻挡旧停止意图；历史/其他会话不借用当前截图或审批；投影实际流式事件与公开参数，不泄漏 reasoning/未允许字段；已拒绝步骤不被迟到成功事件复活；运行和清理期间的设置保存 guard。
- `ConversationRuntimeTests` 4 项：离线演示确实走 SwiftAgentKit，结果步骤为 screenshot → tap → screenshot → finish；快速切会话隔离；后台取消；真实模式在没有本轮明确同意前不读取密钥或启动。
- `ConversationTests` 7 项：恢复未完成记录为中断、不会自动执行；迟到事件与重复 begin 隔离；上下文只含当前会话已完成的公开文字；损坏文件不覆盖；旧任务迁入与草稿恢复；队列事件不覆盖审批状态。
- `ModelStreamTests` 4 项：真实 SSE 文本增量、工具参数分片组装；截断/缺失参数失败；多工具请求被拦截；实际请求启用 stream。
- 其余 18 项已有依赖路径、协议、安全与 PiP 状态测试仍通过。

UI 用例为：会话列表→会话→查看参数和合成截图→批准→结果→重新打开历史；设置→控制调试；拒绝结束本轮；审批中停止与历史不重启；离开控制调试页中断待批准运行。后一条重新验证了先前未重测的 onDisappear guard。UI 测试使用 `--ui-testing`，单元宿主使用 `PHONEAGENT_ISOLATED_TESTS=1`，均隔离为内存会话，不覆盖正常使用历史。

## 截图与实际审阅

11 张原始 PNG 来自最终成功结果包，均为离线脚本及合成画面。来源用例与 SHA-256 见 [manifest.json](agent-ui-screenshots/manifest.json)。已实际查看截图，核对导航、公开回复、审批、参数、截图展开、结果、拒绝/停止的文字与布局。

- [会话首页](agent-ui-screenshots/01-conversation-home.png) · [会话列表](agent-ui-screenshots/04-conversation-list.png)
- [审批与可见停止按钮](agent-ui-screenshots/02-chat-approval.png) · [真实调用参数](agent-ui-screenshots/02a-real-tool-parameters.png) · [合成截图](agent-ui-screenshots/02b-synthetic-screenshot.png)
- [最终结果](agent-ui-screenshots/03-chat-result.png) · [拒绝](agent-ui-screenshots/07-denied.png) · [停止](agent-ui-screenshots/08-stopped.png)
- [设置入口](agent-ui-screenshots/05-settings.png) · [控制调试](agent-ui-screenshots/06-control-debug.png) · [离开调试后中断](agent-ui-screenshots/09-debug-exit-interrupted.png)

首次 UI 回归暴露了停止图标前景/背景同色，以及迟到 tool-start 覆盖审批等待文案的问题，均已修复。测试也改为定位展开标题、滚动到可点击位置并等动画结束后取证；没有删掉失败断言。最后修正初始 inactive 阶段不应把空闲页面标为“已中断”。完整用例随后再次通过。截图中展开较长参数/图片时需滚动查看；手动浏览历史后自动跟随暂停，点击向下按钮回到最新消息，最终结果截图已走此流程。

## 复现命令

从 `ios-app` 运行；destination 对应本机现有已启动设备，不创建/启动其他模拟器。再次执行需使用新的 resultBundlePath，Xcode 不覆盖已有结果包。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project PhoneAgent.xcodeproj -scheme PhoneAgent \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
  -derivedDataPath .build/SimulatorRunBuild \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -scmProvider system -disablePackageRepositoryCache -skipPackageUpdates \
  -parallel-testing-enabled NO \
  -resultBundlePath .build/validation/agentui-rerun-1.xcresult \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

这里的签名仅为模拟器本地临时签名，不使用开发 Team、证书或真机 provisioning。未设置全局 `-sdk iphonesimulator`，宿主机宏仍由 Xcode 选择正确平台。未绕过宏信任、增加账户权限或安装新 CLI 工具。

## 未验证与剩余限制

- **没有调用真实模型服务。** SSE 和参数适配由合成流单测验证；真实 API/模型兼容性、网络异常与账单行为尚需单独联调。
- **没有连接实体 ESP32/iPhone。** 演示走真实 Agent 循环但用脚本 Provider 与 DemoBridge，不能证明硬件可控。固件 App 通道尚未完成，两份工程仍未完成端到端联调。
- **后台与同机跨 App 持续自动化未实现。** 离开前台中断，没有扩展 PiP、后台模式或后台审批。
- CitationsView 未接入：没有真实引用数据；没有整套迁移 Manifold Runtime，也没有宣称 ChatView/MessageBubbleView/InputBar 来自 Manifold。
- 运行 UI 验证仅覆盖本机 iOS 27 竖屏模拟器。最低 deployment target 为 iOS 17，但没有逐版本真机、深色模式或全部辅助功能验收。
