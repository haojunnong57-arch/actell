# 后台执行中断、工具回执和实时活动（2026-10-07）

本次从真实 iPhone 读取最后会话、该会话独立检查点、后台事件和系统日志；没有重新执行历史动作。

## 实际中断原因

- 16:57:39.458，kernel 记录 `memorystatus: killing PhoneAgent [3456] due to cpulimit violation`。
- symptomsd 记录进程约 55.85 秒消耗 48 秒 CPU，超过系统 60 秒窗口内 48 秒的限制。系统因此强制终止进程；没有 App 主动暂停、用户停止或媒体到期的记录。
- 同版本在 16:52:42 生成的 `cpu_resource_fatal` 报告也是相同限制。同一类报告 300 秒内限流，因此 16:57:39 没有再次生成独立 IPS；系统日志明确记录 `Disallow report`。
- 使用 UUID 完全匹配的 Xcode dSYM（debug dylib `A9F0ECC8-47C0-3E91-80BC-B179AB6CFD15`）解析先前报告，16/17 个样本在主线程，热点在 `ConversationView.body/composer`、`AgentPresentationAdapter.pendingApproval` 及 SwiftUI 更新；另一个样本含视频解码。不能把此次终止归为 GPU 或后台任务到期。

原会话存储每收到一个思考片段都发布整个 `conversations` 数组，后台仍驱动会话页面、附件菜单和参数／审批遍历。现将页面通知与执行记录分开：后台继续更新数据与保存文件，不发布隐藏页面的文本更新；回前台时一次通知展示累计内容。运行、审批、媒体、设备连接与 Live Activity 的控制不依赖该页面通知。

## 为什么拖动显示已取消，实时活动停在拖动

两个末尾拖动在检查点都已到达 `observedResult`，随后还完成了截图。该标记表示动作此前收到送达回执、之后获取过截图，不证明绘图效果正确。它们的 UI 记录却只有授权／执行状态，没有参数与结果；最后一次截图也尚未投影到消息记录。这说明异步观察事件落后于实际执行。

原来工具完成、清除 `activeActionCallID`、更新实时活动，都依赖与大量流式文字共享的 FIFO 观察者。进程被系统杀死时，剩余事件无法消费；下次启动，`closePendingMessages` 将所有未完成 UI 工具统一改为“已取消”，且没有填入结果说明。

修复：

- 在框架 `afterTool` 回调中、下一次模型请求之前保存结果和参数，完成审批记录、清除当前动作、更新活动；观察事件保留为兼容路径，并按 call ID 去重，迟到的开始事件不能把已完成工具改回执行中。
- 有效文字／思考进展每十秒最多刷新一次活动的新鲜时间，避免长思考仍显示上一动作。没有进展时不伪造心跳；进程被强制杀死后仍依赖系统的 stale 状态，下一次启动结束遗留活动。
- 启动恢复按会话、run ID、工具 ID 和名称对照检查点。输入已确认送达则显示真实回执；已经发出但未确认则显示“结果未知”；仅准备而未发送的调用才显示取消。读工具丢失结果时不伪造图片或应用列表。
- 保留明确失败／拒绝结果；不恢复执行、不重放动作、不让其他运行或会话继承结果。对旧版误标为取消的空记录也执行同样修复。
- 中断工具保留结果说明，只有思考文本时显示“思考已中断”。会话不再追加恢复说明，已有通知原样保留；灵动岛跳转只定位消息、不显示说明栏。

## 验证入口

本次私有设备原始证据保存在忽略目录 `.build/last-run-investigation/`，不提交会话全文或设备日志。

- `system-last-run.log`：16:57:39 的 CPU 终止与 16:58:11 重启。
- `cpu_resource_fatal.ips`、`symbols.txt`：同版本报告及匹配 dSYM 的解析结果。
- `last-checkpoint.json`、`conversations-v1.json`：检查点与 UI 结果差异。
- 默认核心回归增加后台不发布 UI 但继续持久化、送达／未知／未发送恢复、不追加恢复通知且保留已有通知，以及下一模型请求前保存工具回执的覆盖。
- Debug 离线真机对照：`--task-pip-probe --background-stream-probe`，每次等待至少 20 ms 后生成一个合成思考片段，共 4500 段，本机实际约 102–106 秒结束；音频保活，不申请系统后台任务，不调用模型、不执行设备输入、不写入用户会话。增加 `--background-presentation-baseline` 可仅在此夹具中重新开启后台页面发布，作为负对照。进程 CPU 累计时间用 `getrusage` 记录到 `background-execution-events.log`。

最终验证：

| 同一 Debug 构建的离线真机路径 | 后台测量时长 | CPU 时间 | 平均 CPU | 任务／活动 |
| --- | ---: | ---: | ---: | --- |
| 重新开启后台页面发布的负对照 | 90.10 s | 36.14 s | 40.1% | 正常完成 |
| 修复路径 | 90.19 s | 3.04 s | 3.4% | 持续更新并正常完成 |

测量从进入后台时的第一个采样开始，排除最初十秒前台时间；修复路径稳定后台区间约 2.8%，表格保留完整切换后区间。该对照只验证后台 UI 更新的 CPU 影响，不代替真实模型／NCM 长任务的持续执行验收。

- **309 项核心测试通过，0 失败**：`.build/validation/core.ZTWBIP/Tests.xcresult`。iPhoneOS 无签名及已有开发签名构建通过。
- `baseline-events.log`、`fixed-events.log`、`cpu-comparison.json` 保留负对照和修复路径原始测量，两轮都有后台 `activity.ended phase=completed`。
- 恢复普通 App 后再次读取真实会话：两个原先空白取消的拖动均恢复为 `succeeded`，有原检查点参数与 `Command delivery acknowledged.`。会话仍是 interrupted，未启动或重放原任务。
- 移除恢复说明和活动跳转提示后，新版已安装。对比更新前后真实会话文件，所有历史消息与恢复通知元数据均原样保留，没有追加新提示；记录见 `copy-removal-preflight.json` 与 `copy-removal-after.json`。
