# NCM 开发者服务路线：独立诊断与真实协议后端

2026-10-06 系统配对开发：新增 App 系统确认/PIN、自动保存经过验证的 RemotePairing 身份、持续后台配对和经 S3 的认证/截图/点击入口。手工 Lockdown 导入移至高级诊断。详见 [PAIRING.md](PAIRING.md)；真实端到端控制仍待硬件验证。

2026-10-06 更新：真机 Safari 诊断与 S3→iPhone Lockdown QueryType 已由用户回报成功。新增普通 Lockdown 的独立 NL1、StartSession/TLS、C ABI/Swift 和记录导入测试入口；离线验证及构建通过，尚未取得真实身份认证结果。详见 [LOCKDOWN.md](LOCKDOWN.md)。下文为此前三轮实现及验证记录。

这是一条独立的 **USB 仅 NCM → iPhone 开发者服务** 路线。目前可构建并离线验证的是 NCM-only 固件、手机诊断 App、浏览器探针，以及实现 PairVerify/TLS-PSK/RSD/截图/媒体与触控调用的 Rust 后端库；**尚未证明 NCM 准入，后端已通过 S3 relay/Swift ABI 接到独立 App，未取得真实截图或输入成功证据**。

- worktree：`/Users/developer/Developer/AI/ios-use/ncm-coredevice`
- branch：`feature/ncm-coredevice`
- 已提交基线：`80b1c8f99c2e6d35e52bbb37967aa8b0a4b6c7e3`（PA3 常连）
- 真正仓库是相邻 `with-esp/`；父目录 `ios-use/` 不是 Git 仓库。`app-only/` 是无独立 Git 元数据的实验目录。
- 创建命令：`git -C with-esp worktree add -b feature/ncm-coredevice ../ncm-coredevice 80b1c8f99c2e6d35e52bbb37967aa8b0a4b6c7e3`。
- 原主线只见已有的 `ios-app/PhoneAgent.xcodeproj/project.pbxproj` 未提交签名修改；没有复制、还原或移动该文件。所有实现均位于本 worktree 新目录，不修改 app-only、主线固件/PhoneAgent、VPN 或待办 Page。

USB Host/Device 是 USB 总线角色，TCP client/server 是网络角色；iPhone 作 USB Host 并不阻止 S3 主动建立 TCP。是否接受开发者连接仍是服务端策略问题。主线 `.1 ↔ .2` 的 PA3/PING 与用户报告的 USB HID 点击不作为这条路线的成功证据。

## 当前交付

| 模块 | 实际实现 | 边界 |
|---|---|---|
| `ncm-dev/firmware` | 独立 S3 NCM-only 工程；IPv4 `.1/24`、IPv6 link-local、IGMP/MLD；TCP 28767 的只读诊断服务 | 已交叉编译，未刷写；IPv6/NCM 的 DAD、广播和吞吐未实测 |
| `ncm-dev/core/nd_discovery.c` | 有界 DNS-SD PTR/SRV/A/AAAA、压缩指针检查、分包聚合、TTL/goodbye、重复端点去重 | mDNS 未认证；不保存 TXT；只接受指定 `.2` 的 A 和同链路 link-local AAAA |
| `nd_socket.c` / `nd_server.c` | 指定 NCM 出口、3 秒 deadline、USB epoch 撤销、失效候选拒绝、无后台轮询/自动重试 | NR1 仅对选定 RP 目标双流转发，没有任意地址代理/NAT/端口扫描 |
| `nd_http.c` | 同端口本地浏览器入口，GET 无动作，POST 同源/token 门控；一轮发现后立即问候首个 RP 候选 | 只读诊断，免装 App；未在 Safari 真机运行 |
| `ncm-dev/rust` | 实际 PairVerify → TLS-PSK/CDTunnel → retained RSD → Developer/DDI 检查 → CoreDevice 截图/媒体/HID | iOS 静态库、C ABI、Swift wrapper 和受限 relay 已接线，见 [BACKEND.md](BACKEND.md) |
| `nd_pairing.c` | RemotePairing 明文问候，严格封装/角色/序号/版本检查，解析后清空缓冲 | 只证明问候被接受；没有 Pair Setup、Pair Verify、TLS-PSK |
| 既有 `bridge_lockdown_probe` | 复用 QueryType 的 XML/bplist 编解码及分块 I/O | 不调用 Pair / StartSession / StartService，不读取任何旧凭据 |
| `nd_services.c` | 对接既有 RSD 和 CoreDevice PNG streaming；仅接收可信后端提供的认证隧道、动态 IPv6/RSD 端口和 DeveloperMode/DDI 检查结果 | **集成接口**，当前诊断固件没有认证后端/调用路径；触控返回 unsupported，不发送 HID |
| `PhoneAgentNCM` Swift package | 强绑定实际 `.2` 所在网卡及 local endpoint；有界 ND1 请求、取消/超时、协议验证；截图/输入协议接口 | `NativeDeveloperServices` 已连接实际后端；ND1 ACK 不授予权限，启动需已授权内存身份 |
| `NCMProbe` iOS App | 小型独立诊断界面，需手动确认设备空闲、手动操作；后台撤销连接；结果仅留内存 | Device/arm64 Simulator 已链接 Rust、无签名构建；未安装、未运行界面，不替换 PhoneAgent |

原仓库的 USB Host/usbmux、USB HID 和 ScreenCaptureKit 文件仍因基线存在，但新固件 CMake 不编译它们，独立 iOS target 也不引入这些组件。USB 描述符只含 NCM 两个 interface；编译期拒绝 HID/CDC/MSC。

## 构建和测试

从本 worktree 执行：

```sh
bash tools/test_ncm_chain.sh
bash tools/test_ncm_rust.sh
bash tools/build_ncm_rust.sh device
bash tools/build_ncm_rust.sh simulator
bash tools/build_ncm_developer.sh
bash tools/build_ncm_probe_app.sh device
bash tools/build_ncm_probe_app.sh simulator
bash tools/test_ncm_developer.sh
bash tools/test_ncm_swift.sh
bash tools/test_lockdown_probe.sh
XPC_PYTHON=/usr/bin/python3 bash tools/test_rsd.sh
PYTHON=/usr/bin/python3 bash tools/test_operations.sh
```

固件沿用已安装 ESP-IDF 5.5.5 / TinyUSB 锁定依赖；本次从主线既有 `managed_components` 复制到本 worktree 忽略目录，不执行新下载程序。缺少依赖时组件管理器按 lock 文件解析，不能把当前机器的缓存视为所有环境已有。`IDF_PATH`、`IDF_TOOLS_PATH` 可覆盖；默认复用相邻 with-esp 下的工具链，产物写本 worktree `.build/`。Swift package 无外部依赖；本机 `/usr/bin/python3` 已有 construct/hyperframe，供既有 RSD oracle 使用，未安装 Python/Rust runtime 到 S3。

Xcode 项目已纳入版本控制，`python3 ncm-dev/ProbeApp/generate_project.py` 可确定性重建。上述脚本不包含 flash、install、launch 或签名；不要直接执行 ESP-IDF 构建输出中的 flash 建议。具体结果和边界见 [VALIDATION.md](VALIDATION.md)。

## ND1：只读诊断通道

App 从本机 `.2` 的真实 Ethernet-like interface 连接 `.1:28767`，每连接一个 ASCII 命令，换行结束，服务端返回一个最多 4096 字节 JSON 并关闭。入口仅接受 `.2`。命令最长 64 字节。它是短连接诊断协议，与 PA3 不兼容，也不复用 PA3 端口。

| 命令 | 行为 |
|---|---|
| `STATUS` | 仅返回 `diagnostic-only`；证明 App ↔ S3 诊断 round-trip |
| `DISCOVER4` / `DISCOVER6` | 在 NCM 上查询 `_remotepairing._tcp`、`_apple-mobdev2._tcp`、`_remotepairing-pairable-host._tcp`，3 秒内收集并补查 SRV/A/AAAA |
| `LOCKDOWN` | 从 S3 `.1` 连接指定 `.2:62078`，只发 QueryType；62078 是 lockdown 已知入口，不是 RSD 端口 |
| `PROBE generation index` | 仅连接本轮发现候选，返回 TCP 与问候/QueryType 独立状态；候选最多存活 5 秒且尊重更短 TTL |
| `RSD` / `SCREENSHOT` / `TAP` | 明确返回 `authentication/authorization-required`，无 I/O；App UI 不提供这些动作 |

`pairable-host` 候选只可见，不主动连接；返回 `authorization-required`。本版不发布 pairable-host 广播，不产生持久身份，不展示/记录 PIN。问候仅携带固定版本与 `attemptPairVerify=true` 的意向，收到问候后立即关闭，不发送密钥挑战。

诊断 JSON 只含层、结果、系统错误码、协议版本、候选索引/族/端口；无真实地址、主机名、TXT、设备标识、屏幕或密钥。`authenticated` 永远 false。无原始包日志、文件导出或模型/云服务请求。ND1 本身未认证，因此只允许这些窄只读操作；将来传输配对/屏幕数据前必须另行实现认证及权限边界，不能直接扩展成明文任意代理。

IPv6 范围仅支持同链路 link-local，不把 `.2` 映射成隧道内部地址，不默认 RSD 端口。Bonjour 无回复可能是未广播、权限、接口不支持或丢包，不能定论服务不存在。IPv6 multicast/socket 的线上行为待实测；本次仅测试地址解析与隔离策略。

## PhoneAgent / S3 分工与无 Mac 路径

当前实现：PhoneAgentNCM → **S3 发起** → iPhone 服务问候。它能检验外部来源是否改善 app-only 的本机拒绝；App 的普通反向 socket 仅是诊断入口，完全不等于系统开发者服务已开放。

软件已实现第一条分支；它只在显式授权调用时启动，准入和控制效果仍需真机证据。另列出未采用的固件后端路线：

1. **优先候选：PhoneAgent 承载协议，S3 承载受限字节转发。** 将 device-hub-ios/idevice 的 socket 边界换成经过认证的 App↔S3 流；由 S3 建立外向 RemotePairing 和协商产生的 TCP tunnel 连接，PhoneAgent 处理 SRP/PairVerify/TLS-PSK、用户态 IPv6/TCP、RSD、PNG 及媒体 drain。这样 S3 不需完整 Python/Rust runtime。必须验证 iPhone 服务实际看到 S3 来源、反向初配与后续会话均能跨转发层、App 后台可持续以及媒体带宽；本版已实现这一 relay 和 Swift/Rust 接线，详见 [INTEGRATION](INTEGRATION.md)。
2. **C 固件后端：**沿用已有 C 协议核心，在 S3 上实现网络 lockdown+TLS+CoreDeviceProxy 或 RemotePairing 认证/TLS-PSK，再复用 CDTunnel/lwIP/RSD/PNG。密钥存储、TLS、配对状态与 DDI 仍需完整实现；不能把目前 host 测试算作这一组合已经成功。

两条认证路线不得混用身份：

- 已信任网络 lockdown → 保留 HostID/SystemBUID/证书身份 → session TLS → CoreDeviceProxy → CDTunnel → 动态 IPv6/RSD。
- RemotePairing 身份（identifier/Ed25519/peer binding 等）→ Pair Verify → 协商 TCP listener/TLS-PSK → CDTunnel → 动态 IPv6/RSD。较新 iOS 优先 TCP；不假定 QUIC 必需。
- iOS 27 初配候选：控制端广播 `_remotepairing-pairable-host._tcp` 并监听，手机主动连接、用户在系统 UI 完成 Trust/PIN；随后发现 `_remotepairing._tcp`。Apple 文档只确认同 Wi-Fi 流程，没有 NCM 准入保证。

最终运行路径可以不含 Mac，但“无 Mac 初次准备”和“已准备后的无 Mac 运行”要分别验收。DDI 获取授权、来源、版本匹配、TSS 个性化、挂载/重启恢复仍是独立工作；不捆绑 Apple DDI，不使用不明镜像，不调用 Mac 后台服务代做。触控必须有经认证的 DisplayService 会话及媒体收包/drain；可省 HEVC 解码，不能省认证。已有全局 stopAll 行为不能直接用于共享设备，必须核实本会话的安全清理。

复用依据见 [REUSE.md](REUSE.md)，需要另外授权的下一实验见 [NEXT_EXPERIMENT.md](NEXT_EXPERIMENT.md)。

浏览器最小实验现可免装新 App；但当前 PA3 固件缺少此入口，依然需要备用板或授权维护刷写。见 [NEXT_EXPERIMENT.md](NEXT_EXPERIMENT.md)。Rust 库的真实代码、接线缺口、媒体资源和清理限制见 [BACKEND.md](BACKEND.md)。
