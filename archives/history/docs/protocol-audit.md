> 当前源码状态见 [v0.3 验证](validation.md)。本文早期阶段的未实现列表是历史记录；后续实现不等于硬件验收。

# 截图 + 输入协议审计

## 证据范围

源代码固定于 pymobiledevice3 `cd895d17ce8a97d883c10f87b26c7356d5e0ccb1`
（提交时间 2026-09-30）。本报告直接检查了该 Git checkout；没有连接实体 iPhone。
后续读取用户提供的 [Mac 基线](https://chatgpt.com/space/page_6abf8257931881918f961de7bba04aeb)：
iPhone 15 Pro / iOS 27.0 24A437，Xcode 27 正式版 27A266a / DDI CoreDevice 642.16，
USB userspace RSD；截图/触控/Home 成功，键盘字符不准确，无 WDA。
现已选定 CoreDevice 协议子集；旧路径仅保留为比较背景，不作为实现分支。
本地成功 checkout 是否额外修改仍未确认。

## 三种截图协议不能混为一谈

1. [screenshotr](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/services/screenshot.py)
   使用 com.apple.mobile.screenshotr，DeviceLink/plist 握手，返回 PNG 或 TIFF
2. [DVT screenshot](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/services/dvt/instruments/screenshot.py)
   使用 DTX 的 com.apple.instruments.server.services.screenshot 通道和 takeScreenshot selector
3. [CoreDevice screenshot](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/core_device/screen_capture_service.py)
   使用 com.apple.coredevice.screencaptureservice；feature.capturescreenshot / action.capturescreenshot；
   当前代码说明请求格式为 PNG；响应是带 image 数据的 typed XPC 字典

WDA/XCTest 如果出现在用户已验证脚本中，需要另做分析，不能把它包装成同一种协议。

## CoreDevice 可能的最小链路（有条件）

USB 主机 → Apple USB multiplexing → lockdownd 信任/会话 → CoreDeviceProxy →
CDTunnel 中的 IPv6 → 嵌入式 TCP/UDP → RSD → RemoteXPC → screenshot/display/HID。

[iOS 17.4+ 的 CoreDeviceProxy](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/tunnel_service.py#L1364-L1404)
通过已受信任的 lockdown 服务，避免独立 RemotePairing 的 SRP/PSK/QUIC 路径。
这不等于可以跳过正常配对和所需 TLS。

[版本/路由选择](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/userspace_tunnel.py#L710-L758)
将此方式限定为 17.4+，更早版本或 Wi-Fi 路径涉及 RemotePairing。
macOS 原生隧道依赖苹果桌面守护进程，不能搬到 ESP32。
代码包含 iOS 18.2+ 移除 QUIC 支持的分支；不能盲目选 QUIC。

## 输入服务不是普通 BLE/USB HID

[UniversalHID 与认证门槛](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/core_device/hid_service.py#L38-L123)：

- 真正触摸屏报告为 58 字节，report ID 0x09，服务 ID 常见为 257
- X/Y 为 0–65535 的归一化值；截图像素必须转换
- Contact 为 0xC2，Release 为 0x02；拖动是连续 contact 后 release
- 19 字节 pointer 报告只对应指针，不能当作触屏已成功
- 键盘需先注册虚拟 service，然后发送 39 字节全状态位图
- 没有活跃媒体流时，系统会静默丢弃触摸/键盘事件

[touch_session](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/core_device/hid_service.py#L546-L632)
绑定可达 UDP 端点、启动 DisplayService 媒体流、等待认证、持续读取并丢弃 RTP，再发送输入。
因此“只要截图不要视频”可以去掉 HEVC 解码器，却不能假定媒体协商/收包也可删除。

[DisplayService](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/core_device/display_service.py)
使用 action.mediastreamstart、会话 UUID、IPv6 地址/端口和协商 offer。
[offer](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/core_device/media_stream_offer.py)
涉及 binary plist、protobuf 与压缩 protobuf；可选择性实现，没必要搬整个 Python 生态。
源码警告在同一 display 连接发第二个要求回复的请求可能让设备守护进程崩溃；
停止媒体流应使用新连接，异常路径也必须收尾。

普通 BLE/USB 键鼠可以成为独立的输入产品，但不能替代该开发者协议链，也不提供系统截图。

## USB 关键缺口

[pymobiledevice3/usbmux.py](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/usbmux.py#L154-L200)
连接的是 Unix/TCP usbmuxd socket，不是 ESP-IDF USB endpoint。
必须另行移植/实现 [usbmuxd 的 USB transport](https://github.com/libimobiledevice/usbmuxd/blob/master/src/usb.c)
和 [连接复用状态机](https://github.com/libimobiledevice/usbmuxd/blob/master/src/device.c)。
不能将 libusbmuxd 客户端当作已完成 USB Host。

[lockdown](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/lockdown.py)
还需要正常信任、HostID/SystemBUID、StartSession、按响应升级 TLS、StartService、
必要时服务 TLS。配对记录是凭证，不能写入日志/测试样例/共享归档。

## RemoteXPC 关键要求

[RSD](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/remote_service_discovery.py#L472-L543)
动态发布服务端口和功能，不能硬编码端口。
[RemoteXPC](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/remotexpc.py#L396-L439)
需要特定 HTTP/2 初始化顺序、stream 1/3、窗口更新/流结束处理。
[XPC 编码](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/xpc_message.py#L34-L141)
需要区分 Int64/UInt64、字节对齐、字典/数组/UUID/data，不是 JSON HTTP API。

## DDI 与可用性

开发者模式、DDI 挂载、具体服务是否存在都是独立门槛。
源码将 DDI 大致分为旧版、iOS 17+ PersonalizedDMG 和更高版本的新分支；
实际应按用户当前系统版本和已验证链路决定。
不能由“CoreDevice 是 iOS 17+”推导所有 HID/媒体特性在每一版 17+ 上都可用。

## 可行性判断

没有证据证明 N16R8 因内存容量必然做不到；也没有证据证明已能独立跑通。
当前高风险是 USB Full Speed 兼容/吞吐、嵌入式复用/TLS/隧道集成、
强制媒体流以及开发服务版本差异。需要按阶段在实体设备上验证。
如果这条链路的常驻视频流超过 S3 可用 USB 带宽，调低协商码率/尺寸是否受支持必须实测；
若设备不支持，再考虑具备高速 USB 与更完整网络栈的控制器或小型 Linux 板。
这些是失败后可讨论的替代方案，没有自动切换硬件或执行环境。

## 本次已实现到哪一层

`bridge_xpc.c` 是 typed wire codec，不是已连接的 RemoteXPC 客户端。
`bridge_requests.c` 编码已选中的截图、触控/Home、媒体 start/指定 ID stop 请求，
`bridge_media_offer.c` 生成动态 offer，`bridge_screenshot_stream.c` 流式取出图片字段。
它们都不能代替 USB、TLS、隧道、RSD、HTTP/2 分流和真正的服务生命周期。

媒体 offer 使用上游兼容身份 Mac15,9 / 2205.3.1 / 25F80；它不是 ESP32 的实际设备描述。
源码特别注明 zlib level 6 曾被设备拒绝，因此本次要求真正的 level 9 回调，未用
“格式上看似合法”的无压缩替代包冒充兼容实现。固件中该压缩库尚待集成。

请求中的 CoreDevice 客户端版本按固定源码保留 629.3，与手机 DDI 的 642.16 是不同字段。
没有把服务可用性、输出字节一致或 Mac 成功误写成 ESP32 实机成功。


## v0.2 后续实现状态

原先 USB mux 空缺已补入原始线协议状态机和 ESP-IDF Host 适配代码，
并接上只读 QueryType。详见 usb-transport.md。尚未实机运行，也没有完成
合法配对/TLS、CDTunnel/RSD/HTTP2，因此原来的完整能力门槛仍有效。


## v0.3 implementation update (2026-10-02)

The earlier unimplemented transport list is historical. StartSession/pinned TLS,
CoreDeviceProxy/CDTunnel, a real lwIP IPv6 TCP/UDP adapter, RemoteXPC HTTP2, RSD
and bounded zlib9 are now implemented and covered by the respective test suites.
See validation.md and network-operations.md for exact evidence and remaining gaps.
No physical iPhone session has been performed. Initial trust provisioning,
media-token-specific cleanup, automatic touch orchestration, and App transport
remain unavailable; low-level report serialization is not proof of input effect.
