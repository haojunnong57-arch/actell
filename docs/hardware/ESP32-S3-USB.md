# ESP32-S3 开发板 USB 接线、测量与 Host 扩展方案

记录日期：2026-10-04。电路分析、用户报告的测量与待组装方案分别记录；本文件不表示 iPhone 已接入或通过测试。

用户提供了[信路 ESP32S3 开发板资料页](https://www.xinlucity.com/?s=resourcedetail/index/id/61.html)。其附件中的[开发板原理图](xinlu-esp32s3-schematic.pdf)已按原文件保存，来源及 SHA-256 见实测摘要（本地文件 `../local-validation/esp32-bringup-summary.json`，已忽略）。用户另附的 `1783913303242785.pdf` 是 ESP32-S3 芯片数据手册，不能单独说明开发板的供电布线。以下电路结论来自原理图的逐线检查，用户报告的实物测量另列于下文。

ESP32-S3 本身支持 USB Host / Device，并有内置 PHY，作为 USB 主机不需要另加 USB Host 控制器。[ESP-IDF v5.5.5 Host 驱动](https://docs.espressif.com/projects/esp-idf/en/v5.5.5/esp32s3/api-reference/peripherals/usb_host.html)可在初始化时选择内部 PHY 和 Host 模式。芯片资料中的 `USB_SERIAL_JTAG_DP/DM_PULLUP` 控制的是 GPIO20/19 上的 **D+/D- 数据线**上拉，不是 Type-C 插座 **CC1/CC2** 的 Rp/Rd；修改这些寄存器不会改变图中 R16/R17 的固定接法。“自带主机控制器”和“本板可用普通 C-to-C 线直接枚举 USB-C iPhone”是两个需要分别确认的问题，不应把后者的接线限制说成 S3 不支持 Host。

| 图中位置 | 电路与用途 | 对下一步的影响 |
| --- | --- | --- |
| USB2 / USB-ISP，对应 COM | D+/D- 接 CH340C；接口 VBUS 经 D3 进入板上 5V | 继续用作 Mac 烧录和 UART 日志通道 |
| USB1 / USB-OTG，对应 USB | D+ 接 GPIO20，D- 接 GPIO19；CC2/R16、CC1/R17 各以 5.1 kΩ 接地 | 原生数据通道可由 S3 控制，但连接器按固定受电端配置 |
| D1 与 J4 | 原生 USB 的 VBUS 经 D1 向板上 5V 供电；J4 并联在 D1 两端 | 短接 J4 可绕过二极管，**不会改变 CC 角色**；背面 USB-OTG 焊盘已报告两端低阻连通，COM 单独供电时两端各为 4.95 V；实物焊盘与 J4、接口 VBUS 的对应仍待直接确认 |
| D2 与 J1 | 排针 H1 的 21 脚经 D2 接入 COM 的 VBUS；J1 并联在 D2 两端 | 与 5V-IN / IN-OUT 输出有关，不能当作 J4 使用 |

根据 [TI USB-C 说明的 source/sink 电路章节](https://www.ti.com/lit/pdf/slyy228)，两个 CC 下拉 Rd 表示受电端，供电端需要 Rp 及相应供电控制。**据此推断，这块板不能仅靠打开 Host 配置、短接 USB-OTG 焊盘，再用普通 C-to-C 线，就实现我们需要的 S3 Host → USB-C iPhone Device 接法。** 原理图也未画出 Host VBUS 限流开关；实际供电能力与负载电压尚未测量。

2026-10-04 用户实物测量补充：目标 iPhone 为 USB-C，万用表无二极管档，改用断电电阻测量。用户报告表笔互碰、USB-OTG 焊盘 A→B、交换表笔后 B→A 三次读数均为 1.7 Ω。两方向均等于表笔短接基线，说明两焊盘间在该表分辨率内已有低阻通路；不能据此判断是内部铜箔、焊锡或其他并联路径。用户随后按只接 COM 供电、原生 USB 留空的测量安排，报告 A/B 各自对 GND 均为 4.95 V。该结果确认两个被测焊盘节点均带电，与二极管被低阻路径旁路的情况一致，但没有直接测量接口 VBUS，也未验证 CC 角色、反向电流保护或负载供电能力。无需再短接该焊盘，暂不采用 COM 接电脑供电同时原生 USB 接 iPhone 的接法。读数为用户报告，并非自动采集；见实测摘要（本地文件 `../local-validation/esp32-bringup-summary.json`，已忽略）中的 `user_reported_board_measurements`。

厂家资料页的 Type-C 介绍图片确实写有“需要短接 OTG 焊盘才能使用”。图纸中 J4 只旁路供电二极管，D+/D- 和 CC 不经过 J4；若实物完整采用图中 D1 电路，J4 断开时也应存在 USB 向板上供电的路径。因此，此前只接原生 USB 时亮灯、运行或烧录成功，均不能证明 J4 已短接。厂家这句说明的具体适用条件与实物装配版本尚未确认，不能据此把 J4 当作下载模式开关，或把下载成功当作连接 iPhone 的电气安全验证。

测量证据的边界：COM 单独供电时两端均为 4.95 V 是高阻电压表的空载读数，单独不能证明 J4 短接或接口具有向外供电能力；反向漏电及其他板上路径可能影响空载电位。目前支持低阻旁路判断的主要证据，是断电后双向电阻均等于表笔短接基线，前提是量程单位确为 Ω 且两支表笔分别接触不同焊盘。板上测量仍不能区分 J4 焊锡、内部铜箔或其他并联路径，尚未确认 J4 本身的物理短接状态。

本会话选择继续研究的方案是从 GPIO19/20/GND 引出外部 USB-A 母口，并从单独的受保护 5V 支路供电，详见下文；组装和测量通过后才启用有时限的枚举 / 只读 QueryType 测试。当前不用短接焊盘或把 iPhone 接入板上 USB 口。若采用外接 Hub，还需验证上行口供电隔离，并配置和测试 Hub 支持；当前构建的 `CONFIG_USB_HOST_HUBS_SUPPORTED` 关闭，不能假设插上 Hub 即可工作。

启用 Host 后应保留 COM 日志：S3 的 USB-OTG 与 USB Serial/JTAG 共用内部 PHY，不能期待原生 USB 同时维持当前调试功能，见[乐鑫 USB 说明](https://docs.espressif.com/projects/esp-usb/en/latest/esp32s3/usb_device.html#external-phy-configuration)。

## Host、Device 与供电角色

- 若 ESP32 模拟 USB 鼠标，ESP32 是 Device，iPhone 是 Host；这与本项目拟由 ESP32 主动枚举 iPhone 的 Host 路线不同。当前诊断固件并不是 USB 鼠标固件。
- GPIO19/20 是原生 USB D-/D+；COM 口的数据经过 CH340C 转 UART。原生接口由 `USB_SERIAL_JTAG` 控制器使用时，名字中的“串口”也不意味着板上的 COM 接口。
- 普通 C-to-C 连接的初始角色由 CC 电路决定。板上固定 Rd 会让板子呈现受电端及初始 Device 角色；COM 提供电源不会把 Rd 改成 Rp。这是 USB-C 接口规则，不是 iPhone 独有的限制。
- 常规 Host 同时作为供电端，在连接器 VBUS 提供受控 5V。仅启用 ESP32 Host 软件不能让 iPhone 自动从 Host 变为 Device。
- 想让 ESP32 保持数据 Host、同时从 iPhone 取电，涉及电源/数据角色分离、PD 角色交换和对端支持；本板固定电阻加软件 Host 不足以实现，也未验证 iPhone 会接受。
- ESP32 作为 Device 且仅由手机供电，可以避免 COM 与手机两路供电同时接入的问题；这并不等同于整块板及连接线已经完成电气验证。

上述角色依据见[乐鑫 USB-C 硬件设计指南](https://docs.espressif.com/projects/esp-iot-solution/zh_CN/latest/usb/usb_overview/usb_typec_hardware_guide.html)。芯片内数据线上拉、GPIO 弱上拉以及 JTAG eFuse 都不是 CC 角色控制器；本流程无需修改 eFuse。

## 外接 USB-A Host 原型

状态：2026-10-04 已讨论方案并核对以下商品资料，尚未购买、组装、负载测试或连接 iPhone。数据仍由 ESP32-S3 内置 OTG 处理，外部接口与供电模块不实现 iPhone 协议。

```text
ESP32 GPIO20 -------------------- USB-A 母口 D+
ESP32 GPIO19 -------------------- USB-A 母口 D-
ESP32 GND ---------+------------- USB-A 母口 GND
                   +------------- 电源模块 GND

可靠的 5V 电源 -> 限流/防倒灌模块 OUT -> USB-A 母口 VBUS
USB-A 母口 -> 合规 A-to-C 数据线 -> iPhone USB-C

首轮调试：COM -> Mac（板子供电与日志）；板载原生 USB 口留空。
外接 5V 不与 ESP32 板上 5V 或 3V3 并接；两支路共地。
```

USB-A 母口接合规 A-to-C 数据线可提供传统主机接口的连接方式；不能用一个普通 C 公口转 A 母口转接头，就假设原板的固定 Rd 已变成 Host。数据引线应短、成对走线，避免长杜邦线和面包板绕线；最终信号质量仍需实际枚举验证。

### 配件清单与选择依据

以下价格是检索当时的官网美元标价，不含运费/税，不表示国内现货或已下单。

| 配件 | 数量 | 候选与边界 |
| --- | --- | --- |
| USB-A 母口引出件 | 1 | [Adafruit 4449](https://www.adafruit.com/product/4449)，30cm、四根杜邦母头，$1.95；或 [SparkFun BOB-12700](https://www.sparkfun.com/sparkfun-usb-type-a-female-breakout.html) 接口小板，需焊排针。只负责引出 VBUS、D-、D+、GND，不自带限流 |
| 电源限流/防倒灌模块 | 1 | [Pololu 2596 / TPS2113A](https://www.pololu.com/product/2596)，$9.95，输入 2.8–5.5V，默认限流标称 0.5A，可调整。附带排针未焊；这是电源切换模块，可利用其单路输入与 OUT 做原型保护，不是稳压器 |
| USB-A 公口到 USB-C 公口数据线 | 1 | 例如[绿联 60116，1m](https://nz.ugreen.com/products/ugreen-usb-a-2-0-to-usb-c-cable-nickel-plating-1m-black)，明确支持 USB 2.0 数据；已有合规数据线可复用 |
| 5V 电源与 Micro-USB 供电线 | 各 1 | 可复用可靠 5V USB 充电器，建议 2A 输出能力留余量。Micro-USB 接 Pololu 模块供电入口；不使用高压诱骗输出。电源额定 2A 不表示强制向手机输送 2A |
| 短导线、排针、绝缘固定材料 | 少量 | 2.54mm 母对母，优先 5–10cm；接插件需牢固。购买已焊排针或代焊服务，避免把未焊的针插在孔里当作可靠连接 |
| USB-A VBUS 缓冲电容 | 1 | 150–220µF、耐压至少 10V，靠近外接接口接在 VBUS 与 GND 之间，注意极性；实际布局/容量随最终模块核对 |
| 测试用 USB 有线鼠标 | 可复用 1 个 | 先测普通 USB 设备枚举，再接 iPhone；万用表已有，不必重复购买 |

Pololu 模块的 **`OUT` 才是受保护输出**；其标为 `VBUS` 的脚是 Micro-USB 输入网，若用它供给外接 USB-A 会绕过保护。这里只使用一个输入，不同时给默认相连的 Micro-USB VBUS 与 IN1 接两个电源。默认 0.5A 为标称限流，厂家说明存在较大阈值偏差；不能把它当成精确 500mA 或已证明适合 iPhone。先做电压与负载测试，不能因手机掉线就盲目调大限流。详见[模块引脚、限流与原理图](https://www.pololu.com/product/2596)。

备用成品参考：[TI TPS2553DBV1EVM-364](https://www.ti.com/tool/TPS2553DBV1EVM-364)，板上跳线可选 0.5A/1A 限流、接线端子及输出电容；价格/国内供货未确认。其[参考设计](https://www.ti.com/lit/pdf/SLUU339)使用 150µF 输出电容，不能把只有裸芯片的 TPS2553/CH217 商品当成成品模块。

国内检索入口：[立创 Pololu 2596 / C17529553](https://item.szlcsc.com/18658764.html)、[DigiKey 中文商品页](https://www.digikey.cn/zh/products/detail/pololu/2596/10450599)。接口搜索词：`USB-A 母座 转 DIP 4P 已焊排针`、`USB-A 母口 转 杜邦母头 四线`。这些是选型入口，国内实时库存、运费及到货时间未确认。无需购买 MAX3421E Host Shield、CH375/CH376 控制器或 PD 诱骗板来实现此方案。

## 后续验收

1. 确定实物模块版本、焊好排针并核对四线标识；保留外接模块的规格和接线照片。
2. 不接手机，检查断电接线、VBUS 极性、空载及负载下电压、限流行为与回灌路径。万用表电压读数不能代替负载测试。
3. 使用 COM 编译/烧录并看日志；接线确认后再启用 Host，先测普通鼠标枚举。当前固件 Host 与 Hub 支持均未开启。
4. 普通设备通过后，使用 A-to-C 数据线测试 iPhone 枚举与有时限的只读 QueryType。结果单独记录；成功枚举不等于已配对、截图或触控。
5. 之后再按身份配置、服务发现、截图、可逆输入的顺序验证，避免将 Mac 历史成功基线误记为 ESP32 成功。
