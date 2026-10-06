> 当前源码已升级为 [PA3 常连](../../../../docs/usb-device/PERSISTENT-USB.md)：停止任务释放 HID 并保留 TCP，App 与固件必须同时更新。本文 PA1/PA2 构建、烧录和测试结果是历史记录；PA3 已完成 COM 烧录和启动检查，iPhone 端仍待验收，见该升级说明。

# NCM+HID 烧录与联调 · 2026-10-04

状态：**23:03（Asia/Shanghai）已完成 NCM+HID COM 烧录、三段设备摘要校验和 UART 启动检查。** 用户明确确认“现在只有 COM 接 Mac，原生 USB 已断开，并同意烧录这版 NCM+HID”。真实 iPhone HID 枚举、输入和 Agent 闭环尚未验证。此前用户已确认 NCM-only 双向 PING及最新版 App 本机截图预览正常。

后续用户报告点击进入只读截图通道。App 已修复短暂 inactive 误关空闲 USB 的路径并补足路由/断开原因日志，147 项单元、1 项 UI 和 iPhoneOS 构建通过，待重装复测；尚不能确定用户该次断开的具体触发。固件无需重刷，详见 [App 输入路由修正](NO-PSK.md#hid-点击入口与空闲连接修正--2026-10-04)。

后续 App 已按用户要求改为任务开始授权普通 USB 动作，移除逐动作回前台确认与后台 60 秒/总计 5 分钟策略。此次只需更新 App，固件仍为下面已烧录版本，详见 [当前行为与验证](CONTINUOUS-RUNS.md)。

## 本次实际烧录

- 当前目标与此前 NCM-only 烧录为同一块 ESP32-S3 rev v0.2、16 MB Flash；通过 COM 识别并在本地比较设备身份，未将硬件标识写入仓库。
- 使用下表冻结镜像，57600、ROM `--no-stub --no-compress`，从 23:01:43 至 23:03:05 完成写入。esptool exit 0，三段均报告 `Hash of data verified.`，随后硬复位；本次没有传输重试或中断。
- ROM 按块补齐后实际传输字节数为 bootloader 21504、分区表 3072、App 357376；仍在下表注明的扇区范围内。未读回备份、整片擦除、写 NVS/PHY 或修改 eFuse。
- UART 115200 观察 15 秒，TinyUSB 驱动启动，服务报告 `NCM + HID; 192.168.7.1:28766; PA2 no PSK; no radio/DHCP/default route`。启动 ELF 摘要 `ca37a9600...` 与冻结 ELF 匹配；服务启动行出现一次，未观察到 panic、abort 或 brownout。
- 监视器 exit 0，随后 `lsof` 确认 COM/TTY 无打开进程，可以断开 COM 再接 iPhone。观察范围仅限本次 15 秒，不能代替长时间稳定性或真实 USB 验收。

执行记录与原始日志位于 Git 忽略的 `.build/device-flashes/pa2-hid-20261004-1hmhoa8c/`：`flash-review.json` 状态为 `flashed_com_startup_verified`，另有 `identify.log`、`flash.log`、`runtime.log`、`monitor-control.log` 及所用候选副本。没有调用模型或向手机发送 HID 输入；本机签名配置与烧录前摘要一致。代码仍在 `with-esp/main`、基线 `dfa3d2d` 加下述未提交修复，本次未提交、推送或合并。

## 本轮修复与验证

烧录前准备工作位于 `with-esp`，分支 `main`，基线 `dfa3d2d`。只修改固件 STOP 接收逻辑、对应测试及说明；用户已有 Xcode 签名配置未动。以下为准备阶段验证，串口烧录结果见上节。

此前 TCP 一次收到多条命令时，后来的 STOP 会覆盖首个 STOP 的回执 ID 并重新开始释放；相同 ID 的重复 STOP 还会错误返回 received。现在首个有效 STOP 固定其 ID 和 500 ms 释放期限，直到中性报告完成前不再接收/解析后续命令；释放完成返回该 ID 的 executed 并断开，超时关闭且不报成功。协议细节见 [PROTOCOL.md](../../../../docs/usb-device/PROTOCOL.md)。

- 新增四项回归，在旧实现全部失败：不同 ID 连续 STOP、相同 ID 重复 STOP、STOP 后的 PING/TAP、NCM-only 连续 STOP。修复后 18 项生产 C server localhost TCP 测试全部通过。
- 严格 C 编译及 ASan/UBSan 下，协议解析/去重、点击拖动释放顺序、取消和超时检查通过。USB 平台层为夹具，不代表真实总线传输通过。
- NCM-only 与 NCM+HID 两个配置实际构建成功；ELF 描述符检查通过。HID 版为 3 个接口，端点 `0x81/0x82/0x02/0x83`，报告 ID 1 为绝对鼠标、2 用于键盘释放。不支持任意文字输入。
- build graph 无 Wi-Fi/BLE，DHCP、IP 转发均关闭，未增加调试 CDC。USB 描述符声明总线供电 100 mA；未测量真实电流或浪涌。

沿用本机 ESP-IDF 5.5.5（`b774170ff46c393eeb5e495ea37936038d3f4f4f`）、Xtensa GCC 14.2.0（esp-14.2.0_20260121）、Python 3.12.13、esptool 4.12.0；锁定 esp_tinyusb 2.2.0、TinyUSB 0.21.0~2。未安装或更新依赖。App 本轮未改，最近验证为 143 项单元测试、1 项 UI 测试和 iPhoneOS 27 无签名构建通过，详见 [VALIDATION.md](VALIDATION.md)。

本地日志均被 Git 忽略：`.build/validation/hid-readiness/` 下的 `stop-before.log`、`stop-after.log`、`build-hid-approved.log`、`build-ncm.log`、`descriptor-verification.log`。首次 HID 构建在沙箱中因 CMake 查询主机信息权限失败；批准 build-only 重试后通过，没有设备操作。

## 冻结候选及写入范围

候选目录 `.build/device-candidates/pa2-ncm-hid-stopfix-20261004/`，保存三段镜像、ELF、SDK 配置、依赖锁文件、源码 patch、源码摘要、描述符核对结果和 `flash-review.json`。原始候选清单保留 `prepared_not_flashed` 准备状态；后续授权及执行结果以本页上方执行目录的清单为准。全量源码以基线提交加固件 patch 追溯；版本字符串不能代替下列镜像摘要。

| 文件 | 写入偏移 | 字节数 | SHA-256 |
| --- | --- | --- | --- |
| bootloader.bin | `0x0` | 20832 | `ed060c274ee6d9ee3f31dbc8bdd148491daee270b2535a438ea3983c2853354f` |
| partition-table.bin | `0x8000` | 3072 | `7f00b6c042a89b15b0cac534f82ed988caf29278ff5700b0c511eb1b5bb7c820` |
| phoneagent_usb_device.bin | `0x10000` | 357088 | `19618983de0cc09abb4b71200fff7afa792c6e2f6e0ef7885101a186b2e13acf` |

三段扇区擦除范围分别为 `[0x0,0x6000)`、`[0x8000,0x9000)`、`[0x10000,0x68000)`。分区表与此前已烧录 PA2 NCM-only 相同；bootloader 是本次 HID 构建产物，摘要与旧包不同，不假定可以互换。实际使用本次配套三段镜像，保留 NVS `[0x9000,0xf000)` 和 PHY `[0xf000,0x10000)`，不整片擦除、不配置 PSK、不操作 eFuse。

本次沿用此前成功的 COM 流程：ESP32-S3、16 MB、DIO/80 MHz，57600 波特率，ROM `--no-stub`、写入 `--no-compress`，之后设备摘要核对及 UART 启动检查。生成的通用构建提示使用 460800/stub，不作为本板执行方案。按用户约定，不重新读回备份可由源码重建的工程固件；保留原 NCM-only 候选供恢复。

## 真机步骤与验收标准

1. 已完成：用户确认仅 COM 接 Mac、原生 USB 断开并明确批准本次 NCM+HID 烧录；设备写入及启动检查已通过。
2. 烧录并完成设备校验、启动检查后，断开 COM，再将原生 USB 接 iPhone。HID 版 USB PID 为 `0x4006`，此前 NCM-only 为 `0x4002`；系统可能建立新的以太网服务，需要重新核对固定 IP `192.168.7.2 / 255.255.255.0`，路由器和 DNS 留空。
3. 在前台连接 USB NCM，目标文案为“USB NCM + HID 已连接（免 PSK）；开始任务后可自动执行点击和拖动”，诊断 greeting 为 `PA2 READY 1`。该状态包含双向 PING；H=1 是固件能力声明，不能单独证明 HID 被 iOS 接受。
4. 由用户打开“设置 → 辅助功能 → 触控 → 辅助触控”，检查指针设备。参考 [Apple 指针设备说明](https://support.apple.com/en-us/111775)。在无害页面先测试一次点击，再测试拖动和方向映射；需要看到实际界面响应，executed ACK 本身不是视觉成功。
5. 开启系统全屏采集并确认预览正常。开始 Agent 任务后切到目标 App，验证“最新截图 → 任务内授权 → HID 输入 → executed → 更新截图”，无需逐次返回 PhoneAgent。首次选择无敏感信息、无外部提交行为的页面；由用户主动开始任务，模型截图上传按现有设置执行。随后验证停止、拔线/锁屏释放、采集丢失和过期画面立即停止。

仍未验证：真实 HID 枚举和坐标映射、NCM/HID 并发、停止/断连释放、旋转、USB 休眠恢复、蜂窝及既有 VPN 共存、真实供电、持续稳定性及后台 Agent 闭环。本机预览成功只证明已取得可显示画面，不替代这些验收。
