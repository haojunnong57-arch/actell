# iOS Use · PhoneAgent + ESP32 USB Device

当前主路径：iOS 27 ScreenCaptureKit 在本机采集，PA3 USB NCM 连接 ESP32-S3，HID 执行点击/拖动。USB 连接跨任务复用；STOP 撤销当前输入代号并释放 HID，不关闭健康连接。会话使用可选择的 OpenAI Chat Completions 兼容服务商与模型。

- [本次待办评估、实现与验证](docs/PROJECT-TODOS.md)
- [iOS 构建与测试](ios-app/README.md)
- [PA3 协议](docs/usb-device/PROTOCOL.md) · [常连基线记录](docs/usb-device/PERSISTENT-USB.md)
- [板级硬件资料](docs/hardware/ESP32-S3-USB.md)
- [历史文档与非核心测试归档](archives/README.md) · [第三方来源](THIRD_PARTY.md)

`ios-app/` 是 App；`firmware-device/` 是当前 NCM/HID 固件；`tests/usb_device/` 为生产 C 代码的本机协议夹具。旧 Host `firmware/`、测试和来源清单保留，默认工作不需要阅读它们。`app-only` 与并行 CoreDevice 实验不属于本分支。

用户已报告 USB 双向 PING、本机截图及启用 AssistiveTouch 后点击可用；跨 App 持续闭环仍未全面验收。本分支只做本地构建与合成测试，没有推送、合主线、烧录或真实设备输入。
