> 当前源码已升级为 [PA3 常连](PERSISTENT-USB.md)：停止任务释放 HID 并保留 TCP，App 与固件必须同时更新。本文 PA1/PA2 构建、烧录和测试结果是历史记录；PA3 已完成 COM 烧录和启动检查，iPhone 端仍待验收，见该升级说明。

> 后续变更：图片的 2/5/45 秒年龄限制和模型工具 `based_on_image_id` 参数已移除。本文相关旧策略/测试是历史记录，当前行为见 [截图策略](IMAGE-POLICY.md)。

# 前台查看屏幕与主动关闭 USB · 2026-10-04 UTC

在 `with-esp/main`、基线 `dfa3d2d` 的已有未提交改动上修复。仅修改 App 和回归测试；签名配置、Info.plist 和固件源码与本轮开始摘要一致。本轮未提交、推送、访问串口、烧录或安装真机 App。

## 用户日志与原因

用户提供的两次失败报告具有同一顺序，以下时间为 UTC：

| 事件 | 第一次 | 第二次 |
| --- | --- | --- |
| 选择 `usbHID`，采集与 USB 健康 | 15:54:29.376 | 15:56:07.877 |
| 停止前采集仍 active、新帧年龄很小 | 15:54:43.965，age 0.00 s | 15:56:23.836，age 0.04 s |
| App 主动请求 STOP | 15:54:45.212 | 15:56:24.145 |
| 设备返回 STOP executed | 34 ms 后 | 32 ms 后 |
| 本地关闭连接，ViewModel 场景仍 active | 15:54:45.249 | 15:56:24.179 |

两轮都有有效 `PA2 READY 1`、持续 PING 回执，停止前没有网络错误。USB 已断开是 App 停止流程的结果，不能反推此前 USB 网络先断开。

对应代码错误：连接 HID 后路由选择 `USBDeviceBridge`；该桥的 `screenshot()` 和输入共用了 `context.observation()`，后台能力开启时只有 `.background` 才能通过。于是 App 明明持续收到有效帧，在前台查看屏幕却一直取不到“允许观察的场景”，等待约 15 秒后调用 `lost()` 主动 STOP，并由无原因参数的回调统一显示“采集或 USB 连接失效”。只读 `LocalScreenBridge` 原先使用另一套 `captureObservation()`，因此未连接 USB 时没有同一个场景限制。

## 本轮修复

- USB 桥的截图改用 `captureObservation()`：前台可直接读取 App 的系统采集画面，后台须取得切换后的新帧，inactive 仍等待。编码前后检查场景 revision，动作后继续要求 executed ACK 之后的新帧。
- HID 授权和发送仍使用目标场景检查，前台读取成功不授予前台输入权限。若模型在 PhoneAgent 前台请求输入，返回切换目标 App 并重新截图的具体提示。
- 停止回调携带原因：会话检查、心跳请求、截图等待、画面改变或输入结果异常。`bridge.stop` 在实际 STOP 前记录原因；截图超时不再一律显示“USB 失效”。
- `ScreenUSBExecutionContext` 保存首次失效原因，区分 `captureEnded`、`firstFrameTimeout`、`staleFrame`、`usbHeartbeat`。后续撤销和迟到帧不会覆盖该原因；生命周期和 watchdog 使用同一个具体提示。
- 桥发起 STOP 前也将原始停止原因交给执行上下文。等待 STOP ACK 期间，watchdog/生命周期可能先观察到撤销；现在这些观察者仍报告原始原因，不把截图超时或心跳请求失败改写成笼统的执行资格失效。
- 日志版本 `usb-diag-20261004-5`。新增 `screenshot.begin/ready`、`bridge.stop reason=…`、`run.healthFailed source=…`，记录场景、帧序号/年龄、心跳年龄与失败分类，不包含截图、动作坐标、任务文字或原始外部错误正文。
- 清除系统提示词末尾残留的“每次输入需前台批准”，与已实现的 USB 任务开始授权保持一致。

每轮任务正常结束仍会释放并关闭 USB，控制页会显示“本轮已结束”；这不代表本轮截图失败。下一轮输入任务仍需重新连接。

## 新增健康检查报错的边界

用户随后又报告“执行资格失效或采集 / USB 不健康”，尚未提供该次停止窗口及构建版本。该提示既可能来自实际健康检查，也可能由上述 STOP 清理与 watchdog 竞争覆盖原始错误；不能只凭提示认定 USB 断线或画面过期。

先前完整日志的静止阶段可见 accepted 不增长、帧年龄达到十多秒。当前实现仍保留 2 秒新帧要求；它可能触发不同的停止路径，需要新日志中的 `failure=staleFrame` / `usbHeartbeat` 确认。**本轮没有把静止或旧画面自动当作新帧，也没有放宽输入新鲜度要求。** 采集显示 active 仅表示会话存在，不证明近期有新样本。

本地 iPhoneOS 27.0 SDK 的 `SCStream.h` 将 idle 定义为屏幕未变化而没有新帧；但用户这份日志的 rejected 中没有 idle，因此不能声称已收到 idle 确认。SDK 同时明确 `minimumFrameInterval`、`updateConfiguration` 和 `SCScreenshotManager` 不可用于 iOS，不能照搬 macOS 的帧率或截图方案。[Apple ScreenCaptureKit iOS 文档](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios)

## 验证与复测

离线回归新增：HID 就绪时前台截图成功且零输入/零 STOP、前台只看屏幕的 Agent 任务完成、inactive 期间等待后台新帧、心跳错误与截图超时分类隔离，以及首次失效原因在清理后保留。既有后台输入、动作后新帧、停止/锁屏/断连和防重放测试继续执行。最终结果见 [VALIDATION.md](VALIDATION.md)。

最终完整 156 项单元测试、1 项诊断 UI 回归和 iPhoneOS 27 无签名构建通过。工具链仍为 Xcode 27.0（27A266a）、iOS 27.0 SDK；未更新依赖。最终单元和设备构建分别为 `ios-unit-release.log` / `ios-device-release.log`，UI 成功在 `ios-tests-final.log` 中。

原始构建与测试日志位于 Git 忽略的 `.build/validation/foreground-capture/`。修复前的只看屏幕 Agent 用例超时；直接桥测试初轮还暴露了测试夹具未持续更新心跳，已为夹具补充帧/心跳。一次全套测试在既有 Siri 用例遇到测试进程异常退出/超时，原因未确定，保留失败日志。另一次后台成功用例的连续帧夹具在许可到发送之间替换了帧，触发原有拒发保护；成功用例改为发送期间维持同一新鲜画面并继续心跳，独立的换帧拒发/锁屏/断连用例与生产检查均保留。没有放宽成功次数或停止断言。后续完整测试结果单独记录。

复测只需重建安装 App，无需重烧 ESP32：

1. 确认采集预览正常并连接 NCM+HID，留在 PhoneAgent，发送“查看屏幕”。期望截图与模型结果正常返回，不再因等待切后台而失败。
2. 若再次停止，在重新连接前复制诊断报告，核对版本为 `usb-diag-20261004-5`，查看 `screenshot.ready` 与具体 `failure` / `reason`。
3. 普通控制任务仍需用户开始后切到目标 App；真实 HID 坐标、长期静止画面处理及完整后台闭环尚待真机验证。
