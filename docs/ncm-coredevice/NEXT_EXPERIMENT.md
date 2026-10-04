# 最小下一实验：只验证 NCM 开发者入口

**本文件是待授权的实验说明，不表示已运行或可自动执行。** 当前设备空闲状态未知，没有打开主线 COM/USB、查看手机屏幕或读取配对密钥。

交付物是本 worktree `.build/ncm-developer/phoneagent_ncm_developer.bin`（SHA 见 VALIDATION）和无签名 `NCMProbe.app`。当前 S3 上 PA3+HID 固件没有 ND1 诊断命令，不能直接借该固件取得下面结果。运行前需要用户明确同意：

1. 确认主线/其他任务停止使用设备并选定维护窗口；必要时核对当前固件备份/恢复办法，不以这里的构建产物假称备份。
2. 把独立 NCM-only 诊断固件刷到指定 S3。**这会替换其现有固件、临时失去 PA3/HID 功能**；本次没有进行此步骤。刷写端口、供电接法和回滚镜像先核实，不从 `idf.py` 默认 flash 提示猜测设备。
3. 用户授权使用指定 Team/Bundle ID 给 NCMProbe 签名并装机。**这会增加一个 App，并可能占用 Personal Team 安装槽位**；不能覆盖 app-only、PhoneAgent 或 Device Hub/StikPair 来腾空间。若满额，先请用户选择处理方式。现有构建明确 `CODE_SIGNING_ALLOWED=NO`。
4. 探测数据只有固定 QueryType、协议问候与 mDNS 查询，目标仅当前 NCM `.2` 及同链路发现候选；不会发送触控、抓屏、上传数据、取出旧配对记录或生成新持久身份。手机可能出现本地网络权限请求，由用户自行确认；不变更 Trust/VPN。

建议执行顺序：

| 步骤 | 观察 | 可得结论 / 最小下一动作 |
|---|---|---|
| 用户检查 USB 网络配置仍为 `.2/24`，网关/DNS 空 | 不由工具改设置 | 配置偏差先由用户处理；不关闭现有 VPN |
| STATUS | `ncm/diagnostic-only` | 仅证明 PhoneAgentNCM→S3 通道；失败先查具体 interface 绑定，不能前进到服务层 |
| DISCOVER4 / DISCOVER6 | 分别记录候选类型/族，或者 no-candidates/timeout/io | 只说明这一轮发现结果。IPv6 失败不能推出 IPv4 必败；无广播不能推出所有服务均不可达 |
| LOCKDOWN | `tcpConnected` 和 `lockdown-querytype/result` | 拒绝/EPERM/超时与正确服务回复分开；正确 Type 仍未信任 |
| 5 秒内 PROBE 当轮 RemotePairing 候选 | `tcpConnected`、`greeting/result`、`wireVersion` | 若 TCP 可达而问候重置，失败卡在认证之前；系统明确原因需另获同意采集去标识化日志。不能凭 ECONNRESET 单独断定本机来源策略 |
| 若问候接受 | 停在这里 | 先选择认证路线与身份归属，再另获 Pair/Trust/PIN 授权。当前没有实现认证后端或 pairable-host 广播，不会自动开始配对 |

若没有 RemotePairing 广播但网络正常，下一候选是经明确授权实现 S3 上的 `_remotepairing-pairable-host._tcp` 监听/广播及受保护的 PhoneAgent 协议通道，由手机主动初配；不是猜端口或换成 QUIC。授权时需说明持久信任/凭据位置、哪些端点收发、PIN 仅在受控 UI 中展示，不能把现存 app-only 身份直接导出。

通过认证后才逐层实现并验证：TCP TLS-PSK/CDTunnel（记录协商出的 IPv6、MTU、RSD port，脱敏）→ RSD 动态服务表 → Developer Mode 和匹配 DDI → 单张 PNG 完整校验 → DisplayService 认证媒体会话/drain/安全停止 → 单次可逆输入和前后画面观察。真实截图和输入各需用户明确授权，说明目标与数据流；默认不进入模型、日志、Git 或云端。

Mac 可以作为构建/验证工具；验收最终独立运行时必须断开 Mac 的代理/隧道依赖并单独记录证据。PhoneAgent 后台运行、重启后的 DDI/信任恢复、USB Full Speed 媒体带宽、S3 SRAM/PSRAM/栈峰值也要分别验收。
