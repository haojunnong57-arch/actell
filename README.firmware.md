# ESP32-S3 iPhone bridge v0.3：认证、隧道与网络检查点

**源码实现检查点，整体仍未实机连通。** 可交叉编译的 ESP-IDF 工程已包含真实 USB
Host/mux、已有配对身份的 TLS 会话、CDTunnel、lwIP、RSD 和 RemoteXPC 组件。
真实 iPhone 截图、Home、触控与 App 通道尚未通过硬件验收；默认程序不会尝试配对或控制手机。

开发环境是 dot 自带云端。未改动原 iPhoneMirrorMCP，未操作用户电脑，未读取真实配对凭证。
正在另行开发的 iOS App 不包含在这份固件检查点内。

## 已固定的基线

[用户提供的 Mac 基线](https://chatgpt.com/space/page_6abf8257931881918f961de7bba04aeb)：
iPhone 15 Pro，iOS 27.0 / 24A437；Xcode 27 正式版 27A266a 的 DDI / CoreDevice 642.16；
USB + 进程内 userspace RSD，无 WDA。该环境截图、tap、Home 成功，键盘字符不准确。
这些结果不能推广为 ESP32 已经成功。

## v0.3 新增的实际代码

1. 有界 lockdown StartSession → 设备证书固定校验 TLS → CoreDeviceProxy StartService → StopSession
2. 实际 mbedTLS 1.2 客户端，HostCertificate/HostPrivateKey 与 DeviceCertificate pin；没有 CERT_NONE 回退
3. CDTunnel JSON 握手与原始 IPv6 包边界；协商 MTU 1280～16000
4. ESP-IDF 自带 lwIP 的真实 IPv6 TCP/UDP 栈适配，四路 TCP、固定环形队列、ACK drain、异步安全清理
5. HTTP/2 RemoteXPC 会话与流控，1 KiB 分块，消息 ID 匹配；9,480,493 字节有效合成 PNG 流式测试
6. RSD 现代握手、四类服务发现和能力检查；发现连接保持打开
7. screenshot 和 Home 的服务调用路径；PNG 结果完整后提交，Home 区分写入、对端 TCP ACK 与真实 UI 效果
8. 实际 zlib 1.3.2 level-9 压缩，单次 384 KiB 分配上限，ESP32 默认仅从 PSRAM 分配
9. USB/TLS/CDTunnel 组合适配，以及 lwIP/RSD 组合适配；失败不返回假成功

v0.2 的 raw USBmux、实际 ESP-IDF bulk Host、ZLP、描述符选择、QueryType 和生命周期测试保留。
既有 HID、媒体 offer、typed XPC 和 PNG 编解码测试均纳入回归。

## 运行和验证边界

- 首次信任/配对、真实身份安全配置与保存尚未实现；本版本仅接受调用者已有且获授权的身份
- 真实 USB/VBUS、iPhone TLS 证书呈现/密码套件兼容性、端到端吞吐和内部 SRAM/PSRAM 水位未测
- 没有把各层测试说成一台真实手机上的全链路验证，也没有一个同时覆盖所有物理与密码层的硬件测试
- 触控仍需活动媒体流；安全的“只停止本次流”token 获取规则尚未核实，自动媒体启停/触控保持未就绪
- 上游使用 stopAll，且同一 display 连接第二次带回复请求可能使设备显示服务崩溃；这里不自动照搬 stopAll
- 键盘文本未修复；没有把原始键盘报告等价于正确打字
- lwIP 点对点 profile 拒绝 IPv6 分片和 ND6 路由控制包，UDP 单包不超过 min(2048, MTU−48)
- App TCP28765 通道及其认证/消息协议仍是未来接口，不在本固件实现中

详细接口和证据：
[USB](docs/usb-transport.md)、[TLS 测试与策略](tests/test_tls_README.md)、
[CDTunnel](docs/cdtunnel-transport.md)、[lwIP](docs/lwip-tunnel.md)、
[RemoteXPC](docs/remotexpc-session.md)、[RSD](docs/rsd-discovery.md)、
[组合与操作](docs/network-operations.md)、[zlib](docs/zlib-compressor.md)。

## 复现测试

需要 GCC、ASan/UBSan、CMake、系统 zlib 开发库、Python 3，及完整官方 ESP-IDF v5.5.5
（含其 mbedTLS/lwIP 源码）。Python 需要 construct 2.10.70 和 hyperframe 6.1.0。
公开上游测试证书只从 IDF 的测试目录读取，未写入固件或本归档。测试连接仅使用本机模拟对端。

```sh
python3 -m venv .venv
.venv/bin/pip install construct==2.10.70 hyperframe==6.1.0
. /path/to/esp-idf/export.sh
PYTHON="$PWD/.venv/bin/python" ./tools/test_all.sh
# 可选：真实 lwIP 的并发检测（宿主机测试端口 shim；不是 ESP32 运行时）
SANITIZE=thread ./tools/test_lwip.sh
```

完整输出见 [test-results.txt](docs/test-results.txt)，各套件边界见 [validation.md](docs/validation.md)。
LSan 在当前执行器 ptrace 下不可用；ASan/UBSan 与显式分配计数/池恢复检查另行通过。

## 编译与默认程序

```sh
. /path/to/esp-idf/export.sh
./tools/build_firmware.sh
# 仅用于覆盖 USB 启用分支的编译配置，不是硬件配置建议
./tools/build_usb_compile_only.sh
```

默认程序只检查 Flash/PSRAM、序列化合成请求与 zlib9 offer，并测试缺少配置时拒绝运行。
这些调用使真实组件完成链接，不会生成/导入身份、初始化网络接口或执行输入。
USB 探测默认关闭；即使启用，默认也仅运行 QueryType。
本包不含可直接刷入的二进制，源代码仍需按实际开发板配置。

候选配置为 WROOM-1-N16R8：16 MB Quad/DIO Flash、8 MB Octal PSRAM 80 MHz。
WROOM-2、N16R8V 等不同 Flash/电压变体不能直接套用。板型、VBUS、USB-C CC 和端口接线须先确认。
不会烧写 eFuse。编译大小和资源边界见 [验证](docs/validation.md)与[内存预算](docs/memory-budget.md)。

## 许可证与隐私

组合发布使用 GPL-3.0-only；单个文件保留各自许可，zlib 保留原许可，见 [THIRD_PARTY.md](THIRD_PARTY.md)。
仅使用正常系统信任/开发者流程控制自己或获授权设备。不要把配对记录、私钥、令牌、设备唯一标识
或个人截图加入聊天、日志或源码归档。固定 UUID/地址和图像 fixture 都是明确的测试数据。
