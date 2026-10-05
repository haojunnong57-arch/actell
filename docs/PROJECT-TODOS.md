# 项目待办重评与实施

范围来源：[用户待办 Page](https://chatgpt.com/space/page_36704b3c39e88191b5bc6190c62af3b6)，只读核对 sequence 612；本次明确实施取代页内旧“暂缓”。独立分支 `feature/project-todos`，基线 `80b1c8f`。未修改 `with-esp` 主线未提交签名、`app-only`、CoreDevice worktree、Page 或真实数据。

| 待办 | 基线重评 | 本分支结果/依据 |
| --- | --- | --- |
| 并发 STOP 回执 | PA3 已修 | `USBCommandClient.stopInputs` 共享任务；固件按输入代号拒绝后续 STOP。补 ID2/ID3 连续 STOP 回归，保留连接；未改固件 |
| 双 checkpoint | 仍需 | `RunCheckpointStore` 读取通用、旧 USB 及恢复归档，按会话/运行/代号去重并合并事务。任一未确认发送均保留 unknown；新运行不会覆盖恢复归档。提示在会话中幂等，恢复不授予租约、不保留可用审批、不重放 |
| PING/健康轮询 | 周期 PING 已收敛；健康轮询仍重复 | PING 保留 client 单一调度；model/lease/bridge 共用 context 一个健康定时器。实际入队仍同步验证。修复读 PING 前采样时间导致“负数心跳年龄”的竞态；750ms 失效不变 |
| 重复结束/取消/释放 | 下层已部分修 | `ActionCoordinator.stop` 共享收尾任务；model 不再重复取消、finish 或重复停止同一 bridge；断线释放兜底保留 |
| 文档/测试瘦身 | 仍需 | 精简两级 README；68 个历史文件移入 `archives/history`，相对 Markdown 链接重定位。非核心 PiP 展示/Siri UI 测试可恢复归档，旧调试 UI 测试作为历史保存。核心审批、隔离、协议、迁移、释放测试保留。`AGENTS.md` 提供默认阅读/验证入口 |
| 移除离线演示入口 | 仍需 | 移除整个控制调试页；不新增演示入口。历史演示会话、底层合成回归夹具仍兼容 |
| 移除旧 Host 卡片 | 仍需 | 设备面板只含 SCK/USB NCM；旧 Host 固件和配置数据保留 |
| 移除调试任务/截图/动作记录 UI | 仍需 | 删除调试展示与入口，未删除已有会话和记录；保留用户主动查看的故障诊断 |
| Conversion error | 需证据 | 未找到应用内相同字符串或 UIKit 坐标转换调用；不凭字符串推测修复。仍需原设备的触发步骤、iOS 版本与错误时调用栈。模拟器结果见下方 |
| 查看屏幕后“提交执行结果” | finish 已非强制，schema 仍暴露 | 设备工具只注册 screenshot/tap/drag/wait，以最终文字答复结束；历史 finish 展示名改“结束本轮”。截图的 tool result 仍正常返回模型，不是多余工具调用；后续技能工具为按需只读能力 |
| 多余运行限制 | 部分已移除；次数/token/框架 loop 仍在 | 去除 12 轮、16 次输入、20,000 累计 token、1024 输出 token、默认 60s lifecycle inactivity、URLSession 45/60s 强制超时及框架重复循环终止。使用系统网络超时；保留响应体/协议大小、实际后台资格、锁屏、采集终止、手动停止、防重放和未知结果输入阻断 |
| 导航栏设备按钮 | 仍需 | 会话首页及会话内按钮打开设备控制面板，管理采集/USB 连接、取消与断开；关闭面板不触发任务收尾 |
| 多服务商/会话选模型 | 仍需 | 独立页面增改、确认移除及恢复；会话保存 provider UUID/model ID。旧配置保留原 Keychain 引用，地址变更不携带旧地址密钥，同地址不同新服务商可独立持有密钥。移除后已绑定会话不会静默改用其他服务商。运行中不变更配置 |
| 设置移除 USB | 仍需 | 设备与服务商各自独立；设置保留记录／附件清理、技能管理和后台说明 |

原 STOP 审计证据更正：连续命令 **ID2 STOP 与 ID3 STOP**，五轮复现均只有 ID3 的 executed；不是“五个 STOP 收到三次”。本次 PA3 测试期望 ID2 executed、旧代号 ID3 cancelled，两边均有明确终态。

实施阶段为：恢复/执行生命周期 → 设备入口与服务商 → 归档及回归。真实输入权限沿用 `80b1c8f`，未扩大任务授权。

## 回归与构建

- PA3 生产 C 的 ASan/UBSan 协议/HID 夹具通过；25 个本机 TCP 测试通过（含 ID2/ID3 STOP、重复 ID、取消、断线、代号撤销、STOP 丢失回执）。无实际 USB/HID。
- 12 个 Python wire-contract 回归通过。
- 新增 XCTest：双文件未知事务保全/去重/新运行后保留/无授权复用；迁移 Keychain 引用、独立服务商、地址变更、删除恢复与会话绑定；并发 cleanup 一次释放；单一定时器；心跳取时竞态；18 次输入及 14 次重复观察/超过20,000报告 token 后正常完成；真实 schema 不提供 finish。
- 首轮 172 tests 中存在 11 个失败断言，不能引用旧“166 tests”作最新覆盖。部分是基线已取消的前台/画面匹配限制，部分是测试夹具仍要求 finish。已保留并改写未授权拒绝、撤销/单次消费测试；恢复测试原来保留 pendingApproval 的断言改为不可恢复授权。
- 原 Page 阶段 XCTest：**174 个核心 + 4 个 UI 全部通过，0 失败**，证据 `.build/validation/core.yGz9qf/Tests.xcresult` 与同目录 `test.log`。UI 覆盖设备面板/设置入口、多服务商/会话模型选择、确认取消/移除/恢复、历史停止不重放。已核对 `.build/ui-final/` 的 6 张截图。iOS 27 的 confirmationDialog 未显示显式取消按钮，已改成带取消按钮的 alert。
- 该阶段 iPhoneOS 27 无签名 build 通过（`.build/device-build-verified.log`）。生成工程的全部 build settings 与基线一致，包含原 Live Activities 声明，签名配置未改变。存在原有方向支持警告；没有新增编译错误。
- 此次模拟器 UI 及 App 运行日志未出现所报 Conversion error（`.build/conversion-check.log`），不能据此认定真机问题已修。主机默认 xcrun 路径使 Xcode 的附加诊断收集失败；通过明确的 DEVELOPER_DIR 导出截图和日志，测试本身成功。未改变系统 Xcode 选择。
- 可选归档 PiP 展示/Siri UI、旧 Host 全量、真实服务商与真机测试未跑；本次未改相应固件或 Siri 功能。默认工程与临时恢复归档工程均已检查文件引用，最终提交默认工程。
- 原始构建日志、xcresult、截图只在本分支 `.build/`，不提交用户设备或会话原始数据。默认测试命令见 [App README](../ios-app/README.md)。

## 边界与待证据

未推送、未合并主线、未烧录、未运行真实设备输入、未更改签名/系统设置，未请求真实模型服务。固件源码无变化，继续兼容 PA3，无需本次固件升级。

待真机验收：系统采集授权、AssistiveTouch HID 的拖动/停止/断线释放、跨 App 持续闭环、多服务商实际视觉/工具兼容性，以及 Conversion error 原始调用栈。用户此前报告 PING、截图与点击可用不等于上述全量验收。

此前自动审批审查拒绝了取消“每次模型响应仅一个工具”的附加改动，认为缺少扩大单次响应输入范围的明确授权。该阶段保留边界；用户随后明确确认 B1 多工具，见下方实施记录。审查也曾拒绝直接反转旧权限测试；随后改为保留未授权拒绝并用实际 `80b1c8f` 证据区分观察与显式授权，未修改生产输入授权规则。

## 后续独立任务：模型发现与参数（基于 95557f3）

| 协议 | 模型发现 | 本次推理支持 |
| --- | --- | --- |
| OpenAI-compatible | `GET <base>/models`；列表字段缺失时能力未知，兼容显式游标分页 | Chat Completions |
| Anthropic | `GET <base>/v1/models`，`after_id`，`x-api-key`/`anthropic-version`；读取 capabilities/token 上限 | **仅发现**，任务发送前明确阻止；不伪装 OpenAI |
| Gemini | `GET <base>/v1beta/models`，`pageToken`，`x-goog-api-key`；读取生成方法/token/温度上限 | **仅发现**，任务发送前明确阻止 |
| Ollama | `GET <root>/api/tags` + 每模型 `POST <root>/api/show`（只读元数据）；单个详情失败保留未知 | 显式使用 `<root>/v1/chat/completions`，图片/工具须模型支持 |
| OpenRouter | `GET <base>/models`，offset/limit 分页；读取参数列表、模态、token 上限、原始报价 | Chat Completions |

UI 提供协议/基础地址/密钥、获取/取消/刷新、缓存搜索选择、手动 Model ID 和每服务商/模型参数。模型字段三态；未知可手动填写已知协议字段，明确不支持的字段不发送。支持 temperature、top_p、输出 token 上限、seed；OpenAI 可显式选择 max_tokens 或 max_completion_tokens，不能同时填。只发送用户配置项，不根据模型名猜测。原生 Anthropic/Gemini 参数编辑暂不提供。

基础地址保留代理路径、兼容尾斜杠，拒绝误填完整推理接口。OpenAI 不猜测或自动补 /v1；Anthropic/Gemini 避免重复版本路径。维持 HTTPS，Ollama 明文 HTTP 需自行使用 HTTPS 代理。所有重定向拒绝；分页不跟随远端链接、不跨主机转发密钥；错误不显示响应正文或密钥。更改协议/地址隔离密钥引用、缓存和旧参数，更改密钥清空编辑器缓存。缓存随服务商保存且可离线用，失败/取消不覆盖原缓存；保存本身不联网。服务商移除/恢复及旧单服务商迁移不变。

依据（2026-10-05 核对）：[OpenAI Models](https://developers.openai.com/api/reference/resources/models)、[Chat Completions 参数](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)、[Anthropic Models](https://platform.claude.com/docs/en/api/models/list)、[Gemini Models](https://ai.google.dev/api/models)、[OpenRouter Models](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties)、[Ollama OpenAI 兼容](https://docs.ollama.com/api/openai-compatibility)及[官方 OpenAPI](https://raw.githubusercontent.com/ollama/ollama/main/docs/openapi.yaml)。

验证：新增 14 项模拟 HTTP/请求编码/缓存隔离测试；**188 项核心 + 5 项 UI 全通过**（`.build/validation/core.DLPb76/Tests.xcresult`），包含旧 provider、停止、隔离、迁移回归，以及获取模型→参数→会话缓存选择。该阶段无签名 iPhoneOS build 通过（`.build/discovery-device-build.log`），截图在 `.build/discovery-ui/`。未读取用户实际密钥，未实测任何真实服务商、收费推理或物理设备。单响应单工具限制保留。

后续已授权、分任务提交：输入/授权卡片外背景；统一持久附件资源与图片历史；原生照片/文件选择及真实发送；SKILL.md 管理；按需 list/search/load 技能工具及图标。不自动导入本机用户技能，不执行脚本，不自动发送选中附件。

## 后续独立任务：输入区／授权卡片外背景

从模型发现阶段实际会话截图确认，额外背景来自 composer 共用容器的 `.background(.bar)`。仅移除该层，保留输入框和授权卡本体的圆角背景、safeAreaInset、键盘适配与原审批语义。新增亮／暗 2 项 UI 回归均通过，检查键盘不遮挡输入框、授权按钮在输入框上方、展开及滚动后仍可停止。证据 `.build/ComposerTests.xcresult`、`.build/composer-ui/`；无其他运行或协议行为变化。

## 共享依赖：持久附件资源层

`AttachmentStore` 按会话 UUID/内容 ID 存储原始资源，完整文件保护、排除备份、拒绝符号链接和跨会话读取。数据保存在独立文件，消息只需保存短引用；预览及发送用 PNG 从原图派生，发送图最长边 2048，不转发 EXIF。相同内容只在同一会话去重。支持单帧 PNG/JPEG/HEIC/WebP（20 MiB、5000 万像素以内）和 UTF-8 TXT/Markdown/JSON/CSV（256 KiB），其他格式明确拒绝。1 GiB 容量满后拒绝新增，不自动淘汰原图；显式清理需传入完整消息/草稿引用集合。远程图片客户端无凭据/Cookie、不跟随重定向；消息绑定由后续 UI/模型集成负责。

此提交为图片持久缓存与附件 picker 共用基础，尚不单独新增用户入口。8 项合成资源／模拟 HTTP 测试通过（`.build/AttachmentStoreVerified.xcresult`），覆盖重启、原图/预览、重复内容、会话隔离、文件类型/大小、路径/损坏修复、容量及保留引用、过期/重定向链接。未使用用户照片或文件。

## 后续独立任务：图片历史与本地缓存

新设备截图保存到统一资源层，消息仅记录资源引用；停止、重启后可展开缩略图并查看原图，历史图不恢复输入授权。已有标准 Markdown 图片链接提供按需下载／取消／重试，只访问所属消息已有的 HTTPS 图源，不附加服务商密钥、Cookie 或凭据存储，不跟随跳转。已缓存图片优先读本地，失效且未缓存的旧图片明确无法恢复。旧版只存文字的截图记录同样不伪造恢复。保留含资源的历史消息，设置提供确认后清理未引用附件，下载绑定期间阻止清理竞态。

5 项图片历史回归通过（`.build/ImageHistoryTests.xcresult`）；模拟器“合成截图→停止→重启→暗色原图预览” UI 通过（`.build/ImageHistoryUI.xcresult`，截图 `.build/image-history-ui/`）。覆盖本地重启、过期源、损坏修复、消息归属、删除期间下载、清理引用及旧授权不恢复。没有访问实际图源或用户图片。

## 后续独立任务：照片／文件附件与发送

输入左侧 44 点“＋”菜单打开系统 PhotosPicker 或文件选择器，不申请完整相册权限。选中内容复制到会话草稿，支持预览、移除、重复去重、取消、失败提示与跨会话隔离；只有显式发送才传给当前模型。图片派生为最长边 2048 的 PNG，文本文件内容随当前用户消息发送；当前用户附件在工具截图之后仍保留，旧设备截图只保留最新一张。草稿和历史只存资源引用，不保存文本附件正文／Base64。未支持的协议、类型及大小限制明确报错，失败保留草稿。历史附件不会自动再次发送。

5 项发送回归＋4 项 UI 通过（`.build/AttachmentNativeVerified.xcresult`）：原生照片成功／重复选择、原生文件选择／预览、取消、合成草稿移除及显式发送，真实 Agent 往返中的文本／图片保留，以及 Anthropic/Gemini 仅发现协议的发送拒绝。初期无键盘加号测试的自动点击未触发；实际中心触控成功，现以 44 点区域和中心触控验证，未将此归因于未取得调用栈的 Conversion error。截图在 `.build/attachment-native-ui/`。仅用合成资源；真实 iCloud／第三方文件提供器仍待设备验收。

## 后续独立任务：技能管理与按需读取

设置提供技能查看、启用／禁用、原生文件导入和明确删除确认。导入 SKILL.md 或根目录含该文件的纯文本目录；元数据支持 name、description、可选 version 的简单文本／多行值，格式与限制在页面说明。只收 UTF-8 Markdown/TXT，不执行脚本，不跟随符号链接，不自动导入本机技能。相同内容版本去重；同名不同内容保留独立 UUID/revision，旧版本不自动删除。持久存档受完整文件保护并排除备份，损坏原件保留。

每次运行冻结启用版本；仅注册 list_skills/search_skills/load_skill，前两者只返回名称与摘要。加载按精确 id/revision 和包内资源路径，正文每页最多 2000 字并返回 next_offset，避免大结果被框架直接裁掉；参考文档另外按需读取。工具每次检查当前运行／取消资格，技能文本不能改变设备权限或覆盖任务。无技能正文注入系统提示，无外部文件／脚本执行器。历史工具卡只保留公开文档回执，使用书籍类 SF Symbols 和技能名称。

7 项技能回归＋1 条完整 UI 流程通过（`.build/SkillFinal.xcresult`，截图 `.build/skill-ui/`）：导入与重启、版本去重／禁用／删除、损坏存档、非法路径／符号链接、取消、分页不漏字、真实 Agent 的查询→主文档→参考文档往返，以及系统文件选择→详情→启停→重复导入→取消删除／确认删除→工具卡名称图标。未调用真实模型，未读取实际用户技能。

## 图片缓存重试补充

原图丢失后，同一远程链接可能返回不同内容；修复重试只追加新资源、却仍先读到旧失效引用的问题。下载成功后按消息内图源替换绑定，其他附件及尚有效的本地原图保持原行为；旧孤立资源仍由用户确认清理。新增回归验证新原图重启后可读、旧资源可清理、远程链接随后过期也不再请求网络。图片历史／附件存储／无凭据下载共 **14 项通过**（`.build/ImageRetryVerified.xcresult`）。

## 最终综合验收（2026-10-05）

- 全套当前 target：**214 项核心 + 13 项 UI，0 失败**，`.build/validation/core.dGj1mk/Tests.xcresult`。界面截图与索引在 `.build/final-ui/`；已检查附件草稿、会话模型选择、历史原图与技能卡的代表性截图。
- 随后只修正技能回调在 Swift 6 下的并发捕获警告；最终源码再次通过 **214 项核心 + 1 项技能 UI**，`.build/FinalConcurrencyVerified.xcresult`。其他 UI 代码未再改动。最后无签名 iPhoneOS build 成功，`.build/final-device-build.log`；本次构建未出现编译警告。
- PA3 C 的 ASan/UBSan 协议／HID 夹具及 25 项本机 TCP 测试再次通过（`.build/final-protocol-tests.log`）；12 项 wire-contract 通过（`.build/final-wire-tests.log`）。固件源码未修改，不需本次升级。
- Xcode 附加诊断仍受本机默认 xcrun 路径影响，不能找到 simctl；测试结果为成功，截图以显式 DEVELOPER_DIR 导出。未更改系统 Xcode 选择或签名。
- 原 Page 有效实现及后续模型发现、输入区、共享附件存储、图片历史、原生附件发送、技能、缓存重试分别有本地提交。`Conversion error` 仍需真机原始调用栈；真实服务商／跨 App HID 闭环／iCloud 文件提供器，以及可选归档测试、旧 Host 全量未验收。Anthropic/Gemini 仍仅支持模型发现，未宣称原生推理可用。
- 历史私有 Library 交接包保留；暂停快照移到 [归档](../archives/history/handoffs/2026-10-05-project-todos.md)，不覆盖恢复开发后的状态。未启动云端执行或额度监控。当前额度不可读，未声称已触及 5%。

## B1：同一响应内多个工具（用户明确确认后）

授权依据：用户 2026-10-05 明确“B1 一条消息中允许多个工具调用”。从 `636f4b2` 继续，移除流式／非流式单调用拒绝及提示词限制。Chat Completions 兼容请求允许模型返回多个调用，Ollama 不发送其未声明的 parallel_tool_calls 字段；App 的 `parallelToolCalls` 仍为 false，按返回顺序串行执行，不并发操作设备。

完整响应校验后才释放工具：保留原始 tool_call_id，缺失／批内重复／跨轮复用均整批拒绝，无重试或重放。同步更新本地 SwiftAgentKit：按 ID 去重，允许 screenshot→tap→screenshot 这类参数相同但 ID 不同的显式步骤；每个结果保留对应 ID；停止或取消后剩余工具逐一返回未执行结果。普通校验错误可回传模型后继续，未知输入结果仍封锁本轮后续点击／拖动；原有逐动作或任务授权、单次审批、截图资格和断线释放不变。

新增合成 Agent 回归覆盖混合技能／设备工具、多次观察、授权顺序、中途未知结果、可恢复错误、取消、拒绝、重复 ID 和下一模型轮次收到全部结果。流式／非流式解析覆盖整批缓冲、原始 ID 和请求字段。首轮发现旧测试仍要求 parallel_tool_calls=false，按本次授权更新，未移除安全断言。31 项定向回归通过（`.build/MultiToolVerified.xcresult`）；模型发现／安全测试另 24 项通过（`.build/MultiToolProtocolVerified.xcresult`，包含重复复核的 12 项安全测试）。最终综合结果追加在后续验收。

## B6：服务商思考内容／摘要展示

授权依据：用户同次明确“B6 要支持思考消息展示”。在现有 Agent 事件→会话存档→SwiftUI 消息组件中贯通，使用与工具卡一致的原生 DisclosureGroup，默认折叠，显示接收中／已完成／已中断／生成失败。正文和思考分别保存；只有思考的工具轮次也保留，不用答复覆盖。停止、网络错误或重启后保留已收到部分，迟到事件不能写入其他运行／会话。旧存档可读；新任务上下文只使用公开正文，不自动回传历史思考。

| 当前推理路径字段 | 支持范围 |
| --- | --- |
| Chat Completions `choices[0].delta/message.reasoning_content`、`reasoning` | 仅字符串，流式增量及非流式完整响应 |
| `reasoning_details[].type == reasoning.summary` 的 `summary` | 可读摘要；流式／非流式均支持 |
| `reasoning_details[].type == reasoning.text` 的 `text` | 可读文本；同块拼接、不同块分段 |
| encrypted／opaque／signature／未知对象或类型 | 不展示、不存入思考正文；不解码为文本 |
| 普通 `content` 中的 `<think>` 等标签 | 仍是普通答复，不猜测或抽取为思考 |

同一响应固定使用首个有内容的可读通道；同时出现时优先 details，再 reasoning_content、reasoning，避免别名重复展示。字段依据本地固定版本 SDK 和 [OpenRouter 官方 reasoning_details 说明](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)。未新增 reasoning effort／预算参数，不要求服务商披露未提供的内容。OpenAI-compatible、OpenRouter、Ollama 的现有 `/v1/chat/completions` 路径按以上字段识别；没有字段就不显示区块。原生 Anthropic/Gemini、OpenAI Responses、Ollama 原生 `/api/chat` 以及需要签名／加密 reasoning 跨工具轮次回传的模式尚未接入，不能据此宣称这些模式兼容。

新增 9 项解析／历史／真实 Agent 合成回归，覆盖字段与别名去重、忽略加密内容、普通正文不抽取、取消／错误、旧存档／重启、跨会话迟到事件、思考→多工具→下一轮答复。初次 22 项定向单元测试通过（`.build/ReasoningInitial.xcresult`）；该次 UI 失败经层级证实是父 DisclosureGroup 标识覆盖正文标识，已把标识限定到标题，3 项 UI 随后全通过（`.build/ReasoningUIVerified.xcresult`）。已检查 `.build/reasoning-ui/` 中完成、失败、流式和暗色恢复的 4 张截图。包含追加的完整链路用例在内，231 项核心回归已全部通过；最终 UI／构建结果见后续验收。
