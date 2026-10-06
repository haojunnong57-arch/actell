# Swift / Rust / S3 实际后端链

本轮已补齐前一提交中缺失的 **S3 双连接转发、Rust 原生连接器、C ABI 和 Swift 调用层**。独立 `NCMProbe` 已链接该库并拥有其生命周期；初始化、显示 ABI 版本和浏览诊断页面均不发开发者请求。现有身份由调用方显式传入内存，默认界面不读旧配对文件、不生成身份，也不提供绕过授权的截屏/触控按钮。

当前可构建的调用链：

```text
NativeDeveloperServices.connect(已授权内存身份, 独立权限, 新鲜发现候选)
  → C ABI 整数句柄 / 专属后台 runtime
  → RelayConnector（实际 .2 interface + bind(.2)，仅连接 .1:28767）
  → S3 NR1 OPEN → 选定 iPhone RemotePairing endpoint
  → 真实 PairVerify
  → NR1 TUNNEL → 同一目标的协商 TCP listener
  → TLS-PSK / CDTunnel / IPv6 userspace TCP / retained RSD
  → readiness / capturePNG / startTouchMedia / tapDelivery
```

Swift 先复用 `.2/24` 的具体 Ethernet interface 选择和 Network.framework 类型验证；Rust 每次连接复验地址/网卡索引，并设置 Darwin `IP_BOUND_IF` 及源地址。失败不改用默认路由、Wi-Fi/VPN、Mac 代理或设备直连。原有 IPv4 `%interface` 取 NWInterface 的兼容边界仍存在；原生 socket 在 iPhone NCM 上的运行效果尚未实测。

## NR1 转发协议

与只读 ND1/浏览器共用 `.1:28767`，入口只接受 `.2`。第一行最长 96 bytes；只有以下三条命令：

| 命令 | 约束 |
|---|---|
| `NR1 OPEN generation index nonce` | 候选必须是当前未过期 RemotePairing 服务；nonce 为 32 个小写十六进制字符；固件只允许一个会话 |
| `NR1 TUNNEL nonce port` | 第一条连接已建立，nonce 匹配，未撤销；目标地址从第一条会话复制，只有 port 可以取认证后协商值；只允许第二条连接一次 |
| `NR1 CANCEL nonce` | 撤销同一会话的两条流；不触发开发者操作 |

建立上游连接后回复 `NR1 OK\n`，随后字节完全透明；失败仅回复短静态错误。S3 不保存长期私钥、不解密 PairVerify/TLS、不解码屏幕/音频。nonce 只隔离流，不是手机开发者身份认证，也不能辨认手机上哪个 App：其它同机 App 仍可能占用通道。该受控 USB 实验接口不应被当作可暴露到其它网络的代理。

每条流每方向一个 2048-byte slab，满时停止对应方向的读取，靠 TCP 窗口施加背压；应用层上限每条流 4096 bytes、双流 8192 bytes，另外还有 lwIP socket/pbuf（当前 TCP window/send buffer 各 5760、max sockets 10）。两个 worker 的栈各 8 KiB，峰值待硬件测量。不是无界队列，也不使用 PSRAM 或 Rust/Python runtime。

任何流 EOF/I/O failure、USB generation 失效、显式取消或整个会话 60 秒无字节活动，都终止整代连接；不会保留半开流或自动重放输入。60 秒取两条流的共享活动时钟，因此媒体流动时空闲 PairVerify 控制连接不会单独超时。断开事件检查间隔最多约 50ms；这不是远端媒体/触点停止确认。

## ABI / Swift 所有权

头文件：[ncm_backend.h](../../ncm-dev/PhoneAgentNCM/Sources/CNCMBackend/include/ncm_backend.h)。所有 C 参数在 `start` 调用内复制；没有把 Swift 闭包或借用指针跨线程保存。每个会话使用独立线程和 Tokio runtime，原生句柄是递增整数，不暴露 Rust 指针；`close` 幂等撤销句柄并取消该 runtime 的 adapter/media tasks，普通 EOF 同样向上返回错误。Swift 在取消/异常时关闭整代连接；App 在后台、离开页面或取消设备空闲确认时关闭持有的 backend。**当前 App 因而只承诺前台会话；切换到别的 App 会触发关闭，不能称作已经实现跨 App 长期后台控制。** 后续后台运行方案需要独立技术验证，不能偷偷引入 VPN 或音频保活。

最多两个进程会话（单块 S3 仍只接收其中一个），每个会话最多一个排队请求、一个未消费回复；reply credit 在 Swift 真正拷走 payload 前不会释放，因此不在消费者阻塞时继续发截图/输入。request ID 单调递增，已接受的请求不重放；错误只含数字阶段/原因，ABI 不输出原始报文或身份。输入成功值明确是 `reportsWrittenVisualEffectUnverified`。

权限分别为：验证已有身份、单张截图、包含音频的媒体会话、输入。未授予对应权限的操作在 Rust 中拒绝；Swift 的验证权限门控先于网卡查找/拨号。传入身份不是新建配对；本库无文件/Keychain 自动查找或 PairSetup。调用者仍需合法取得与目标绑定的完整已有 RP 身份；不能从旧 app-only 私钥或 Lockdown 记录默默推导。

已有授权时的调用顺序如下（文档示例，不执行）：

```swift
let backend = NativeDeveloperServices()
try await backend.connect(identity: authorizedIdentity,
    authorization: grantedPermissions, discovery: freshReply, endpoint: selectedRP)
try await backend.checkDeveloperReadiness() // 不下载/挂载 DDI
let png = try await backend.capturePNG()     // 仅返回调用方内存
try await backend.startTouchMedia()         // 需要屏幕及音频媒体授权
let delivery = try await backend.tapDelivery(x: x, y: y)
backend.close()                             // 不声称远端停止已获确认
```

`UnavailableDeveloperServices` 作为显式不可用实现保留，未用于真实 backend 的上述路径。ND1 的 `RSD/SCREENSHOT/TAP` 仍拒绝并返回 authorization-required；它们不是 C ABI 的入口。

## 实际离线证据

- C relay 测试在 localhost/socketpair 上双向各传输 1 MiB，延迟消费者触发背压，验证字节完整、4 KiB slab 上限、两条流、取消联动、独立实例隔离、失效候选/错 nonce/重复连接拒绝。
- Rust 连接器测试实际 TCP，验证同 nonce 的 OPEN/TUNNEL、协商端口、拒绝重放、错误传播以及不吞掉 ACK 后首字节。
- ABI 测试验证 payload 缓冲不足时保留事件、队列满、重复 request ID、句柄隔离和关闭；内存 peer 执行真实问候/M1，再故意失败或等待取消。
- `test_ncm_chain.sh` **运行真实 Swift wrapper → 实际 Rust ABI/worker → 实际 NR1 客户端 → 同一 C relay 源码 → synthetic RPPairing peer**。对端确实看到问候和 verifyManualPairing M1，故意关闭后 Swift 收到 PairVerify 错误；另一测试等待实际问候后取消 Swift task，确认原生 worker、C relay、模拟上游均关闭。这是连通和失败路径证据，不是成功认证/截图/输入证据。
- fixture 构建在独立 `.build/ncm-rust-fixtures`；只允许 127.0.0.1，身份为公开确定性测试值。生产构建不启用该 feature，已链接 App 的符号表没有 `ncm_test_start_loopback`。Device 与 arm64 Simulator App 都需链接检查；没有签名、安装或运行。

整个后端依然不能声称生产内存全局有界：以上新增传输/ABI 背压，不会自动修复 jktcp 内部无界通道或 RemoteXPC 聚合/递归解析配额。iOS27 媒体兼容、远端清理、DDI 来源和同机开发者服务政策仍需独立验证；不以软件连线完成替代这些证据。
