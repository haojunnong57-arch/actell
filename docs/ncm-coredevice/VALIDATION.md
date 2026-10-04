# 本 worktree 的验证与未验证项

验证日期：2026-10-04 UTC（本机 Xcode 日志显示 2026-10-05 凌晨）。基线 `80b1c8f99c2e6d35e52bbb37967aa8b0a4b6c7e3`，branch `feature/ncm-coredevice`。

**未连接或操作实体设备。服务准入、真实截图、真实输入均没有本轮成功证据。** 下面的 TCP 对端仅为 `127.0.0.1` 上的合成程序；RSD/PNG 也只用合成 fixture。

| 层 / 命令 | 本次实际结果 | 不能推出的结论 |
|---|---|---|
| `build_ncm_developer.sh` | ESP-IDF v5.5.5 / ESP32-S3 构建成功；`CONFIG_TINYUSB_NET_MODE_NCM=y`、`HID_COUNT=0`、IPv6 开启、IPv4/IPv6 forwarding 关闭 | 未刷写，不证明枚举、IPv6、真实 socket 或内存峰值 |
| `build_ncm_probe_app.sh device` | Xcode 27 / iOS 27 SDK，arm64 Device **BUILD SUCCEEDED**，`CODE_SIGNING_ALLOWED=NO` | 未签名/装机，不证明手机网络权限、接口绑定、后台行为 |
| `build_ncm_probe_app.sh simulator` | Simulator **BUILD SUCCEEDED**，无签名 | 未启动 UI / Preview；不是页面视觉验收 |
| `test_ncm_swift.sh` | 9/9 XCTest 通过；接口拒绝歧义/Wi-Fi/VPN；回复边界、禁止能力提升；真实 Network.framework loopback 分片、错误响应、超时重用、取消和 busy | 没有接触 `.1/.2`，IPv4 `%scope` 在 iPhone 的适用性尚待复验 |
| `test_ncm_developer.sh` | C ASan/UBSan 通过：DNS 分包/IPv4/IPv6/off-link/所有截断位置/循环压缩/TC/TTL/goodbye/TXT 不保留；问候分片/所有 EOF 位置/深度/重复字段/角色/封装/超时/清空；失效候选和身份类型/认证/DDI 门控 | 不是 mDNS 在 NCM 上的线上测试，不是密码学认证证明 |
| 同一 C suite 的 TCP loopback | 使用实际 POSIX socket、明确源接口/源地址：成功问候、TCP 后 EOF、绝对超时、拒绝错误目标均通过 | 不代表 iPhone 对 `.1` 来源放行 |
| `test_lockdown_probe.sh` | 45 XML/bplist fixture、50,000 变异/随机输入、分片与期限、独立 plistlib 请求解码均通过 | 没有真实 Lockdown QueryType、Trust/session |
| `test_rsd.sh` | 固定上游 handshake AST oracle 与 C RSD ASan/UBSan 通过：root/reply stream、动态端口/feature、控制连接、失败清理 | 所有对端都是 mock，认证/tunnel 前置未提供 |
| `test_operations.sh` | 既有真实 C request/HTTP2/XPC/PNG 实现，在合成 RSD/ACK 边界下通过截图事务、reply stream 1/3、错误/释放/临时输出测试 | 合成 PNG 不是手机截图；Home ACK fixture 不代表输入生效，未启用触控媒体会话 |
| `clang --analyze` | 新增 `ncm-dev/core/*.c` 静态分析退出 0，无诊断 | 不能替代硬件、并发/内存水位实测 |
| 项目完整性 | `bash -n`、`git diff --check` 通过；确定性 Xcode 工程生成可复核 | 不验证未运行的产品流程 |

初次 ESP-IDF 在沙箱内遇到进程信息读取限制；Swift macro 编译及 loopback bind 也被沙箱限制。随后在构建/本地测试所需权限下重跑并通过。没有靠关闭协议检查让测试通过。C socket 测试曾发现合成 JSON 多一个右括号，修正了测试 fixture；生产解析器正确拒绝该格式，未放宽。

既有 RSD oracle 需要 construct/hyperframe。默认 Python 缺失；改用本机已经安装依赖的 `/usr/bin/python3` 后通过，没有安装新解释器/依赖或运行完整 pymobiledevice3 CLI。

## 当前产物

产物均在忽略目录 `.build/`，没有提交二进制、屏幕、凭据或原始诊断日志。

- S3 app image：`.build/ncm-developer/phoneagent_ncm_developer.bin`
  - 大小 **383648 bytes**（`0x5daa0`），1 MiB app 分区剩余约 63%。大小不代表运行时 SRAM/PSRAM 或吞吐裕量。
  - SHA-256：`ecf1cdd20805e510136b012ec514ec12c41ff23635508f8398ed3e9d6eb57afe`
  - Bootloader / partition table 也已构建；没有执行 flash。未启用 PSRAM，诊断任务栈预留 32 KiB，峰值未实测。
- iOS Device：`.build/ncm-probe-app/Build/Products/Debug-iphoneos/NCMProbe.app`
  - 无签名 executable SHA-256：`7f7dc1ac710133b9208577cf89108243fd81ac71481529c225d79465eaffd5e4`
- Simulator：`.build/ncm-probe-app/Build/Products/Debug-iphonesimulator/NCMProbe.app`
- Swift library 源码：`ncm-dev/PhoneAgentNCM/`，可直接本地 package 引入，不改主线 PhoneAgent。

本地重跑入口保留在 `tools/`。本次日志（均忽略）：`.build-ncm-build.log`、`.build-ncm-app-device.log`、`.build-ncm-app-simulator.log`、`.build-ncm-core-tests.log`、`.build-ncm-swift.log`、`.build-ncm-rsd-tests.log`、`.build-ncm-operations-tests.log`。构建日志带编译路径，不用于对外共享。

## 仍缺失的关键实现 / 证据

1. 当前 S3 是原 PA3 固件，设备空闲状态未知；未获得新固件刷写、App 签名安装授权。故没有在该物理 NCM 接口上发现/QueryType/问候的结果。
2. 没有配对记录加载/生成/持久化、Pair Setup/Verify、TLS-PSK、网络 lockdown session/CoreDeviceProxy 或可用的完整 authenticated tunnel。`nd_authenticated_tunnel` 是可信后端集成接口，参数不是认证实现，更不能从 ND1 JSON 反序列化获得。
3. RSD/截图 C 代码可编译和 mock 测试，但无认证后端把它接到手机。只暴露既有四类已知服务（screenshot/display/universal HID/Indigo），不宣称完整列举系统所有服务。
4. 触控接口固定 unsupported。媒体认证、音视频前置协商、RTP drain、会话安全停止、输入后屏幕确认未实现。
5. PhoneAgent 重协议 + S3 限定转发的分工只完成设计，没有可用 relay；普通 App 自连接在 app-only 的旧证据中曾被明确拒绝，不能绕过此门槛宣称成功。
6. 独立 DDI 来源/授权/匹配/个性化/挂载、拔除 Mac 后长期运行、重启恢复、后台执行、带宽/资源占用均待验证。保留当前 VPN，不依赖 LocalDevVPN。

已完成的授权范围是独立代码、构建与离线测试。下一次真机实验的数据、目标、替换固件/增加 App 的后果及授权边界见 [NEXT_EXPERIMENT.md](NEXT_EXPERIMENT.md)。
