# PA1 本地 USB TCP 协议

ASCII，单行 LF 结束；最多 256 字节/行。端口 28766，服务端仅绑定 192.168.7.1。参数使用无前导零的非负十进制整数。大小写与空格必须精确。签名为小写 64 hex 字符的 HMAC-SHA256。`K` 为 32 字节 PSK，`N` 为每连接 32 字节随机数的 64 hex 表示。

```text
S -> C: PA1 CHALLENGE N\n
C -> S: PA1 AUTH HMAC(K, "auth|" + N)\n
S -> C: READY H HMAC(K, "server|" + N + "|READY " + H)\n
```

`H=0` 仅 NCM、`H=1` 包含 HID。App 验证 READY 签名后才认定设备身份。无 PSK 时只返回 `PA1 LOCKED\n`，然后关闭。认证等待 3 秒。随机数由 S3 硬件熵源短时启用产生，不启用无线；本项目没有与其冲突的 ADC/I2S 功能。

命令正文 `P` 与 ACK 正文 `A`：

```text
C -> S: P HMAC(K, "client|" + N + "|" + P)\n
S -> C: A HMAC(K, "server|" + N + "|" + A)\n
```

| P | 条件 | A |
| --- | --- | --- |
| `id PING` | 认证有效 | `id executed`，仅表示协议往返/续租 |
| `id TAP x y` | HID 就绪、750 ms 内有 PING、无另一输入 | `id received` → `id executed` |
| `id DRAG x y tx ty duration` | 同上，100…2000 ms | `id received` → `id executed` |
| `id STOP` | 认证有效 | 释放完成后 `id executed`，并关闭连接 |

`id` 范围 1…4294967295，坐标 0…65535，基于已经旋转到显示方向的图像；画面 ID 不传给 S3，由 iOS ActionCoordinator + USBDeviceBridge 校验。固件不能证明人的批准或核实屏幕内容，它信任持有 PSK 的客户端。因此不要把 PSK 共享给其他应用或自动化控制者。

两种 ACK 必须关联原 id 并验签。tap/drag 的 executed 不得先于 received。App 一次只发送一个输入；并发 PING 使用独立 id。输入不自动重试，丢失 executed 的结果标为未知并停止。设备按 session 保留有界去重记录，不跨断电/重连恢复动作；新 challenge 使旧签名无效。

无认证命令、签名不符、非 ASCII/超长行、越界参数、重复冲突、过期 id、HID 未启用、操作忙、缺少心跳：立即关闭并释放，不把拒绝伪装成 executed。32 条缓存不会逐出尚未完成的输入。非活动会话 60 秒关闭。

received 表示已接受且尚未完成 USB 报告序列；executed 表示该序列的最终鼠标释放报告 transfer completion 已到达。无法证明 iOS 已改变界面，因此 Agent 必须读取 ACK 后到达的新帧。STOP 还发送键盘全零报告。

TCP 未加密，不支持发现、自动重连、队列恢复、多客户端控制或任意二进制 payload。loopback 测试使用公开测试密钥与 CommonCrypto 替代 mbedTLS，仅替换平台/USB 层；生产解析、认证流程、socket 状态机、幂等表和 HID 时序代码直接参与测试。它不模拟 USB 总线驱动。
