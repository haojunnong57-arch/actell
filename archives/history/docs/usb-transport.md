> 当前源码状态见 [v0.3 验证](validation.md)。本文早期阶段的未实现列表是历史记录；后续实现不等于硬件验收。

# v0.2：真实 USB 传输代码与验证边界

## 本轮的明确里程碑

把上一版只能生成协议字节的工程，推进到实际 ESP-IDF USB Host API、原始 Apple mux
连接状态机和只读 lockdownd QueryType 探测的组合。仍未连接实体板或 iPhone。
USB Host 是基于已成功 USB Mac 基线选择的实现候选；没有假定板子已经具备安全 VBUS。

实际固件路径：

ESP-IDF Host 枚举 → 当前配置的 FF/FE/02 bulk IN/OUT → Apple mux VERSION/SETUP →
逻辑端口 62078 的 SYN/SYNACK/ACK → framed XML QueryType → 严格回复校验 → RST/取消/清理。

代码不是发送给电脑 usbmuxd socket 的客户端。也没有伪装 USB 鼠标，没有生成配对凭证。

## 实现范围

### 原始 mux：bridge_usbmux.c

- v1/v2 VERSION；v2 SETUP
- 输出 magic FEEDFACE，输入 FACEFACE；字段使用显式大端字节编码
- 4 个可独立建连/释放的通道，每路 8 KiB 固定接收环
- SYN、SYNACK、ACK、RST；端口拒绝、断开、协议错误、超时
- 256 字节隐式窗口比例、背压、已经授予的接收窗口不能因取整而被撤销
- 分包/合包、重复/重叠数据抑制、序号回绕和重复 SYNACK 恢复
- 上限 65,536 字节的输入 frame、4,132 字节输出 packet
- 不做普通 IP TCP 重传；USB 本身提供有序可靠传输，异常立即终止
- close 使用 RST，不提供 FIN/半关闭；空闲开放通道和零窗口写操作由调用者设期限

四路通道是日后在同一 USB 上并行承载 CoreDeviceProxy 和自有 App 端口的基础，
不等于普通 iOS App 已经连通。当前未实现或运行 iOS App。

### ESP-IDF 适配：bridge_usb_host.c

- 真正调用 install、枚举过滤、打开设备、claim interface、bulk submit 和 completion API
- 一个 owner task 串行驱动 host-library/client 事件；USB 回调不阻塞、不递归调用 mux
- 2 × 4096 字节 RX DMA transfer，4 × 4132 字节 TX DMA transfer
- TX 复制到自己的有界队列后才返回已接受；队满明确背压
- 用 USB_TRANSFER_FLAG_ZERO_PACK 结束整条、恰好对齐端点最大包长的 mux packet
- 保留同步 bridge_io 适配，短读/短写会继续泵送真实 USB 事件，并遵守操作与运行期限
- 断线、短 TX、STALL/异步错误、超时均返回失败，不制造已连接状态
- 先取消/排空，再释放 DMA 内存；如果无法安全排空，保留相关内存并拒绝新 run，不能伪称恢复
- run generation 防止旧 stream 在堆地址复用后误接到下一次会话

### 只读探测：bridge_lockdown_probe.c

发送唯一请求：QueryType + 固定非识别性 Label。
最多接收 4096 字节；接受严格范围内的 XML/binary plist。
只在完整匹配 com.apple.mobile.lockdown、且无错误/重复/多余结构时返回成功。
不会执行 Pair、StartSession、StartService，不生成/读取/保存证书、私钥、设备唯一标识。

QueryType 成功最多证明这个服务能通过所建立的通道回复，不证明信任、TLS、DDI 或截图可用。

## 板级保护与已知限制

默认同时关闭 BRIDGE_USB_WIRING_CONFIRMED 与 BRIDGE_USB_HOST_ENABLE。
启动保护不是替代真实硬件核验：代码不能提供或验证 5 V、USB-C CC/数据角色、接口布线和防回灌。
没有设定任何未经确认的 VBUS 控制 GPIO，没有发送 Apple USB vendor-mode 切换请求。

必须从真实描述符确定包含 mux 的 bConfigurationValue；默认 1 只是初始配置值，
不代表它适用于这部 iPhone。缺少或歧义的 FF/FE/02 interface 直接失败。
只支持 Full Speed bulk MPS 8/16/32/64 与 alternate setting 0，未实现 SET_INTERFACE。

ESP-IDF 5.5.5 枚举器以 1..bNumConfigurations 索引处理配置，且会把越界值回退成 1。
本适配会先拒绝越界选择，避免默默改用其他配置；非连续配置值设备暂不支持。

运行期限覆盖工作阶段；清理的每个等待阶段另有 2 秒上限。用户 session callback 必须
通过有界 I/O 配合调度，代码无法抢占任意自定义阻塞函数。

## 主要源码依据

- [usbmuxd device.c](https://github.com/libimobiledevice/usbmuxd/blob/3ded00c9985a5108cfc7591a309f9a23d57a8cba/src/device.c)：原始 mux 与 pseudo-TCP 行为
- [usbmuxd usb.h](https://github.com/libimobiledevice/usbmuxd/blob/3ded00c9985a5108cfc7591a309f9a23d57a8cba/src/usb.h)：接口 tuple、USB 传输上限
- [usbmuxd usb.c](https://github.com/libimobiledevice/usbmuxd/blob/3ded00c9985a5108cfc7591a309f9a23d57a8cba/src/usb.c)：bulk 与 ZLP 行为
- [demuxusb 协议头](https://github.com/hack-different/demuxusb/blob/778f8cd0ffd1558be857c0d170ab5d8eacd89ba3/ext/usbmux.h)：输入 FACEFACE / 输出 FEEDFACE
- [ESP-IDF USB Host API](https://github.com/espressif/esp-idf/blob/b774170ff46c393eeb5e495ea37936038d3f4f4f/components/usb/include/usb/usb_host.h)
- [ESP-IDF transfer 定义](https://github.com/espressif/esp-idf/blob/b774170ff46c393eeb5e495ea37936038d3f4f4f/components/usb/include/usb/usb_types_stack.h)：ZERO_PACK 与异步传输所有权

usbmuxd 只写出 FEEDFACE、没有校验入站 magic。独立检查抓包分析器才确定 FACEFACE，
避免仅让实现和自造测试端互相符合而错过真实线协议。

## 仍然缺失

实体 Full Speed 枚举与 iOS27 兼容性、合法配对/TLS、CoreDeviceProxy、隧道内 IPv6/TCP/UDP、
RSD/HTTP2 实际会话、媒体流排空、真实 PNG/触控，以及手机与 App 的后台生命周期。
本轮不会把这些缺口用成功占位接口掩盖。
