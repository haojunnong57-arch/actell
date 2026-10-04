# N16R8 资源预算与性能边界

## 已知硬件上限

ESP32-S3：双核最高 240 MHz、512 KiB 片上 SRAM；所购 N16R8 标称 16 MiB Flash / 8 MiB PSRAM。
[S3 数据手册](https://www.espressif.com/sites/default/files/documentation/esp32-s3_datasheet_en.pdf)
和 [USB Host 官方文档](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-reference/peripherals/usb_host.html)
说明原生 USB OTG 为 Full Speed，原始速率上限 12 Mbit/s。
板上供电、VBUS 方向、接口连接、封装和 Flash 类型仍待确认。

Flash 容量不是可用 RAM。PSRAM 也不意味着所有 DMA/实时缓冲都可以放到外部 RAM。
[PSRAM 配置文档](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-guides/flash_psram_config.html)
要求按真实 Flash/PSRAM 模式配置，N16R8V 与 WROOM-1-N16R8 不应混用。

## 不应照搬的桌面参数

固定版本 pymobiledevice3 源码：

- RemoteXPC 的接收窗口为 16 MiB
- userspace TCP 接收窗口上限为 4 MiB
- touch_session 请求 1 MiB UDP 接收缓冲
- PNG 截图响应先完整接收，再解码 XPC 对象

窗口数字不全是即时分配，但仍不能当成 8 MiB 设备可直接沿用的配置。

## 建议架构（待验证，不是已经达到的占用）

- 截图保持压缩态，分块输出；不生成全屏 RGBA framebuffer
- 主逻辑一次只允许一张截图，支持取消、超时和丢弃未完成结果
- 限制 XPC 控制消息长度、嵌套层数、服务数量与 in-flight 请求数
- 用小型缓冲池处理 USB、隧道、TCP 和 RTP，不无限排队
- HID 只保留当前按键/触点状态，断线尽量 release，并明确失败
- RTP 收到即丢弃，不保存完整视频帧；仍需确保接收端持续有空闲
- 独立统计内部 SRAM 和 PSRAM 的最低剩余量/最大连续块

初始工程目标可以是 16 KiB 单包上限、8–32 KiB 控制消息上限、数个固定 packet slab，
但必须遵守协商结果。不能先声称这些限制兼容所有 iPhone。
本次 `bridge_plist_recv` 由调用者指定 scratch 和最大消息长度；组件自身不分配缓冲。
本次 bplist 和通用 XPC 解析器是完整内存视图，通用 XPC 默认上限 64 KiB。
另有 `bridge_xpc_extract_png` 专用流式路径，通过 256 字节 scratch + 有界递归状态
提取 XPC 内的大图。宿主机测试成功处理 9,441,044 字节合成 PNG；不是实际 iPhone 带宽测试。
输入必须先经已实现的有界 HTTP/2 分流，sink 字节在完整消息通过前都是临时结果。

## 数量级示例（算术上限，不是基准测试）

1179 × 2556 × 4 = 12,054,096 字节，约 11.50 MiB。仅一张这样大小的 RGBA 图
已经超过 8 MiB PSRAM；因此不应把“截屏”实现为全图解码缓冲。

即使假设一张压缩图仅 2 MiB，12 Mbit/s 原始链路的绝对下限也约为 1.40 秒；
真实 USB 帧/复用/TLS/隧道开销和并行媒体流只会增加时间。
PNG 实际大小取决于画面；这里不是固定大小、不是承诺帧率。

## 需要真实设备测量的项目

- Full Speed 枚举是否成功、USB endpoint 类型/最大包长
- 单次原始压缩截图的大小、耗时、重试率
- HID 必需媒体流的平均/峰值速率，丢包能否被容忍
- 长时间输入/截图并行时的内部 SRAM 与 PSRAM 水位
- 重连、系统锁屏、开发服务消失、DDI 失效后的行为

没有这些测量就不能给出可靠的最低 RAM、截图 FPS 或稳定性保证。

## 已有构建数字的适用范围

ESP-IDF 5.5.5 v0.1 诊断镜像历史 size 为 184,179 字节；v0.2 历史双配置大小见其归档；v0.3 最新大小见 validation.md。
它仅链接诊断用到的函数；其余组件完成交叉编译但未被当作连接栈运行。
USB/TLS/网络栈的动态池、媒体收包和真实负载不包含在这份数字里。

协议组件自身使用固定边界，但回调可能分配。媒体 offer 的 zlib9 调用必须独立预算
其工作区，不能把 serializer 的零 malloc 声明推广到压缩库或整个系统。


## v0.2 USB 层静态预算

Xtensa 编译对象确认 raw mux context 为 102,808 字节，分配于 PSRAM。
宿主机 ABI 下 sizeof 为 102,856 字节，不能直接当作 MCU ABI 大小。
其中已含四路8 KiB接收环、64 KiB重组缓冲与4132字节发送暂存。
Host适配的DMA数据区合计24,720字节，需内部可DMA内存；另有SDK transfer元数据、
控制器资源和Host运行状态。QueryType回复另用4096字节PSRAM。

这是有界实现预算，并非真实最低剩余堆。启用USB代码的编译镜像约240 KiB，
仍不包含配对/TLS、IPv6/CDTunnel、媒体会话的完整运行成本。


## v0.3 实现预算（静态边界，不是目标机水位）

Xtensa编译对象尺寸：rawmux102808字节，CDTunnel172字节，lockdown220字节，
RemoteXPC1288字节，pullresponse1112字节，RSD1408字节。
lwIP固定context在目标DWARF中为247248字节，宿主sizeof247336；包含四路16KiB TCP RX、
8个最大16000字节TX包、4路×4个2048字节UDP队列与收包/命令暂存。
rawmux/lwIPcontext明确从PSRAM分配，USB DMA仍需要内部可DMA内存。
RSD完整目录scratch最多64KiB，不复制个人属性；PNG分块输出不常驻整图。

zlib9每次请求字节硬上限384KiB（另有分配器metadata/栈）；宿主观测五次分配峰268112字节。
默认ESP分配只使用PSRAM，不回退内部RAM。压缩只处理最大384字节自身offerprotobuf，
不是网络接收数据的通用解压器。

TLS没有伪称全局硬堆上限：输入身份各8KiB、记录最多16KiB，仍有内部解析/密码分配。
宿主测试单/双TLS calloc payload峰60356/110996字节仅为特定fixture观测。
IDF配置记录缓冲为IN16384/OUT4096，使用内部allocator；不能把宿主数字直接映射到芯片。

IDF5.5.5/S3开启STDATOMIC_S32C1I_SPIRAM_WORKAROUND，由工具链禁用不安全的PSRAM硬件
原子指令路径。未来换SDK/编译器必须重新验证。lwIP另行pbuf/segment优先PSRAM分配，
失败可回退内部RAM；固定slot、窗口、OOSEQ和UDP上限仍不等于完整系统绝对内存上界。

静态预算显示该最小方案具有继续验证价值，但没有证明实际8MiB目标下稳态/峰值、
完整系统栈深度或摄像头/媒体冲突恢复。单独iOSApp、AppTLS和模型调用不在本固件预算内。
