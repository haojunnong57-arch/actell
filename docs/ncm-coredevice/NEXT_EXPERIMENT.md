# 待授权的唯一最小实验：S3 来源的只读 NCM 服务准入

**此实验未执行。** 设备空闲状态未知；没有打开现有 COM/USB、改网络/VPN、读取密钥、抓屏或发送输入。Swift/Rust/S3 实际后端链已接线并可离线构建，详细状态见 [BACKEND](BACKEND.md)；本实验只解除更早的设备准入未知，不启动认证/媒体能力。新版固件含待命 NR1 转发器，但本实验的 Safari 页面只发 ND1 诊断，不创建 NR1 会话。

## 具体动作和影响

首选备用 ESP32-S3；否则需要用户明确批准一个维护窗口，确认其他任务已释放当前板和手机，核实当前 PA3 固件的实际回滚镜像/刷写端口/供电接法后，临时刷入本 worktree 的 NCM-only 诊断固件。**用当前板会覆盖 PA3/HID 固件，实验期间失去其功能**。本工程的 build 脚本不 flash；构建日志中的 flash 提示不是执行授权。

无需另装 App：手机 Safari 手动打开 `http://192.168.7.1:28767/`。GET 页面没有探测；页面没有外部资源、脚本、自动刷新或上传。逐次点击 Status、IPv4 discovery + greeting、IPv6 discovery + greeting；必要时再点 Lockdown QueryType。浏览器到 `.1` 的路由若被现有配置/VPN阻止，先报告这一层，不自动改设置；可另行选择已构建但未签名安装的 NCMProbe 作为诊断客户端，**它不是本次实验必需项**。

每个 discovery 按钮执行一轮 3 秒 mDNS，立即对第一条当轮有效 RemotePairing 候选做 TCP/RPPairing 问候，之后关闭；没有候选就不猜端口。IPv4/IPv6 独立测试。Lockdown 仅 `.2:62078` 的 QueryType。所有设备方向连接从 S3 的 NCM 接口发起；手机内普通 App 或 Mac Wi-Fi 上的成功不替代这一证据。

不需要新 Pair/Trust/PIN；不提取旧身份，不创建持久凭据，不开屏幕/音频媒体，不发触控。如果手机意外提示 Trust/PIN/新配对，**停在提示处另行说明并取得授权**。Bonjour 查询可能让系统产生本地诊断日志，页面只显示服务类型、协议版本、连接/错误状态，不显示设备名、TXT、UDID 或密钥。HTTP 明文只在固定 `.1↔.2` USB 子网传送这些诊断元数据；页面与 POST 均 no-store、无 CORS，POST 检查 origin/host 和每次 USB 连接的临时 token。token 不是配对身份。不给公网主机、模型或日志输出屏幕内容。

## 只记录以下结果

| 层 | 观察值 | 结论及停止点 |
|---|---|---|
| Safari → S3 | Status `ncm/diagnostic-only` | 仅证明本地页面/命令通道；失败先处理路径，不能当开发服务拒绝 |
| S3 mDNS IPv4/IPv6 | candidates / no-candidates / io，以及族和服务类型 | 无广播不能断言没有服务；不能用固定 RSD 端口继续试 |
| S3 → RemotePairing | tcpConnected、greeting result、wireVersion | TCP 成功而问候被断开：卡在认证前。单凭 ECONNRESET 不能断定“本机来源”策略；系统原因需另获日志采集授权 |
| S3 → Lockdown（可选） | tcpConnected、QueryType result | Type 正确也不代表已信任、可开启 CoreDeviceProxy |
| 任一问候被接受 | 立即结束本实验 | 记录“未认证”；随后再决定已信任 Lockdown 或 RP 身份方案和必要授权，不能宣称截图/输入成功 |

**能否不影响主线就只读发现？** 现有 PA3 固件没有 ND1/HTTP 探测入口；本次不改它，因此不能让当前板原样发出这个实验。备用板能保留原板固件，但占用同一手机端口时仍需协调。当前板必须临时换固件；“数据操作只读”不等于“刷写无影响”。不从主线抢串口，不让 Mac 后台代做 S3 探测，不关闭 VPN，也不引入 LocalDevVPN。

如果 NCM 上没有可用服务，下一次候选才是 `_remotepairing-pairable-host._tcp` 反向初配监听/广播。它会改变手机信任并生成长期身份，需要另行授权，不能自动升级本实验。Apple 文档只确认同 Wi-Fi 流程，不能预先保证 NCM 可行。
