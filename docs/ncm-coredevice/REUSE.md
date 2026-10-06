# 实际复用对照与来源

读取日期：2026-10-04 UTC（本机日志时区日期为 2026-10-05）。下述是本地文件/固定源码的观察，不是本轮真机成功记录。完整 SHA 和相关文件摘要见 [SOURCES.json](SOURCES.json)。

| 来源 | 已读证据 / 实际状态 | 采用与未采用 |
|---|---|---|
| app-only 原生探针 | `CoreDeviceProbe.m` 的 Bonjour、只读 QueryType、RPPairing 问候；`RemoteXPCProbe.m` 有界 XPC/HTTP2；README/VALIDATION 与四份去标识化 JSON | 沿用阶段区分和问候 schema；实际 C XPC/RSD 复用本仓库的已测试实现，未拷贝私有 framework 或 VPN 代码 |
| app-only 真机日志摘要 | `validation/self-connection-2026-10-03.json`：身份已保存/读取，6 个地址 TCP 连接后被 `originating from local machine` 策略拒绝；Pair Verify 未到达；原生 XCTest 截图被 error 41 拒绝 | 明确普通 App 自连接不可当作捷径；测试 S3 外向来源。未读取身份文件、原始屏幕或原始系统日志；记录中的“配对成功”不作为控制成功 |
| app-only Device Hub 历史 | 固定源码 `1fcdfb0…` 曾构建/安装、监听就绪；没有成功控制本机。后来同机配对记录属于 StikPair 分支，不能归给原版 Device Hub | 只读源码和去标识化记录，不复用签名产物，不修改实验目录 |
| [device-hub-ios](https://github.com/JaviSoto/device-hub-ios/tree/1fcdfb0a6799b62f05625d0cbb359bec57256b94) | `Rust/DeviceHubFFI/src/protocol.rs`：Pair Verify → TCP listener → TLS-PSK → 协商 client/server IPv6、MTU、RSD port；`Docs/ProtocolSecurity.md`：v1 要求 Xcode 已准备 Personalized DDI；Swift Bonjour/endpoint 验证，Rust 承担重协议 | 模块分工/会话 generation 参考，并复用固定补丁版库及 PNG validator；不引入整个 UI、TCA、媒体解码或已编译 XCFramework。MIT，已读 LICENSE/THIRD_PARTY_NOTICES |
| [idevice](https://github.com/jkcoxson/idevice/tree/a64b8867815b3da17b5c927531bdba877e8456ef) | 实际读取 Device Hub 固定 vendor 的 `remote_pairing/socket.rs`、`rp_pairing_file.rs` 及上层调用；host/device role、序号、身份字段、TCP tunnel 等 | MIT；第二轮已将 Device Hub vendor 的 Rust 库及 PNG validator 纳入 `ncm-dev/rust`，用于 PhoneAgent 侧；不把 runtime 移到 S3。vendor 含 Device Hub 的补丁，不能把其安全行为泛化为所有 idevice 版本 |
| [idevice_pair](https://github.com/jkcoxson/idevice_pair/tree/6deb85f33c3f16c8f5d505387e1b2653a10eb8b9) | `src/backend/wireless.rs` 的 PairableHost 反向初配及 TCP tunnel；`pairing.rs` 明确区分 Lockdown/Remote payload；默认身份生成与保存 | 只作参考。此次 checkout 根目录和 Cargo.toml 未找到明确项目许可证声明；不能因为依赖 idevice 是 MIT 就声称项目也是 MIT。未复制或执行该项目 |
| [pymobiledevice3](https://github.com/doronz88/pymobiledevice3/tree/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1) | 本地 clean checkout；`tunnel_service.py` RPPairing、TCP；`screen_capture_service.py` CoreDevice PNG；`hid_service.py` touch_session 必须开启 DisplayService、drain RTP | GPL-3.0-or-later，沿用本仓库 schema 转译及对应许可；未调用完整工具、服务或手机操作。既有测试只运行固定且哈希校验的纯编码参考文件 |
| [rPlayHub](https://github.com/rPlayAI/rPlayHub/tree/fe6a7a9f1cff431acfda142cd3564fc8e0e849a3) | `core/rp_remotexpc.c`、`rp_coredevice.c` 的 C transport/请求；`host-c/ddi.c` 仍依赖 libplist/OpenSSL/TSS；`doc/DDI.md` 是项目自己的 DDI 流程说明 | GPL-3.0 LICENSE 已读；本轮不复制核心，避免重复本仓库 C 实现；它的桌面平台成功不证明 ESP32/iPhone NCM 成功。没有下载 DDI 或执行 fetch/build 脚本 |
| with-esp 基线 | `USBCommandClient.swift` 的具体接口选择；`firmware-device/main/usb_network.c` 的本地子网；`bridge_core` 的 QueryType/RSD/XPC/PNG | 适配接口选择、NCM 网络，增加 IPv6/诊断并分离新工程；旧文件保持原样。新目标不使用 USB HID/SCK/usbmux |

[Apple 的 Device Hub 配对文档](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub) 描述同 Wi-Fi 的无线配对以及接线配对，未给出此 iPhone-host/S3-device NCM 拓扑的准入保证。客户端接受普通 IP 不是服务端支持所有接口的证明。

Network.framework 的 [requiredInterface](https://developer.apple.com/documentation/network/nwparameters/requiredinterface) 和 [requiredLocalEndpoint](https://developer.apple.com/documentation/network/nwparameters/requiredlocalendpoint) 用来明确出口和源地址。本项目沿用 `IPv4Address("address%interface")` 取得具体 `NWInterface` 的兼容处理；未找到 Apple 对 IPv4 的该写法的明确保证。必须校验返回的名称/索引/类型，否则失败；不固定 en3，不用默认网关，不回退 Wi-Fi、蜂窝或 VPN。

新 C/Swift 文件按本仓库 GPL-3.0-or-later 标注，组合仓库许可继续是根目录说明的 GPL-3.0-only。没有将第三方许可改成 MIT。Espressif ESP-IDF、esp_tinyusb/TinyUSB、lwIP 和 cJSON 的独立许可仍适用；既有 [THIRD_PARTY.md](../../THIRD_PARTY.md) 和 [TinyUSB notices](../../firmware-device/licenses/) 保留。cJSON 从已安装 ESP-IDF 源码构建（MIT），本次不另行 vendoring。新二进制若分发，应随完整源码和所有依赖 notices 一起提供。

第二轮复用的精确 manifest、MIT notices、离线构建和能力边界见 [BACKEND.md](BACKEND.md)。最初仅接口的交付不再代表 Rust 层的当前实现状态；诊断 App/固件仍不具备认证控制能力。
