# 方案、实现状态与下一步

记录日期：2026-10-03。本文区分归档交付时的证据、本次 Mac 检查与尚未完成的工作。原始源码文档保留其 2026-10-02 交付时间语境，本文及 [LOCAL-VALIDATION.md](LOCAL-VALIDATION.md) 补充本次结果。

## 两条链路

1. **控制目标 iPhone 的固件链路：**ESP32-S3 USB Host → raw USBmux → lockdown / 既有配对身份 TLS → CoreDeviceProxy → CDTunnel / IPv6 / lwIP → RSD / RemoteXPC → 截图、Home 等服务。代码路径存在，尚未在真实 iPhone 上形成可验收闭环。
2. **App 与固件的配套链路：**iOS App 的 `NWListener` 拟监听 TCP 28765，ESP32 经 usbmux 建立另一条逻辑流，使用独立 TLS-PSK 及有界消息协议。它不是普通 USB 以太网。iOS 有候选实现，固件 v0.3 没有该 App 通道，也不能宣布 backend ready。

App 的工具子集为 screenshot / tap / drag，wait / finish 为本地动作；该版 App 不提供 Home 或文字输入工具。固件中的 Home 请求路径不表示 App 已支持 Home。

## 必须保留的边界

- 首次信任、配对、身份安全配置及恢复流程未实现；已有身份下的 TLS 测试不能替代首次配对验收。
- 触控依赖活动显示媒体流。只构造 HID 报告不足以重现触控；本次流的安全停止令牌、自动启停与完整清理尚未就绪。
- 板型、USB 接线、VBUS 供电、实际吞吐及内部 SRAM / PSRAM / 任务栈峰值未实测。云端镜像大小不是硬件内存水位。
- iOS 离开前台会停止任务和连接。同机打开另一 App 可能终止控制过程；当前没有跨 App 后台持续执行能力。
- iOS 的演示模式使用合成画面；协议 fixture、模拟 USB 对端和语法解析都不证明真实桥接成功。
- App 已完成 SPM 解析和无签名 Simulator `build-for-testing`；18 项 XCTest 已编译但未执行。模型 API、界面启动及真机运行仍待完成，详见[最新编译验证](../ios-app/docs/IOS-BUILD-FIX.md)。
- 两份工程尚未联调。App PSK 与 Apple 配对身份是不同材料，不能复用；本次没有生成或读取这些材料。

## 历史证据

[Mac 基线页面](https://chatgpt.com/space/page_6abf8257931881918f961de7bba04aeb) 的 2026-10-02 记录：iPhone 15 Pro、iOS 27.0 / 24A437、Xcode 27 正式版 27A266a DDI / CoreDevice 642.16，USB 进程内 userspace RSD，无 WDA。截图、直接触控和 Home 成功；`Test123` 输入显示为 `tEST! @#`，字符正确性未解决。此记录是 Mac 链路证据，不是 ESP32 成功记录，也不是本次重测。

固件 v0.3 的原始[验证说明](validation.md)、[云端测试输出](test-results.txt)和[交叉编译输出](build-results.txt)保留在这里。iOS 原始[验证说明](../ios-app/docs/VERIFICATION.md)同样保持未改动。本次新的 Mac 结果独立记录在 [LOCAL-VALIDATION.md](LOCAL-VALIDATION.md)。

## 后续验收顺序

先准备可重复的本地构建与测试环境，再按真实 USB 连接 → 信任/身份配置 → RSD 服务发现 → 一张完整 PNG → 已有合适 DDI 的测试设备上可逆输入的顺序验收。之后补齐固件 App 通道并验证认证、截图事务、输入确认和停止/断线清理。同时实测内存与栈水位，单独定位字符输入问题。

以上是后续工作说明；本次整理没有执行设备操作、安装依赖或联网调用模型。
