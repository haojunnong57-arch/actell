# 普通网络 Lockdown：已有身份的 StartSession / TLS

2026-10-06，在 `feature/ncm-coredevice` 上新增第一阶段普通 Lockdown 认证链。
用户已在 iPhone Safari 取得 `STATUS: diagnostic-only`、`DISCOVER: no-candidates`、
`LOCKDOWN: lockdown-querytype/ok, tcpConnected:true`。这些是 NCM 和真实 QueryType
通信的证据，不是受信任会话、CoreDeviceProxy 或控制成功证据。

用户提供的 Library 方案分享链接要求浏览器登录，本轮未读到正文；实现依据是用户
明确提出的已有普通配对记录 → StartSession/TLS，并保留 QueryType、区分两条身份路线。

## 实现范围

- 既有 `LOCKDOWN` ND1/Safari 命令保持只读 QueryType，HTTP 表单采用 `same-origin`
  Referrer Policy，继续拒绝空/跨来源和无效 token。
- 独立 `NL1 OPEN <nonce>` 只令 S3 连接既定手机 `.2:62078`；不依赖 IPv4/IPv6 mDNS。
  `NL1 CANCEL` 与 `NR1 CANCEL` 分开，NL1 会话不能使用 NR1 TUNNEL。
  原有 NCM 源地址检查、USB epoch 取消、60 秒无流量期限和有界转发保留。
- App 的 Rust 库接收显式选定的普通 Lockdown plist，不自动查找系统记录，不发 Pair，
  不生成信任、不回退 RemotePairing。S3 只转发字节，不持有私钥。
- 首个设备请求就是 StartSession，携带原 HostID/SystemBUID；要求正确 Request、
  非空有界 SessionID 和 EnableSessionSSL=true。拒绝或错误后关闭，不重试/降级。
- 使用记录中的 HostCertificate/HostPrivateKey 完成 TLS 1.2 客户端认证；服务器叶证书
  必须与 DeviceCertificate 精确匹配，握手签名由 rustls/ring 实际验证。
  不复用第三方 `sni.rs` 中跳过证书/签名校验的配置。
- ready 仅在 TLS 握手完成后报告。正常结束在同一 TLS 流发送 StopSession；取消、后台、
  拔线只撤销本地连接，不能报告远端已经确认 StopSession。

普通 Lockdown 身份包含 HostID/SystemBUID/X.509 证书与主机私钥；RemotePairing 身份
使用 identifier/Ed25519/altIRK/peer binding。两者有独立入口和类型，不能互换。

## 测试入口

新版 S3 固件：`.build/ncm-developer/phoneagent_ncm_developer.bin`。
本轮已构建，尚未刷入实体板。此前已刷入的是 HTTP 修复版，不含 NL1。

独立 NCMProbe App 中“普通 Lockdown 会话”区域：

1. 保持 iPhone 的 NCM IPv4 为 `192.168.7.2/24`，连接运行新版固件的 S3。
2. 确认设备空闲，填写目标 iPhone UDID，手动选择已有配对 plist。
3. 允许使用此记录，再点“验证 StartSession / TLS”。
4. 成功只表示受信任 TLS 会话；点“结束会话（StopSession）”确认正常清理。

记录最大 1 MiB，必要字段是 HostID、SystemBUID、DeviceCertificate、HostCertificate、
HostPrivateKey；证书/私钥为普通配对记录的 PEM data 字段。若有 UDID 字段，必须匹配
用户填写的目标。若某种导出的记录不含 SystemBUID，需要提供原控制端的对应 BUID，
不能生成替代值。本版不自动合并其他系统配置文件。

导入记录只留内存，会话启动完成或取消后清除 App 持有的 Data；Swift COW 和解析器
临时副本无法承诺完全擦除。没有持久化、日志输出或上传配对记录。测试页面尚未做真机
UI 验收；Device/arm64 Simulator 无签名构建通过，尚未安装到 iPhone。

Swift `NativeLockdownSession` → `ncm_lockdown_start` → Rust `lockdown::Session`
→ `RelayConnector::new_lockdown` → S3 NL1。现有 poll/close 复用句柄和队列，action 5
只供普通会话正常 StopSession。错误阶段 101–107 单独命名，和 RP 的 1–12 分开。

## 验证和剩余工作

- C ASan/UBSan、QueryType/browser/relay 回归通过；新增固定 Lockdown 目标、协议隔离及取消测试。
- Rust 25 项 backend/ABI 测试和 175 项复用协议测试通过；包含实际内存流上的双向 TLS
  认证、同流 StopSession、错误证书拒绝、握手前没有 ready、手机拒绝后不 Pair/回退。
- Swift 15 项完整链路/边界测试通过；包含普通入口的权限和身份类型边界。
- 固件、Device 和 arm64 Simulator App 构建通过；clippy warnings-as-errors 通过。

所有新认证测试使用公开测试证书和内存/localhost 对端，未读取真实配对身份，不能推出
手机会接受原 Mac 身份在 S3 来源上的 StartSession。当前实体板连接/身份文件未就绪。

下一验收是原身份在这条 S3 链路上的 StartSession/TLS；成功后才增加普通路线的
StartService(CoreDeviceProxy)、动态端口转发及服务 TLS、CDTunnel/RSD。随后复用
截图/媒体/触控能力，但必须保留路线自己的设备绑定和生命周期。
