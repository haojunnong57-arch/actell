# PA2 本地 USB TCP 协议（免 PSK）

2026-10-04 用户选择 USB 免 PSK，并接受可访问 USB 网络的其他程序也能发命令。PA2 不认证设备或客户端身份，不验签、不加密；不提供跨连接的密码学防重放。App 不读取桥接 Keychain，设备不访问 `pa_usb/psk`，无默认密钥、NVS 配置、eFuse 写入或安全启动设置。旧 Host TLS PSK 与模型 API key 独立保留。

ASCII，单行 LF 结束；接收缓冲上限 256 字节、命令正文上限 128 字节。端口 28766，服务端仅绑定 192.168.7.1。App 按本地 `192.168.7.2/24` 查找唯一符合链路条件的接口，校验名称、索引及类型后，通过 `requiredInterface` 和 `requiredLocalEndpoint` 绑定；不回退到无线或无绑定连接，详见 [接口绑定验证](NO-PSK.md#vpn-对比与具体接口绑定--2026-10-04)。参数使用无前导零的非负十进制整数。大小写与空格必须精确。

```text
S -> C: PA2 READY H\n
C -> S: 1 PING\n
S -> C: 1 executed\n
```

`H=0` 仅 NCM、`H=1` 包含 HID。客户端等待 greeting 最多 3 秒，再用 PING 验证双向收发。READY 只是对端自报能力，不能证明身份。App 与固件需同时更新；旧 `PA1 LOCKED` / `PA1 CHALLENGE` greeting 会明确报协议不匹配，设备拒绝旧 AUTH 和带签名的命令，不自动兼容或回退。

命令正文与 ACK 均直接以 LF 结束，没有签名字段：

| 命令 | 条件 | ACK |
| --- | --- | --- |
| `id PING` | TCP 已连接 | `id executed`，仅表示协议往返/续租 |
| `id TAP x y` | HID 就绪、750 ms 内有 PING、无另一输入 | `id received` → `id executed` |
| `id DRAG x y tx ty duration` | 同上，100…2000 ms | `id received` → `id executed` |
| `id STOP` | TCP 已连接 | 释放完成后 `id executed`，并关闭连接 |

`id` 范围 1…4294967295，坐标 0…65535，基于已经旋转到显示方向的图像；画面 ID 不传给 S3，由 iOS ActionCoordinator + USBDeviceBridge 校验。本 App 仍逐动作批准并核实画面；其他客户端可以直接调用设备协议，固件无法证明人工批准或屏幕内容。免 PSK 不取消 iOS 本地网络和全屏采集系统权限。

两种 ACK 必须严格解析并关联原 id。tap/drag 的 executed 不得先于 received。App 一次只发送一个输入；并发 PING 使用独立 id。输入不自动重试，丢失 executed 的结果标为未知并停止。设备按 TCP session 保留有界去重记录；相同 id/参数返回已有阶段，冲突或过期 id 关闭连接。重连从空记录开始，不自动恢复旧动作；其他程序仍可在新连接重新发送相同明文命令。

非 ASCII/超长行、格式错误、越界参数、重复冲突、过期 id、HID 未启用、操作忙、缺少心跳：立即关闭并释放，不把拒绝伪装成 executed。32 条缓存不会逐出尚未完成的输入。每条新连接首次输入前必须先 PING；动作期间 PING 间隔超过 750 ms 撤销，动作总时限 2500 ms。非活动会话 60 秒关闭。

received 表示已接受且尚未完成 USB 报告序列；executed 表示该序列的最终鼠标释放报告 transfer completion 已到达。无法证明 iOS 已改变界面，因此 Agent 必须读取 ACK 后到达的新帧。STOP 还发送键盘全零报告。

不支持发现、自动重连、队列恢复、多客户端控制或任意二进制 payload。loopback 测试仅替换平台/USB 层；生产解析、socket 状态机、幂等表和 HID 时序代码直接参与测试，没有凭据夹具，不模拟 USB 总线驱动。

已知限制：此前审计发现连续不同 id 的 STOP 可能覆盖待回执的 STOP id；本次免 PSK 变更没有修复该问题。单 STOP 释放/终止已测，重复 STOP 竞争仍需在 HID 真机验收前单独修复和回归。
