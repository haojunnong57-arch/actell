# 截图不设时间有效期，动作自动关联截图

> 2026-10-05 收尾策略更新：移除“用过截图就必须调用 finish”的规则，模型最终文字可以正常结束设备任务；finish 也不再要求持有截图。只有普通工具调用前的解说不作为最终回复，空回复明确显示“模型未返回结果说明”，真实工具错误继续展示。运行结束只表示对话结束，不代表 HID 已产生可见效果。诊断版本 `usb-diag-pa3-input-4`，新增 `run.ended reason=… finishRequired=false`，仅修改 App，无需更新固件；按用户要求不更新或运行测试。

本轮 iPhoneOS 无签名编译通过，日志位于忽略目录 `.build/validation/optional-finish-20261005/ios-device-build.log`。测试文件、固件源码、工程签名配置和 Info.plist 的摘要与本轮开始一致；未安装 App 或烧录，指针显示及真实点击效果仍待确认。

> 2026-10-05 输入策略更新：按用户要求，允许在 PhoneAgent 自身及其他 App 输入，删除 PNG 内容比对、方向/尺寸变化拒绝、15 秒匹配等待和发送时新帧序号/场景一致性拦截。停止、锁屏、采集结束、USB 故障仍撤销输入。诊断为 `usb-diag-pa3-input-3`，本次只需更新 App。最终版本仅验证 iPhoneOS 无签名构建；按用户要求测试用例保留本轮开始状态，不更新或重跑，旧拒绝策略测试暂不代表当前行为。

按用户要求，在 `with-esp/main` 的既有未提交改动上移除图片过期策略及模型工具 `based_on_image_id` 参数。基线提交为 `dfa3d2d`。该阶段未改变 USB 连接生命周期；后续已实现 [PA3 常连](PERSISTENT-USB.md)，必须同时更新 App 和固件。

## 当前行为

- `tap` 参数只有 `x`、`y`、`purpose`；`drag` 参数只有起终点坐标、`duration_ms`、`purpose`。App 自动使用本轮最近一次 screenshot 工具返回的画面。工具 schema、模型提示、演示 provider 和工具卡片已同步。
- 删除 `AgentLimits.maxScreenshotAge` 和动作/finish 的 45 秒图片限制；删除 USB 输入层 5/45 秒限制，以及采集缓存、PNG 编码、执行资格和最终发送检查中的 2 秒新帧限制。
- 采集会话仍有效时，静止画面不因一段时间没有新样本而停止。读取缓存不会篡改序号、原始时间戳或诊断中的帧年龄，也不会把 idle 伪装成新样本。
- 旧 Host/演示的单次确认请求仍从请求创建时计时 45 秒，已与图片采集时间解耦。真实 USB 普通输入沿用任务开始授权，不显示逐动作确认。
- 截图返回值中的 `image_id` 仍是观察元数据；App 内部仍用标识符隔离会话、并发和一次性授权。旧 TLS Host 的同名 wire 字段由 App 自动补入以兼容原协议，模型不用传；PA2/PA3 NCM/HID 均不传输图片 ID。

## 保留的校验

系统采集结束、blank/suspended/stopped、会话换代、锁屏、用户停止及 USB 心跳/连接丢失仍停止输入。坐标范围、一次性许可和结果未知不重放仍在；方向/尺寸变化、目标场景、画面内容比对及输入时新帧序号一致性拦截已按用户要求移除。

动作或 wait 后仍需再截图；动作 executed ACK 后仍要求取得 ACK 之后的帧，不能用动作前截图验证执行结果。首次样本等待 5 秒、单次截图/目标场景匹配等待上限、USB 回执超时继续存在，它们不检查图片年龄。输入不再等待画面匹配，也不因画面变化拒绝。

图片策略与连接生命周期独立。后续 [PA3 常连实现](PERSISTENT-USB.md) 已把停止输入和关闭 TCP 拆开；真实通信故障仍关闭连接。

## 验证与复测

本地证据保存在 Git 忽略的 `.build/validation/no-image-expiry/`。测试只使用合成画面和离线 provider，不调用模型服务、不上传实际屏幕。最终结果见 [VALIDATION.md](VALIDATION.md)。

该阶段诊断版本为 `usb-diag-20261004-6`（当前 PA3 为 `usb-diag-pa3-persistent-1`），新增固定标记 `imageExpiry=disabled modelImageIDParameter=false`。单独的图片策略改动无需烧录；当前 PA3 常连升级须同时更新固件和 App；静止画面、较慢模型返回和实际 HID 输入仍需设备复测。
