# v0.3 验证状态

验证日期：2026-10-02 UTC，dot 云端。没有连接实体 ESP32/iPhone、没有刷机、没有真实配对身份。

## 本轮验证分层

| 层 | 已执行的证据 | 不代表 |
|---|---|---|
| lockdown | 111 XML/binary fixtures、50,000 变异、192 分片会话；真实状态机与 plistlib 对端 | 已经配对手机 |
| TLS | 实际 mbedTLS 与独立 OpenSSL；双向测试证书校验、两条同时存在的 TLS、完整 StartSession/StartService/StopSession | iPhone 证书或密码套件兼容 |
| CDTunnel | 105 fixtures、>7,000 变异、短 I/O/截止时间、40～16000 字节 IPv6 分包 | 手机隧道可用 |
| lwIP | 真实 NO_SYS=0 栈、真实 TCP 定时器/SYN/ACK/校验和；18 组 ASan/UBSan 与 TSan | ESP32 运行时或实际吞吐 |
| RemoteXPC | 上游握手 AST/hyperframe 字节对照、窗口/分片/跨流/控制帧/ID；9,480,493 字节有效合成 PNG 流式接收 | 从手机抓到图片 |
| RSD | 上游现代握手对照，1～31 字节分片，四服务表，UNKNOWN/拒绝能力状态，精确64 KiB边界 | DDI 服务在目标机存在 |
| zlib9 | 1,155 输入对照、265 完整 offer、5,000 fuzz、分配/预算/并发、ESP allocator shim | 手机接受媒体 offer |
| 组合/操作 | USB-CoreDevice 23 组边界、网络绑定生命周期、截图/Home真实应用协议调用 | 单一测试覆盖完整实物链路 |

TLS 测试包含错误 pin、无认证输入、严格完整 PEM/DER（隐藏拼接对象也拒绝）、OOM、过期/慢速截止时间、
EOF、警报、明文、超长记录、TLS1.1/1.3不兼容、篡改记录，以及对端验证客户端证书。
公开测试身份只从单独的官方源码目录读取，没有放入固件或本归档。

lwIP 18组测试覆盖乱序、重传、FIN/RST、零窗口重开、UDP边界与丢弃、generation复用、ACK drain、
队满、回调中清理、mailbox满、发送/RX环、池/堆/netif恢复。IPv6分片和ND6路由控制输入被拒绝；
目标profile不依赖全局重组或邻居路由状态。TSan使用宿主Unix端口的互斥shim，实际lwIP核心未改写。

## 审查中发现并修复

- 临时解析变量和最终超时路径的 SessionID 副本擦除
- 证书/私钥 PEM/DER 尾随对象或隐藏拼接输入的完整消耗验证
- pull response 已挂接时禁止额外 send/pump，避免有界队列被二次推进
- 无ID限定回复跳过控制wrapper；支持关联payload在root/reply任一流到达
- IPv6片段不进入会跨netif生命周期的全局重组缓存；ND6输入不改变全局路由状态
- 已投递命令超时后的不确定开流/写入状态会停止net
- 重复 network start 不丢失活跃/待清理指针；Home按住期间不解析可能阻塞的RSD消息

## 回归与工具

保留 v0.2 全部 raw mux、USB Host生命周期/真实协议组合、QueryType、描述符与v0.1协议回归。
固定上游 Python oracle 在执行前校验 SHA-256。完整最终输出：`docs/test-results.txt`；构建摘要：`docs/build-results.txt`。

```sh
. /path/to/esp-idf/export.sh
PYTHON=/path/to/venv/bin/python ./tools/test_all.sh
SANITIZE=thread ./tools/test_lwip.sh
```

ASan/UBSan通过。LSan退出扫描在当前ptrace执行环境不支持；使用显式分配平衡与lwIP资源基线恢复。
这不是把未运行的LSan宣称通过。独立审查另以131,000组输入对照系统inet_pton检查IPv6解析。

## ESP32-S3 构建

- ESP-IDF v5.5.5：b774170ff46c393eeb5e495ea37936038d3f4f4f
- Xtensa：esp-14.2.0_20260121
- 默认安全配置：size 447895 字节，bin 448016 字节
- USB启用的仅编译配置：size 465127 字节，bin 465248 字节
- 两种配置都链接真实会话/TLS/网络/压缩代码；默认只运行缺配置拒绝检查与合成离线自测
- 没有在目标芯片执行这些路径，也没有把镜像大小当作动态RAM预算

USB仅编译配置中的配置值4、wiring确认位是编译测试值，不是开发板确认，不可直接刷入。
候选N16R8配置、PSRAM原子访问workaround、lwIP窗口/OOSEQ/重组上限保留在sdkconfig.defaults。
已启用lwIP优先PSRAM分配；分配失败可回退内部RAM，所以仍须测内部水位。

## 明确未完成

首次信任/配对与安全身份配置、真实USB/VBUS/Full Speed兼容、真实TLS pin呈现、整机截图/Home效果、
媒体流token识别与自动触控启停、持续媒体负载、键盘文本修复、App通道、硬件重连与RAM峰值。
DDI下载/安装器不在本阶段。实体测试全部为NOT RUN，Apple互操作性UNVERIFIED。
