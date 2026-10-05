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
| 查看屏幕后“提交执行结果” | finish 已非强制，schema 仍暴露 | 真实模型只注册 screenshot/tap/drag/wait，以最终文字答复结束；历史 finish 展示名改“结束本轮”。截图的 tool result 仍正常返回模型，不是多余工具调用 |
| 多余运行限制 | 部分已移除；次数/token/框架 loop 仍在 | 去除 12 轮、16 次输入、20,000 累计 token、1024 输出 token、默认 60s lifecycle inactivity、URLSession 45/60s 强制超时及框架重复循环终止。使用系统网络超时；保留响应体/协议大小、实际后台资格、锁屏、采集终止、手动停止、防重放和未知结果输入阻断 |
| 导航栏设备按钮 | 仍需 | 会话首页及会话内按钮打开设备控制面板，管理采集/USB 连接、取消与断开；关闭面板不触发任务收尾 |
| 多服务商/会话选模型 | 仍需 | 独立页面增改、确认移除及恢复；会话保存 provider UUID/model ID。旧配置保留原 Keychain 引用，地址变更不携带旧地址密钥，同地址不同新服务商可独立持有密钥。移除后已绑定会话不会静默改用其他服务商。运行中不变更配置 |
| 设置移除 USB | 仍需 | 设置只保留记录管理和后台说明，设备与服务商各自独立 |

原 STOP 审计证据更正：连续命令 **ID2 STOP 与 ID3 STOP**，五轮复现均只有 ID3 的 executed；不是“五个 STOP 收到三次”。本次 PA3 测试期望 ID2 executed、旧代号 ID3 cancelled，两边均有明确终态。

实施阶段为：恢复/执行生命周期 → 设备入口与服务商 → 归档及回归。真实输入权限沿用 `80b1c8f`，未扩大任务授权。

## 回归与构建

- PA3 生产 C 的 ASan/UBSan 协议/HID 夹具通过；25 个本机 TCP 测试通过（含 ID2/ID3 STOP、重复 ID、取消、断线、代号撤销、STOP 丢失回执）。无实际 USB/HID。
- 12 个 Python wire-contract 回归通过。
- 新增 XCTest：双文件未知事务保全/去重/新运行后保留/无授权复用；迁移 Keychain 引用、独立服务商、地址变更、删除恢复与会话绑定；并发 cleanup 一次释放；单一定时器；心跳取时竞态；18 次输入及 14 次重复观察/超过20,000报告 token 后正常完成；真实 schema 不提供 finish。
- 首轮 172 tests 中存在 11 个失败断言，不能引用旧“166 tests”作最新覆盖。部分是基线已取消的前台/画面匹配限制，部分是测试夹具仍要求 finish。已保留并改写未授权拒绝、撤销/单次消费测试；恢复测试原来保留 pendingApproval 的断言改为不可恢复授权。
- 最终源码 XCTest：**174 个核心 + 4 个 UI 全部通过，0 失败**，证据 `.build/validation/core.yGz9qf/Tests.xcresult` 与同目录 `test.log`。UI 覆盖设备面板/设置入口、多服务商/会话模型选择、确认取消/移除/恢复、历史停止不重放。已核对 `.build/ui-final/` 的 6 张截图。iOS 27 的 confirmationDialog 未显示显式取消按钮，已改成带取消按钮的 alert。
- 最终 iPhoneOS 27 无签名 build 通过（`.build/device-build-verified.log`）。生成工程的全部 build settings 与基线一致，包含原 Live Activities 声明，签名配置未改变。存在原有方向支持警告；没有新增编译错误。
- 此次模拟器 UI 及 App 运行日志未出现所报 Conversion error（`.build/conversion-check.log`），不能据此认定真机问题已修。主机默认 xcrun 路径使 Xcode 的附加诊断收集失败；通过明确的 DEVELOPER_DIR 导出截图和日志，测试本身成功。未改变系统 Xcode 选择。
- 可选归档 PiP 展示/Siri UI、旧 Host 全量、真实服务商与真机测试未跑；本次未改相应固件或 Siri 功能。默认工程与临时恢复归档工程均已检查文件引用，最终提交默认工程。
- 原始构建日志、xcresult、截图只在本分支 `.build/`，不提交用户设备或会话原始数据。默认测试命令见 [App README](../ios-app/README.md)。

## 边界与待证据

未推送、未合并主线、未烧录、未运行真实设备输入、未更改签名/系统设置，未请求真实模型服务。固件源码无变化，继续兼容 PA3，无需本次固件升级。

待真机验收：系统采集授权、AssistiveTouch HID 的拖动/停止/断线释放、跨 App 持续闭环、多服务商实际视觉/工具兼容性，以及 Conversion error 原始调用栈。用户此前报告 PING、截图与点击可用不等于上述全量验收。

自动审批审查拒绝了取消“每次模型响应仅一个工具”的附加改动，认为可能扩大单次响应触发的输入范围。该边界仍保留，未绕过；如要取消，需用户明确确认具体多工具输入行为。审查也曾拒绝直接反转旧权限测试；随后改为保留未授权拒绝并用实际 `80b1c8f` 证据区分观察与显式授权，未修改生产输入授权规则。

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
