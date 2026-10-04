# USB 连接跨任务复用 · PA3

> 最新真机反馈（2026-10-05）：用户确认开启辅助触控后点击生效；此前日志已显示 PA3 TAP 的 received/executed 以及任务结束后 TCP 保持。完整后台连续运行仍待验证。最新 App 收尾修复版本为 `usb-diag-pa3-input-4`，见 [验证记录](../../archives/history/docs/usb-device/VALIDATION.md) 和 [截图/收尾策略](../../archives/history/docs/usb-device/IMAGE-POLICY.md)。

> 2026-10-05 输入策略更新：按用户要求，允许在 PhoneAgent 自身及其他 App 输入，删除 PNG 内容比对、方向/尺寸变化拒绝、15 秒匹配等待和发送时新帧序号/场景一致性拦截。停止、锁屏、采集结束、USB 故障仍撤销输入。诊断为 `usb-diag-pa3-input-3`，本次只需更新 App。最终版本仅验证 iPhoneOS 无签名构建；按用户要求测试用例保留本轮开始状态，不更新或重跑，旧拒绝策略测试暂不代表当前行为。

按用户要求，在 `with-esp/main` 的既有未提交改动上同时修改 App 与固件。基线 `dfa3d2de906a5a0ed9e47c45e90dd9fe9b369f63`，未提交或推送。PA3 已于 2026-10-04 17:24 UTC 通过 COM 烧录并完成启动检查，详见本页实际烧录记录。协议直接升级为 [PA3](PROTOCOL.md)，没有旧版兼容分支。

## 行为变化

| 触发事件 | 现在的行为 |
| --- | --- |
| 正常结束一轮任务、停止/取消任务、截图失败或采集失效 | 撤销本轮输入，等待 HID 释放回执，保留 TCP |
| 切换 App、空闲时进入后台、锁屏 | 不因场景事件直接关闭已建立的 USB TCP；锁屏仍停止任务输入 |
| 下一轮任务 | 复用已连接客户端，取得新的内部输入代号 |
| 取消单条 PING | 取消调用方等待，继续消费迟到回执；保留连接 |
| 取消已发送的输入 | 取消等待并释放本轮 HID；不将部分执行误报为成功 |
| 明确点击断开、真实 socket/协议失败、回执超时或无法确认释放 | 关闭 TCP，及时更新 UI；不自动重连或重放 |

`AgentViewModel` 分离 USB 与 Agent 的生命周期代号，结束任务不再清空 USB 客户端。建立连接后再次点击连接不会替换健康连接。`USBCommandClient` 是唯一 PING 发送者；`USBDeviceBridge` 只检查采集和通信健康。

每轮任务的输入会话包含连接标识与递增代号。固件 STOP 立即撤销旧代号，释放完成后允许下一代任务使用同一 TCP；旧输入与迟到 STOP 不能操作新任务。命令 ID 和去重记录跨任务保留。回执分为 received、executed、cancelled；cancelled 的输入可能已部分执行。

图片仍无年龄上限，模型仍不传 `based_on_image_id`。内部输入代号用于隔离任务，不是图片 ID 或图片计时。图片尺寸/方向变化和目标画面匹配拦截已删除；动作后观察、系统采集有效性与停止机制继续保留。

常连没有取消真实故障检测：App 在无 ACK 时仍关闭；固件在总线换代/失效、主动输入丢失心跳、释放超时或长时间没有新命令时仍关闭。屏幕采集后台能力不保证系统永远调度 App，长期后台和锁屏/拔插恢复仍需要实测。

## 本地验证

全部日志位于 Git 忽略的 `.build/validation/persistent-usb/`：

- `firmware-tests-final.log`：C 协议/HID 时序断言及 ASan/UBSan 通过；24 项生产 TCP 状态机回归通过。覆盖连续任务、取消输入、STOP/PING/输入流水线、重复 STOP、旧代号、释放超时和总线换代。
- `ios-tests-final.log`：166 项单元测试与 1 项诊断 UI 回归，0 失败。包含 5 项真实 NWConnection 连接 localhost 测试：跨任务复用、取消 PING 后迟到 ACK、取消 DRAG 与重复释放、STOP 丢 ACK、空闲真实 EOF 更新 UI。其余生命周期测试覆盖结束/取消任务、空闲后台/锁屏/采集失效仍保留连接及明确断开。
- `ios-device.log`：iPhoneOS 27 无签名 build 成功，不等于已经安装到 iPhone。最后将场景、锁屏、停止和断开日志统一关联到独立 USB 连接标识后，`ios-diagnostics-regression.log` 的 3 项相关生命周期回归与 `ios-device-diagnostics.log` 的无签名构建再次通过；跨任务日志可以沿同一连接标识追踪。
- `build-ncm.log`、`build-hid.log`：两种 ESP32-S3 固件编译成功。`firmware-descriptors.log` 从 ELF 验证 NCM 端点 `0x81/0x82/0x02`，HID 增加 `0x83`，无 CDC；无 Wi-Fi/BLE 链接、DHCP 或网络转发。
- 初始 `firmware-tests.log` 的 localhost 监听受执行沙箱限制而失败；获准使用本机测试网络后 22 项通过，追加释放超时/流水线用例后最终 24 项通过。初始 iOS 161 项及随后 5 项 TCP 测试分别通过，最终完整 166 项通过。测试使用合成帧和本机协议对端，没有上传真实屏幕或调用模型。

工具链未安装或升级：Xcode 27.0 / 27A266a，iOS/Simulator 27.0 SDK，Swift 6.4（Swift 5 模式）；ESP-IDF 5.5.5 / `b774170ff46c393eeb5e495ea37936038d3f4f4f`，GCC 14.2.0 / esp-14.2.0_20260121，Python 3.12.13，esp_tinyusb 2.2.0，TinyUSB 0.21.0~2。工程签名配置、Info.plist 和依赖锁文件保留本轮开始状态。

## 已构建的升级候选

冻结目录：`.build/device-candidates/pa3-ncm-hid-persistent-20261004/`。这是从本轮真实 build 输出复制的三段镜像、ELF、构建配置、依赖锁文件与摘要清单；不是从设备读回的备份。`manifest.json` 记录源文件摘要和写入地址；其 `flashed: false` 保留准备时快照，实际烧录状态以本页下方执行目录的 `flash-review.json` 为准。

| 写入地址 | 文件 | 字节数 | SHA-256 |
| --- | --- | ---: | --- |
| `0x0` | `bootloader/bootloader.bin` | 20832 | `ed060c274ee6d9ee3f31dbc8bdd148491daee270b2535a438ea3983c2853354f` |
| `0x8000` | `partition_table/partition-table.bin` | 3072 | `7f00b6c042a89b15b0cac534f82ed988caf29278ff5700b0c511eb1b5bb7c820` |
| `0x10000` | `phoneagent_usb_device.bin` | 357376 | `9e7e68db1a3285052eb0a33cdbe30a94767b3e25df8b784c5d0852b8e1aeca72` |

另有 `.build/device-ncm/` 的 NCM-only 构建，app 354288 bytes，SHA-256 `87ad59d10e81c37aa2d4d9744d719493ea4f27c12e1f924666defd9152ac6aa5`。完整输入验证使用上述 HID 候选。

准备阶段未访问设备；后续已获本版明确授权并完成 PA3 固件烧录，尚未安装真机 App。须安装匹配的 PA3 App；旧 App/新固件或新 App/旧固件均不作为可运行组合。继续采用用户已确定的免 PSK、固定 IP；不改 NVS、PHY、eFuse、签名账户或系统 VPN。

本次已确认仅 COM 接 Mac、原生 USB 与 iPhone 断开，并取得本版烧录授权。使用此前可靠的 57600 baud、ROM 无 stub/无压缩方式，按约定没有重复备份可重新构建的旧固件。冻结的 IDF `flasher_args.json` 保留生成默认值，实际执行参数记录在下面执行清单。

## 实际烧录 · 2026-10-04 17:24 UTC

用户明确要求“接好线了，开始更新固件”，随后确认“是，只有 COM 接 Mac”。通过串口识别为此前同一 ESP32-S3、16 MB Flash；硬件身份仅在本地比较，不写入仓库文档。

- 17:22:41—17:24:03 UTC（2026-10-05 01:22:41—01:24:03 Asia/Shanghai），使用上述冻结三段镜像完成写入；esptool exit 0，三个 `Hash of data verified.` 全部通过，无传输重试。
- 写入扇区为 `[0x0,0x6000)`、`[0x8000,0x9000)`、`[0x10000,0x68000)`；未整片擦除，保留 NVS/PHY `[0x9000,0x10000)`，未写 eFuse、配置密钥或读回固件备份。
- 复位后 UART 115200 观察 15 秒，TinyUSB 启动，服务报告 `NCM + HID; 192.168.7.1:28766; PA3 persistent; no PSK/radio/DHCP/default route`。启动 ELF 摘要匹配冻结 ELF，服务行出现一次，未观察到 panic/abort/brownout。
- 监视器正常退出，确认 COM/TTY 无占用。工程签名与 Info.plist 和烧录前摘要一致；没有安装 App、连接 iPhone 或发送 HID 输入。

原始记录位于 Git 忽略的 `.build/device-flashes/pa3-hid-20261004-70wnxwe3/`：`flash-review.json` 状态为 `flashed_com_startup_verified`，保留候选副本、`identify.log`、`flash.log`、`runtime.log` 及执行脚本。没有将含设备标识的原始日志提交到 Git。本记录只证明 COM 烧录、摘要与短时启动检查通过，不证明 iPhone PA3 网络/HID/常连验收通过。

## 真机复测

1. 更新两端后启动采集，连接 USB NCM+HID；当前诊断应显示 `usb-diag-pa3-input-4`、`greeting.valid protocol=PA3 hid=true` 与双向 PING。iPhone 的“设置 → 辅助功能 → 触控 → 辅助触控”必须开启才能使用当前指针输入方案。
2. 连续开始/结束两轮任务，再取消一轮。期望 STOP 的 executed 后出现 `input.release.completed connectionRetained=true`，连接标识保持一致，命令 ID 继续递增；下一轮无需再点连接。
3. 可留在 PhoneAgent 或进入其他 App，验证一次点击与拖动，再在拖动中停止。确认鼠标/按键释放、没有迟到输入；任务取消不是设备断开。
4. 停止采集只撤销输入；重新授权采集后，若 TCP 健康可直接开始新任务。明确断开或拔线才应显示断开/失败。真实故障不自动重放。

上述真机测试尚未完整完成。2026-10-05 用户报告开启辅助触控后点击生效，提供的 PA3 日志也显示任务结束后 TCP 继续；这不替代拖动、停止/故障释放和完整后台 Agent 闭环验证。
