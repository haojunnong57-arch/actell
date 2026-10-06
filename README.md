# iOS Use · PhoneAgent + ESP32 USB Device

当前主路径：iOS 27 主 App 经已配对的 ESP32 NCM 开发者服务获取截图并执行点击/拖动。入口为“设置 → USB 连接 → ESP32 控制”；导航栏设备按钮使用同一控制页面。原 ScreenCaptureKit/PA3 USB HID 与 TLS 链路保留，由 `DeviceControlRoute` 预留切换，暂不添加开关。当前 NCM 控制需保持主 App 前台。会话支持选择 OpenAI Chat Completions 兼容服务商与模型。

- [本次待办评估、实现与验证](docs/PROJECT-TODOS.md)
- [iOS 构建与测试](ios-app/README.md)
- [NCM 开发者服务与主工程整合](docs/ncm-coredevice/MAIN-INTEGRATION.md) · [NCM 路线](docs/ncm-coredevice/README.md)
- [PA3 协议](docs/usb-device/PROTOCOL.md) · [常连基线记录](docs/usb-device/PERSISTENT-USB.md)
- [板级硬件资料](docs/hardware/ESP32-S3-USB.md)
- [历史文档与非核心测试归档](archives/README.md) · [第三方来源](THIRD_PARTY.md)

`ios-app/` 是 App；`firmware-device/` 是当前 NCM/HID 固件；`tests/usb_device/` 为生产 C 代码的本机协议夹具。旧 Host `firmware/`、测试和来源清单保留，默认工作不需要阅读它们。`ncm-dev/` 提供共用 Swift/C/Rust 协议库和 Probe，主 App 与生产固件已复用；`app-only` 仅为外部参考。

用户已验证 ESP32 NCM 截图与中央触摸计数增加；主任务的 NCM 真机闭环及拖动效果仍待验收。旧 PA3 链路也已有 USB PING、本机截图和 HID 输入记录。不同链路的历史证据不能互相替代；最新范围见各整合和验证记录。
