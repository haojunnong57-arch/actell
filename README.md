# iOS Use · PhoneAgent + ESP32 USB Device

当前主路径：iOS 27 主 App 默认经 VPN 回环调用 CoreDevice 服务获取截图并执行点击/拖动，也支持 ESP32 NCM 路线。入口为“设置 → 手机操控 → 连接模式 / 连接与验证”；首页和消息页不再显示设备入口，设置内的控制入口保留。原 ScreenCaptureKit/PA3 USB HID 与 TLS 链路保留，由 `DeviceControlRoute` 预留切换，暂不添加开关。各会话可并行执行，离开页面不停止；NCM 后台任务复用系统调度，无需启动录屏。同一手机的控制任务按整轮排队。系统资格到期、锁屏或连接故障仍会停止任务。模型服务商在“设置 → 服务商”管理。会话支持选择 OpenAI Chat Completions 兼容服务商与模型。

VPN 回环为连接模式首项及未保存偏好时的默认值，已有显式选择保留。需先开启支持本机数据包回注的外部 VPN（已使用 LocalDevVPN 验证）；App 不安装或管理 VPN。控制页可编辑接口与对端 IPv4 地址，默认 `10.7.1.1` / `10.7.0.1`，保存后重新连接生效。两条路线共用配对身份，切换会释放旧会话与动作授权；新配对授权名称为「执言」。真机已验证截图、实际点击和媒体释放，详情与边界见 [VPN 回环模式](docs/ncm-coredevice/LOCALDEVVPN.md)。

后台媒体模式在“设置 → 后台执行 → 执行模式”选择音频或画中画，默认音频，选择从下一轮任务生效。画中画继续播放状态样本帧，仅任务执行且进入后台时展示；音频模式在任务开始时播放一秒静音 PCM 的循环，为切后台做准备，不创建画中画窗口。这两个模式默认不申请 BGContinuedProcessingTask 或 UIApplication 后台任务，任务进度由自定义 Live Activity 展示。切后台时最多等待五秒媒体实际启动，等待期间不发送设备操作，超时暂停；任务停止、锁屏或音频中断会释放相应媒体来源，不自动重启或重放任务。该机制不能承诺系统永不挂起/终止 App。当前新增音频实现只做本地模拟器与构建验证，尚未真机验证。

NCM 视频继续使用系统 VideoToolbox 解码和默认 Core Image JPEG 转换。2026-10-07 的隔离对照确认：切后台可能使原解码会话失效，但在后台重新创建的硬件会话可正常解码，故已移除实验性的 libde265 依赖和强制软件渲染。视频反馈使用认证协商返回的动态端口。进一步真机对照查明：静止屏幕会停止产帧，PLI/FIR 不强制重新采集；截图已改用请求后的发送端进度报告确认完整画面，移除一秒年龄限制。原 RCTL 固定尾值被 iOS 解释为 60001 kbps，导致 S3 链路发送端缓冲不足、序号缺口；现将 S3 协商上限和接收带宽声明统一为 2000 kbps。修复后连续 7 次截图通过（含后台静止计算器和切换设置），2764 个视频包无序号缺口，输出均为 1179 × 2556。详见 [根因与对照证据](docs/ncm-coredevice/VIDEO-GEOMETRY.md#refresh-and-sequence-gap-root-causes-2026-10-07)。

NCM 默认截图继续复用视频帧并编码 JPEG，不调用独立 PNG 截图服务、不关联输入历史。接收端保留关键帧及其后续 P 帧，队列限制 64 帧 / 8 MiB，新关键帧可替换旧积压；溢出或断流时丢弃引用链并请求关键帧。App 在工作队列持续解码，截图只在内部取最新完整画面、按需编码 JPEG，停止控制会话时取消接收任务并释放解码器。视频协商现开启 SW:1，优先解析流内有效画面区域（已捕获 flag-2 内容矩形），并保留按 displayId 查询对端 DeviceInfoService 的后备路径；每帧校验显示范围与 SPS 画布匹配后，裁去右/底部填充再编码 JPEG，不缩放。不使用本机屏幕尺寸、机型表或按颜色猜边。旧固定 14 字节帧尾假设不适用；现按 RBSP 解析已观察的 flag-2/flag-3 格式，处理跨片段数据的转义边界。几何日志只在尺寸变化时记录数值。保存相册使用返回的原始图片；截图失败保留认证隧道，不自动重放输入。原 CoreDevice PNG 截图 API 保留但不自动回退。ESP32 仍只转发数据。最后一个操控任务结束后释放本 App 的视频/HID 服务；其他操控任务运行或排队时不提前释放，切后台不关闭。退出通知关闭本 App 连接。系统取消配对不会自动删除本地身份，可显式重新配对。2026-10-07 已在真实 ESP32 链路多轮连续截图成功，修改前尺寸为 1184 × 2576，SPS 无裁剪窗；设备信息服务主屏为 1179 × 2556，现已接入逐帧裁剪，真机连续三张输出 1179 × 2556；底部填充移除，原始码流已有的最右侧一列暗像素保留。详见 [视频几何诊断](docs/ncm-coredevice/VIDEO-GEOMETRY.md)。


- [本次待办评估、实现与验证](docs/PROJECT-TODOS.md)
- [后台 CPU 终止与工具回执恢复诊断](docs/BACKGROUND-RUN-RECOVERY.md)
- [屏幕流停止与任务完成提醒](docs/CONTROL-SESSION-TEARDOWN.md)
- [iOS 构建与测试](ios-app/README.md)
- [NCM 开发者服务与主工程整合](docs/ncm-coredevice/MAIN-INTEGRATION.md) · [NCM 路线](docs/ncm-coredevice/README.md)
- [PA3 协议](docs/usb-device/PROTOCOL.md) · [常连基线记录](docs/usb-device/PERSISTENT-USB.md)
- [板级硬件资料](docs/hardware/ESP32-S3-USB.md)
- [历史文档与非核心测试归档](archives/README.md) · [第三方来源](THIRD_PARTY.md)

`ios-app/` 是 App；`firmware-device/` 是当前 NCM/HID 固件；`tests/usb_device/` 为生产 C 代码的本机协议夹具。旧 Host `firmware/`、测试和来源清单保留，默认工作不需要阅读它们。`ncm-dev/` 提供共用 Swift/C/Rust 协议库和 Probe，主 App 与生产固件已复用；`app-only` 仅为外部参考。

用户已验证 ESP32 NCM 截图与中央触摸计数增加；主任务的 NCM 真机闭环及拖动效果仍待验收。旧 PA3 链路也已有 USB PING、本机截图和 HID 输入记录。不同链路的历史证据不能互相替代；最新范围见各整合和验证记录。
