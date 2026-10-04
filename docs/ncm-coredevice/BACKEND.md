# 真实协议后端：已实现的代码与尚未取得的证据

`ncm-dev/rust` 是供 PhoneAgent 进程承载的 Rust 库，**不是当前诊断 App 已可用的截图/触控能力**。它没有启动器、凭据文件路径、自动发现、Mac 代理或原生设备直连 fallback。测试只使用内存 duplex、公开的确定性测试种子及合成报文；没有读取已有手机身份，也没有创建持久配对记录。

## 代码路径

| 层 | 当前真实调用 | 离线证据 / 设备前置 |
|---|---|---|
| 既有 RemotePairing 身份 | `ExistingIdentity` 保留 host identifier、Ed25519 密钥对应关系、altIRK 和绑定的 peer identifier/public key | 不把 Lockdown plist 当 RP 记录；不提供导入/持久化 UI。调用方须将已授权身份放入内存；类型来自 idevice，本库不调用其文件/生成方法 |
| PairVerify | RPPairing 问候 → `verifyManualPairing` M1–M4；复用 Device Hub 补丁版的 peer 签名/标识校验 | 新测试实际执行问候和 M1，在恶意 M2 前截断，确认无 PairSetup/重试/隧道 fallback；密码学向量由复用测试覆盖。真机仍须 S3 来源准入及授权身份 |
| 隧道 | 验证成功才 `create_tcp_listener` → 新 S3 stream → 原生 Rust TLS1.2 PSK → CDTunnel | 没有 OpenSSL 程序或 QUIC 假设；协商 client/server IPv6、MTU、RSD port，拒绝零端口/IPv4/loopback/同地址，MSS=MTU−60 |
| 用户态网络 / RSD | jktcp IPv6/TCP/UDP → 动态 RSD → 保留 RemoteXPC 控制连接 → 校验 UniqueDeviceID/ProductType 与已验证 peer 一致 | 不安装 TUN/VPN；不写死 RSD 端口，不用 `.2` 作隧道内部地址。枚举实际 RSD 表，字段只供内存调用方使用 |
| Developer Mode / DDI | `ImageMounter.query_developer_mode_status()` 和 `image_is_present("Personalized")` | 只读。没有下载、个性化或挂载；镜像存在不单独证明版本匹配/服务权限，服务调用仍可失败 |
| 截图 | `ScreenCaptureServiceClient.take_screenshot(None, Png)` → PNG CRC/IHDR/IDAT/IEND 和尺寸上限校验 → 返回调用方内存 | 这是真实 capturescreenshot 请求代码，测试 PNG 仍是合成。结构校验不等于完整像素解码，也不证明真机截图成功 |
| 触控媒体 | 同一 authenticated tunnel 中绑定两个 UDP 端口；DisplayService audio→video 协商；分别保留两个 reply-bearing 控制连接 | 音视频 drain，不解码/保存/上传。视频须符合经协商的 SSRC/PT、源端口、递增序号；首次包和后续新鲜度门控。兼容参数沿用 Device Hub，iOS27 兼容性未实测 |
| 输入 | 活动媒体到达后发送 UniversalHID Down、50ms 后 Up | 输入坐标是 0…65535 归一化坐标，不是像素；不推断方向。结果名明确为 `ReportsWrittenVisualEffectUnverified`。没有把 ACK 或 write 成功当作 UIKit 生效 |
| 取消与清理 | deadline、互斥的 `&mut Session`、失败/取消撤销整代传输、abort 所有 drain task；关闭时移除本会话控制流 | 不重放输入，不调用影响其他控制端的 `stopAll`。取消可能发生在 Down 已到达之后；不能保证远端释放。自有隧道关闭是否停止远端媒体/触点仍需授权真机核实；关闭结果明确 `RemoteMediaStopUnconfirmed` |

采用 Device Hub 的媒体兼容 profile（Mac17,7 / framework 2205.3.1 / OS 25F71）只是协议参数复用，不是声称手机变成 Mac 或已验证 iOS27。音频也会经认证会话到达控制端并被丢弃，因此授权真实媒体时必须同时说明音频和屏幕数据流。

## 分工与尚未接线的部分

PhoneAgent 承担密码学、TLS、用户态 IP、RSD、媒体排空及 CoreDevice 请求；S3 最终只负责有界的 NCM 字节转发。S3 不运行 Rust/Python，也不拿到长期身份私钥。即使 PhoneAgent 是被控的同一手机，系统所见 TCP 发起端也必须是 S3；是否仍被手机按本机来源策略拒绝要实测。

`NcmConnector` 是强制传输边界，须提供**同一个被选 NCM 对端、同一 USB generation、由 S3 发起**的两条流（PairVerify 与协商的 TCP listener）。库内没有 `TcpStream::connect` 或默认路由。当前交付是可构建的实际协议库；**S3 双连接 relay、Swift↔Rust C ABI、生命周期桥接及授权身份注入尚未实现**。`NCMProbe` 仍只调用 ND1，`UnavailableDeveloperServices` 没被偷偷改成模拟成功。静态库不代表已链接进 App。

这些接线工作可继续离线开发，并非“手机不授权就无法写代码”。目前影响路线选择的唯一最早真机阻塞，是 S3 来源的 NCM 服务问候能否被接受；它失败时，需要先区分没有服务、接口策略和必须新配对，盲目补 UI/凭据导入不能解除它。最小实验见 [NEXT_EXPERIMENT](NEXT_EXPERIMENT.md)。

还不能直接视为生产后端：jktcp 0.1.6 的内部通道有无界队列，RemoteXPC 聚合/递归解析尚未整体加入资源配额，截图库先收完整回复再校验 PNG；高码率或异常回复的内存上限须继续处理。不能用当前 CRC/超时宣称全链路内存有界。媒体停止/输入取消的远端确认、真实 NCM 吞吐、App 后台暂停恢复、DDI provisioning 也未验收。

## 构建、测试与来源

```sh
bash tools/test_ncm_rust.sh                 # 仅内存协议测试，offline + locked
bash tools/build_ncm_rust.sh device        # aarch64-apple-ios 静态库
bash tools/build_ncm_rust.sh simulator     # aarch64-apple-ios-sim 静态库
```

脚本使用既有 Rust 1.95.0 工具链；默认从相邻 app-only **只读执行编译器**，或指定 `NCM_RUST_TOOLCHAIN`。本 worktree `.build/ncm-cargo` 的 registry/cache 为独立副本；Cargo 输出只写 `.build/ncm-rust`，不修改 app-only。所有 Cargo 操作使用 `--offline --locked`，不会下载/执行第三方二进制。其他机器需预先准备对应工具链、目标标准库及锁定源码缓存；脚本不会自动安装。

实际 vendoring 来源是 Device Hub `1fcdfb0…` 中的 idevice `a64b886…` 加项目补丁，不是声称未修改的 upstream HEAD。保留两个 MIT license。原始 Cargo.toml 保存在 `Cargo.toml.upstream`；`tools/prepare_ncm_idevice_manifest.py` 收窄为当前原生后端所需依赖，避免解析未使用的安装/恢复/wasm 工具链；未选功能名仅供 cfg 检查，不是支持这些功能的声明。唯一 Rust 协议源码适配是 RSD `new_retained`，使控制连接由 Session 持有；PNG validator 直接保留 Device Hub MIT 来源。精确文件摘要和变更标记见 `ncm-dev/rust/SOURCE_MANIFEST.json`。没有复制许可证不明的 idevice_pair 代码，也没有修改第三方许可。
