# Agent 执行层与会话 UI

本次基于 `e183d6d`，保留 SwiftAgentKit、Provider、五个工具、逐动作批准、Keychain 和既有运行限制。Bundle ID 固定 `com.ja1chen.PhoneAgent`。此文描述本地工作区实现；实际验证结果见 [AGENT-UI-VALIDATION.md](AGENT-UI-VALIDATION.md)。

## 用户路径

- 首页为会话列表：两个新建入口均直接创建真实模型会话，不再显示方式选择面板；支持搜索、打开历史和删除空闲会话。已有演示记录保留原模式。
- 列表每项只显示标题和单行消息预览，不显示时间、模式文案、模式图标或第三行状态。行内两行间距 3 pt、上下边距各 10 pt，行高随系统字号自然变化。仅当前会话处于待审批且存在有效审批请求时，在标题后显示“待确认”标签；普通错误、完成、停止、中断和空闲状态不显示标签。离开会话仍按原逻辑中断运行，不为列表标签保留过期审批。
- 会话页显示用户消息、模型公开回复、工具请求/参数、待批准、执行、截图/结果及失败/拒绝/取消。真实模式点击发送即提交本次消息、近期文字上下文及本轮工具获取的截图，不再弹出模型发送确认；设备输入仍需逐次确认。
- 工具调用使用无外框、无卡片底色的消息行；所有状态统一前置小号工具图标，名称保留普通正文字号/字重，与图标同为比正文更浅的次要文字颜色。成功不显示“已返回”状态标签；失败、拒绝、取消及执行/待确认等状态保持现有标签。授权卡片沿用相同图标和名称样式。无成功勾选图标；参数、截图、结果仍可展开。
- 工具失败保留“失败”标签，展开后“结果说明”显示具体错误，不再替换成固定停止文案或另插 notice。错误以匹配 callID 的 `AgentToolResult.error` 返回下一轮模型；模型可解释限制或选择其他有效步骤。模型继续产生的公开回复正常显示。
- 待授权操作单独显示在输入框上方的卡片中；消息流只保留工具名称与等待状态。卡片默认显示操作摘要，完整说明、参数和截图可在有界的详情区展开、滚动；拒绝/批准按钮右对齐。只有当前会话、当前运行、当前步骤的有效审批会生成卡片，审批 ID 变化时重置展开状态；批准、拒绝、停止或离开会话后移除。
- 输入框 Return 与发送按钮共用校验和发送入口；空白、超过 2,000 字符及运行/停止处理中不发送。保留自动换行和最多五行的输入布局。
- 设置 → 控制调试，保留原设备连接、截图、任务记录、状态 PiP 原型。离开运行中的会话或调试页会中断该轮。
- 历史演示和控制调试仍可运行确定性脚本与合成计数器屏幕，经真实 SwiftAgentKit 循环执行；不会调用 HTTP 模型或真实桥接。没有用打字动画假装模型流。UI 回归测试在隔离内存中预置演示历史，不通过正式新建入口创建演示。

## 展示与执行边界

```text
SwiftAgentKit Agent + PrivateVisionProvider / DemoProvider
  → 单个 FIFO AgentEvent 消费者
  → AgentEventProjection（公开文本与允许列表内的工具字段）
  → ConversationStore（只接受当前 sessionID + runID）
  → AgentPresentationAdapter（sessionID + runID + stepID/callID）
  → ConversationView + 改编的 ToolInvocationView

会话 UI → send / approve / deny / stop 意图 → 完整 ID 校验
  → 既有 AgentViewModel / ActionCoordinator → 逐次审批和桥接
```

`RunIdentity.conversationID` 即 sessionID；runID 每次显式发送重新生成，stepID 为该次运行中的实际工具 callID。旧运行事件无法写入当前会话；相同 callID 在不同运行中不会共用卡片。截图来源附带完整步骤 ID，审批预览还必须匹配 request.imageID。离开会话后不保留图像预览，历史只保留文字回执。

真实模型使用 SSE 公开文本增量，不显示/保存 reasoning。工具参数片段要完整组装、验证 JSON 和单调用限制后才放给执行层；流截断或兼容性错误明确失败，不回退重新请求以冒险重放动作。实时步骤来自 SwiftAgentKit 事件和 ActionCoordinator 回调，不使用 Manifold 的 progress consumer。

批准只消费一次等待；第二次点击、其他会话、旧 runID、错 stepID 或旧 approvalID 都不能动作。拒绝标记 `denied`、结束该轮并释放等待，停止标记 `cancelled`/`stopped`；两者采用同一资源清理机制但保留不同语义。停止后旧回调失效，等待旧任务和桥接清理结束前不开放下一次发送。没有接入 Manifold 的默认 AutoApprove、askOncePerSession 或工具自动重试策略。

输入成功回执只表示送达，必须取得新截图才能继续或调用 finish。历史恢复把未完成回复标为中断、未完成工具标为取消，不自动重新执行。未提供编辑/重新生成按钮，避免悄悄重放设备副作用。

工具运行错误不再设置 `shouldStop` 或停止整个协调器；错误会使旧截图失效，下一步如需设备输入必须重新获取截图。输入传输已经被调用后发生异常，结果可能不明，因此禁用本轮后续 tap/drag（新截图也不会解除）；Agent 仍可继续观察、解释。逐动作审批、显式拒绝/停止、离开前台中断、运行次数/时间及框架循环限制保持有效，没有启用自动 repair/retry。拒绝说明也只保存在对应工具结果；模型服务或配置错误没有对应工具，仍可显示独立通知。

会话“已结束”只表示 Agent 正常返回文字或 finish；工具失败后模型解释限制，也可正常结束对话，不代表设备任务完成。设备完成仍需 finish 的新截图验证。模型在失败后返回空回复时保留阻塞状态，不用调用工具前的叙述冒充最终答案，也不重复插入工具错误通知。

## 真正复用的开源部分

| 来源 | 实际使用 | 未接入部分/原因 |
| --- | --- | --- |
| [ManifoldKit 固定提交](https://github.com/ManifoldKit/ManifoldKit/tree/15c9c2443770c9289c2e93c88a55bdebc4562771) · MIT · Rory Ford | 摘取并适配 ToolInvocationView 的生命周期外壳，以及 ToolInvocationStyle 中 PlainToolInvocationBody 的工具卡渲染；原文件、哈希和许可完整保存 | 不引入 Runtime/ChatViewModel/ChatView；CitationsView 没有真实引用数据可接，未导入 |
| [MarkdownUI 2.4.1](https://github.com/gonzalezreal/swift-markdown-ui/tree/2.4.1) · MIT · Guillermo Gonzalez | SPM MarkdownUI，渲染模型公开回复；禁用外部 inline/block 图片自动下载 | 仓库已说明维护模式。没有迁移其推荐的另一个新库或提高最低 iOS 版本 |
| SwiftAgentKit 本地兼容快照 | 保留真实执行循环、工具系统、运行限制与已固定依赖 | 无第二套 Agent runtime；本次没有改 Vendor/SwiftAgentKit |

[完整 Manifold 来源和改动清单](../../../../ios-app/Vendor/ManifoldPresentation/README.md)；许可见 [ManifoldKit-MIT.txt](../../../../ios-app/Licenses/ManifoldKit-MIT.txt) 和 [MarkdownUI-MIT.txt](../../../../ios-app/Licenses/MarkdownUI-MIT.txt)。会话列表、输入框、消息壳、导航、事件投影、意图路由、截图关联和持久化均为应用自有代码，不能称为整套 Manifold ChatUI 的复用。

之前也评估了 [Exyte Chat](https://github.com/exyte/Chat)（媒体依赖较多）与 [assistant-ui](https://github.com/assistant-ui/assistant-ui)（React 技术栈）；未加入它们的源码或依赖。本次选择针对真实 Agent 工具状态的独立展示组件，并保留 SwiftUI 会话布局。

## 数据与运行范围

会话文件 `Application Support/PhoneAgent/conversations-v1.json` 使用原子写入、完整文件保护、排除备份；每会话最多 200 条记录，单条公开回复最多 16,000 字符，草稿最多 2,000 字符，文件上限 64 MiB。不保存截图、真实凭据、原始 HTTP 响应或内部推理。旧任务首次迁入；遇到损坏或不兼容文件保留原文件，仅在内存中继续。上下文只使用当前会话最近 16 条已完成的用户/助手公开文字，不恢复历史工具队列。

模型/API 网络兼容性、真实 ESP32 通道、物理 iPhone 操作及两端联调仍未验证。未扩展 PiP/后台能力，App 离开前台即停；同机跨 App 持续自动化仍未实现。

## 主要文件

```text
ios-app/
├── PhoneAgent/AgentUI/
│   ├── AgentPresentationAdapter.swift       # 应用事件投影与意图边界
│   └── Components/ToolInvocationView.swift  # Manifold 工具卡源码适配
├── PhoneAgent/Agent/ModelStreamDecoder.swift
├── PhoneAgent/App/
│   ├── ContentView.swift                   # 会话列表
│   ├── ConversationView.swift              # 会话页
│   └── ControlDebugView.swift              # 旧控制界面移到设置下
├── PhoneAgent/Models/ConversationModels.swift
├── PhoneAgent/Storage/ConversationStore.swift
├── PhoneAgentTests/                        # 含事件/审批/恢复/流式用例
├── PhoneAgentUITests/ConversationUITests.swift
├── Vendor/ManifoldPresentation/            # 原文、来源哈希和 MIT 许可
├── Licenses/                               # 同时打包到 App 资源
└── docs/agent-ui-screenshots/               # 离线模拟器截图及哈希
```
