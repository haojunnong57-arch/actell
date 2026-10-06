# USB 任务授权与后台执行 · 2026-10-04

当前实现位于 `with-esp/main`，基线 `dfa3d2de906a5a0ed9e47c45e90dd9fe9b369f63`，本轮未提交或推送。按用户“这些限制都先去掉”的要求，移除 USB 普通动作逐次回前台批准、每段后台 60 秒、任务总计 5 分钟三项策略。此前实现和验证记录保留在 [BACKGROUND.md](BACKGROUND.md) 与 [NO-PSK.md](NO-PSK.md)，涉及上述限制的旧说明已被本页取代。

图片时效和模型动作参数已进一步简化，见 [当前截图策略](IMAGE-POLICY.md)。USB 连接现已跨任务复用，PA3 同时升级 App 和固件，见 [常连升级说明](../../../../docs/usb-device/PERSISTENT-USB.md)。本页验证数字与原“无需烧录”范围是上一阶段记录。

后续已修复 HID 连接时前台查看屏幕误等后台、超时后主动断开 USB 的问题。截图在前台也可读取，输入仍要求目标场景；停止诊断升级至 `usb-diag-20261004-5`。详见 [前台截图修复](FOREGROUND-CAPTURE.md)。

## 授权行为

- 用户在前台发送任务、点击开始或确认 Siri 草稿后，当前真实 USB HID 任务获得普通点击和拖动的任务授权。不会因打开历史、点灵动岛链接、USB 重连或 App 重启自动开始或重放任务。
- `AgentViewModel` 只为真实模式的 `USBDeviceBridge` 选择 `InputAuthorizationMode.task`。旧 TLS Host 和演示仍使用原逐动作批准流程；本地只读采集不能获得输入授权。
- 自动授权不进入 `waitingApproval`，不撤销当前采集执行资格，也无需逐次切回 PhoneAgent。每个动作仍绑定 run/generation、callID、参数摘要、imageID 和期限，持久记录明确标为 `task`，随后一次性消费；取消或重启不能复用。
- 发送前仍检查当前采集会话、USB 心跳、场景、帧序号、方向和尺寸，并比对编码后画面；停止或场景变化会撤销许可。executed ACK 后必须取得更新帧才允许下一次输入。模型和屏幕内容不能改变授权模式。
- 输入仅限现有 tap/drag 工具，不增加文字输入或其他设备能力。现有敏感操作交给用户处理的模型指令保持有效。

此前灵动岛的“查看并确认”实现是 `Link`，会打开 App 的审批界面，并没有直接执行批准的 `LiveActivityIntent`。Apple 支持通过 App Intent 实现 Live Activity 内的按钮交互；本次选择任务开始授权，因此没有增加新的灵动岛批准按钮，现有状态和导航继续使用。[Apple 交互说明](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)

## 后台机制与仍保留的停止条件

后台机制此前已经启用。SCK 路由使用 `UIBackgroundModes=screen-capture` 和 `ScreenCaptureRunScheduler`，后者是 App 内部对有效采集/USB 会话的核验，不是独立的系统保活任务。Apple 文档明确说明该后台模式让全屏采集流在 App 进入后台后继续。[ScreenCaptureKit iOS 文档](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios)

普通非 SCK 任务使用已接入的 `BGContinuedProcessingTask`。`RunExecutionScheduler` 每轮只选择一个来源，SCK 任务不会同时再申请 Continued Processing。系统可因资源不足或用户取消中止后台处理；移除 App 自定截止不等于保证整个模型/网络/输入循环无限运行。[BGContinuedProcessingTask 文档](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)

本轮删除 `ScreenUSBExecutionContext` 的后台/总时限、`AgentLimits.maxRunSeconds`、动作协调器和 ViewModel 的总时限检查。没有用静音音频、无线通信或额外 VPN 保活。

以下仍有效，界面不再将它们表述为固定后台时长：

- 用户停止、锁屏、采集停止/换代、USB 断连/心跳失败立即撤销输入；不自动恢复。
- 首帧等待 5 秒、USB 路由单次截图等待最多 15 秒、输入画面匹配等待 15 秒，以及采集会话和通信健康检查；截图不再设置年龄上限。截图不再要求必须先切到目标 App；只有输入要求目标场景。这些限定一次等待或画面有效性，不会每 60 秒或满 5 分钟终止健康任务。
- 60 秒没有有效模型/工具进展的停滞检查与网络请求超时仍在，正常响应/工具结果会更新进展。它不是后台每段 60 秒计时。
- 每轮最多 12 次模型调用、16 次输入、每次输出 1024 tokens、已报告累计 20,000 tokens 的预算保持；没有改成无限调用模型。
- 当前 PA3 在本轮结束后释放 HID 并保留 USB；下一轮任务复用健康连接。真实断线或无法确认释放仍关闭。系统采集许可仍由用户在 picker 中确认。

## 本地验证

工具链沿用 Xcode 27.0（27A266a）、iPhoneOS/iPhoneSimulator 27.0 SDK、Swift 6.4（Swift 5 语言模式）和现有 Package.resolved，没有安装或更新依赖。原始日志仅在 Git 忽略的 `.build/validation/background-continuous/`。

- 最终完整单元测试：151 项、0 失败，`ios-unit-final.log`。覆盖超过旧 60 秒/300 秒后仍可执行、后台任务无逐动作审批完成、Siri 任务确认和灵动岛导航不重放、任务授权持久记录和一次性消费、旧通道拒绝任务授权，以及停止/锁屏/采集丢失/USB 失败时零输入。
- 首轮 `ios-unit.log` 有一项旧 Siri/灵动岛用例仍等待已经移除的逐动作审批而失败。已改为验证确认任务后后台完成及原有防重放行为，随后完整回归通过；首轮日志保留，没有将其报告为全程一次通过。
- 模拟器 UI 回归：1 项、0 失败，`ios-ui.log`。检查系统采集必须显式发起、后台开关不存在、任务授权说明存在且不含旧固定时限，以及诊断导出版本。模拟器不提供真实 SCK 全屏流。
- 最终 iPhoneOS 无签名构建通过，日志 `ios-device-final.log`。工程签名配置及 Info.plist 与本轮开始的摘要一致。

新增日志版本 `usb-diag-20261004-4`。`run.authorization mode=task fixedDurationLimit=false` 和 `input.authorized source=task tool=tap/drag` 可用于识别新的路径，不输出任务文字、坐标或截图。此前 `run.route`、连接和停止诊断继续保留。

本轮没有打开串口、刷写、安装真机 App 或调用外部模型。ESP32 固件维持已烧录的 NCM+HID 版本，详见 [烧录记录](HID-BRINGUP.md)。本机编译和模拟器夹具不证明真机 HID 或持续后台 Agent 闭环成功。

## 下一步真机复测

该阶段原本只需重新构建安装 App；后续 PA3 常连升级需要同时更新固件，见 [常连复测](../../../../docs/usb-device/PERSISTENT-USB.md#真机复测)。确认全屏采集可预览、USB 状态为 NCM + HID。只看屏幕可留在 PhoneAgent；普通点击/拖动任务由用户开始后切到目标 App。期望连续完成“截图 → 模型 → 输入 → executed → 新截图”，过程中无需回 PhoneAgent 审批。

日志应包含 `run.route selected=usbHID` 和任务授权标记；若中止，在重启前复制完整 USB 日志。健康运行跨越原 60 秒/5 分钟边界、真实坐标与旋转、锁屏/拔线/停止释放、供电和现有蜂窝/VPN 共存仍待真机验收。系统资源调度也需实际观察，不能从后台采集成功推出全部环节已成功。
