# 本 worktree 的验证与未验证项

验证日期：2026-10-04 UTC（本机 Xcode 日志显示 2026-10-05 凌晨）。基线 `80b1c8f99c2e6d35e52bbb37967aa8b0a4b6c7e3`，branch `feature/ncm-coredevice`。

**未连接或操作实体设备。服务准入、真实截图、真实输入均没有本轮成功证据。** 下面的 TCP 对端仅为 `127.0.0.1` 上的合成程序；Rust 使用内存 duplex；RSD/PNG 也只用合成 fixture。

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
  - 大小 **387680 bytes**（`0x5ea60`），1 MiB app 分区剩余约 63%。大小不代表运行时 SRAM/PSRAM 或吞吐裕量。
  - SHA-256：`87a9944c45518449dbc5347c2d6b1788da4d1fd5837e179dcdb5a801e29e3933`
  - Bootloader / partition table 也已构建；没有执行 flash。未启用 PSRAM，诊断任务栈预留 32 KiB，峰值未实测。
- iOS Device：`.build/ncm-probe-app/Build/Products/Debug-iphoneos/NCMProbe.app`
  - 无签名 executable SHA-256：`7f7dc1ac710133b9208577cf89108243fd81ac71481529c225d79465eaffd5e4`
- Simulator：`.build/ncm-probe-app/Build/Products/Debug-iphonesimulator/NCMProbe.app`
- Swift library 源码：`ncm-dev/PhoneAgentNCM/`，可直接本地 package 引入，不改主线 PhoneAgent。

本地重跑入口保留在 `tools/`。本次日志（均忽略）：`.build-ncm-build.log`、`.build-ncm-app-device.log`、`.build-ncm-app-simulator.log`、`.build-ncm-core-tests.log`、`.build-ncm-swift.log`、`.build-ncm-rsd-tests.log`、`.build-ncm-operations-tests.log`。构建日志带编译路径，不用于对外共享。

## 第二轮：真实后端与浏览器诊断

第二轮没有实体设备操作。代码位置 `ncm-dev/rust`，实际调用链及未接线部分见 [BACKEND.md](BACKEND.md)。

| 验证 | 实际结果 | 边界 |
|---|---|---|
| `test_ncm_rust.sh` | 新增 13 项测试 + 固定 idevice 的 175 项测试通过 | PairVerify 独立向量/篡改/peer mismatch、TLS record/取消/长度、CDTunnel、RTP/HEVC/RTCP、HID 编码等均离线；不证明设备会接受 |
| 新 backend 集成测试 | 实际 RPPairing 问候与 verifyManualPairing M1 字节通过内存流，模拟恶意对端截断 M2，确认不再拨号、不 PairSetup、不 fallback | 不是成功认证的端到端真机测试 |
| `build_ncm_rust.sh device/simulator` | Rust 1.95.0，iOS arm64 和 arm64 Simulator release 静态库构建通过 | 未链接 Swift/C ABI，未签名或装机；库中有真实截图/媒体/触控代码，不等于 App 可操作手机 |
| `cargo clippy … --all-targets -- -D warnings` | 本 backend 无 lint warning；`cargo fmt` 完成 | 不是安全审计，未覆盖所有第三方资源上限 |
| 新版 `test_ncm_developer.sh` | C ASan/UBSan、loopback 与浏览器 GET/POST 测试通过；GET 无探测、Host/Origin/token、重复头、禁止 chunked/越权动作均检验 | 不连接手机；尚未在 Safari 实机验证路由和页面 |
| 新版固件构建 / HTTP static analysis | 固件 387680 bytes，`clang --analyze nd_http.c` 无诊断 | 未 flash，无新硬件行为证据 |

Rust outputs：`.build/ncm-rust/aarch64-apple-ios/release/libphoneagent_ncm_backend.a` 与 `aarch64-apple-ios-sim/release/libphoneagent_ncm_backend.a`。这是普通 Rust staticlib，不是完成 C ABI 的 XCFramework。产物 SHA/测试摘要另见 [BUILD_RESULTS.json](BUILD_RESULTS.json)。离线 Rust 缓存是相邻 app-only 既有 registry 的独立副本；没有写回 app-only 或下载第三方二进制。日志 `.build-ncm-rust-all.log`、`.build-ncm-rust-ios.log`、`.build-ncm-rust-simulator.log`、`.build-ncm-rust-clippy.log`、`.build-ncm-core-second.log`、`.build-ncm-firmware-second.log` 均忽略。

## 第三轮：S3 转发与 Swift/Rust 接线已完成

第三轮详情见 [INTEGRATION.md](INTEGRATION.md)。第二轮表格中的“未链接 Swift/C ABI”是当时状态，现已由以下结果更新：

| 验证 | 最终结果 | 证据边界 |
|---|---|---|
| `test_ncm_developer.sh` 新增 relay suite | ASan/UBSan 下双向各 1 MiB、慢消费者、4 KiB/流上限、取消双流、独立会话、stale/wrong nonce/duplicate 拒绝通过 | 真正 socket，但只有 localhost/socketpair；不代表 NCM 带宽或实体连接 |
| `test_ncm_rust.sh` | 19 项 backend/ABI/relay 测试 + 175 项复用协议测试通过 | 包含 ABI buffer ownership、队列满、request ID、不串会话、失败/取消；没有真实手机认证 |
| `test_ncm_chain.sh` | 14 项 Swift XCTest 通过 | 其中完整 Swift→实际 Rust worker→NR1→同一 C relay→模拟手机确实发送问候/M1；对端故意失败及取消后，上层错误/清理得到验证，不是认证成功 |
| 原生权限与生命周期 | 验证权限在网卡查找/拨号前检查；独立截图/媒体/输入 gate，取消关闭句柄及专属 runtime | 只读 UI 不导入密钥或启动控制；没有运行 App 界面/系统后台切换 |
| 最终 App | Device 与 **arm64 Simulator BUILD SUCCEEDED**；实际链接 C ABI/Rust 后端，`CODE_SIGNING_ALLOWED=NO` | 未签名、安装、启动；不提供 x86_64 Simulator archive |
| 生产二进制隔离 | Device/Simulator 的已链接 dylib 均含五个 `ncm_backend_*` ABI 函数，没有 `ncm_test_start_loopback` | fixture 构建隔离到 `.build/ncm-rust-fixtures`，不会部署该测试入口 |
| 最终 S3 固件 | ESP32-S3 NCM-only + ND1/HTTP + NR1 双 worker 构建通过 | 未 flash，单会话两个 8 KiB worker 栈及 lwIP 内存峰值待测 |
| 代码检查 | Rust clippy `--all-targets --features offline-fixtures -- -D warnings` 通过；C 新 relay/HTTP analyzer 无诊断；diff/check 和来源 manifest 复核 | 不替代完整协议资源加固或真机验收 |

最新产物大小、SHA、测试计数和忽略日志摘要统一见 [BUILD_RESULTS.json](BUILD_RESULTS.json)。前面的二轮产物 SHA 为历史记录。最终日志：`.build-ncm-relay-tests.log`、`.build-ncm-relay-firmware.log`、`.build-ncm-native-rust-tests.log`、`.build-ncm-native-clippy.log`、`.build-ncm-chain.log`、`.build-ncm-linked-app-device.log`、`.build-ncm-linked-app-simulator.log`。

## 当前剩余条件 / 未验证项

1. S3 来源的 NCM mDNS/QueryType/RPPairing 问候是否接受仍未知，当前实体板仍保留 PA3；没有争用设备或实际服务准入结果。
2. 软件接线已经完成。启动实际 backend 需要调用方显式提供与目标绑定的、已授权的完整 RP 内存身份。没有新配对、自动提取旧密钥、身份导入 UI 或持久化；默认 App 页面只读诊断。未实现另一条网络 Lockdown Session/CoreDeviceProxy 认证路线。
3. 完整真机 PairVerify、TLS/RSD、截图、音视频协商、真实触控效果尚未验证。新增 relay/ABI 背压不代表 jktcp 和 RemoteXPC 全局资源已加固；媒体/触点远端清理仍无确认。
4. DDI 来源/匹配/个性化/挂载、无 Mac 冷启动、重启恢复、App 后台、NCM 吞吐、S3 运行栈/内存仍缺证据。已有 Personalized 镜像 presence 检查不单独证明兼容或服务权限。

最终需要的最小一次真机动作仍是 [NEXT_EXPERIMENT.md](NEXT_EXPERIMENT.md)：备用 S3 或经授权临时刷写维护窗口，然后 Safari 手动只读发现/问候。无需新 App、新配对或私钥。任何实体操作都保持待授权。
