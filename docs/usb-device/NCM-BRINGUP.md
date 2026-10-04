> 当前源码已升级为 [PA3 常连](PERSISTENT-USB.md)：停止任务释放 HID 并保留 TCP，App 与固件必须同时更新。本文 PA1/PA2 构建、烧录和测试结果是历史记录；PA3 已完成 COM 烧录和启动检查，iPhone 端仍待验收，见该升级说明。

# NCM-only 首次 COM 烧录 · 2026-10-04

18:47（Asia/Shanghai）完成烧录。用户已确认仅 COM 接 Mac、原生 USB 口留空，并明确批准替换当前诊断固件为准备好的 NCM-only 镜像。烧录阶段没有连接 iPhone，没有烧录 HID、配置 PSK或修改 App 签名。随后用户报告 iPhone 设置中已出现以太网接口，枚举识别获得用户侧确认。

## 结果

- 目标：ESP32-S3 rev v0.2，探测 Flash 16 MB；`/dev/cu.usbserial-<port>`，115200 波特率。
- 源码：`with-esp/main`，HEAD `883d0e8e61e62b2c9db3361985dc43c9db45ed9a`，`firmware-device` 无未提交修改。用户现有 Xcode 工程和本地化修改保持原状。
- 本机 ESP-IDF 5.5.5 构建成功；ELF 描述符核对通过：NCM、两个接口、三个端点、HID 关闭，未链接 Wi-Fi/BLE；DHCP、转发关闭。
- bootloader、分区表、App 三段写入均通过 esptool 的设备端摘要校验，没有执行全片擦除或写入 NVS 镜像。
- 15 秒 UART 观察中，TinyUSB 驱动安装成功，服务报告 `NCM only; 192.168.7.1:28766; auth LOCKED; no radio/DHCP/default route`，未见 panic/abort。
- iPhone 枚举：用户在后续接线后报告“出现了以太网”。这是用户观察的系统网卡识别结果，未采集 USB 抓包或手机截图。
- 固定 IP：用户随后报告已配置好 IP。此前给出的参数为 `192.168.7.2` / `255.255.255.0`、路由器与 DNS 留空；没有读取手机配置或证明网络可达。
- 未验证网络收发、认证 PING、HID、系统采集或后台 Agent 闭环。

脱敏验证摘要（本地文件 `evidence/ncm-com-bringup-20261004.log`，已忽略）。完整构建、写入、启动日志与镜像保存在 Git 忽略的 `.build/device-backups/ncm-preflash-20261004-0C8ErC/`，烧录清单为该目录的 `flash-review.json`。

## 镜像与恢复

App 为 389568 字节，SHA-256：

```text
be0bfa5782e695cd8684573a90b794d5fb92c756c5a345e043ebe34f57d90a6a
```

烧录使用事先冻结并重新核验摘要的 `candidate/` 镜像，未复用其他 worktree 的旧包。启动日志中的 App version 是 ESP-IDF 自动取出的 Git describe 字符串，受历史归档 tag 及字段长度影响；它不表示烧录了原后台分支。以本记录的源码提交、App 摘要和清单为准。

写入范围按擦除扇区计为 `[0x0, 0x6000)`、`[0x8000, 0x9000)`、`[0x10000, 0x70000)`。烧录前另行读取当前设备 `[0x0, 0x80000)` 的 512 KiB，并经设备摘要校验一致；备份为 `current-first-512k.bin`，覆盖所有本次写入区域。这不是完整 16 MB 备份；其余 Flash 没有被本次烧录命令覆盖。此前名为 factory 的全片备份是空白 Flash，不能单独恢复当前诊断固件。

新旧分区表的 NVS 范围相同（`0x9000`、长度 `0x6000`），本次没有清空 NVS 或配置密钥。App 分区声明从原诊断固件的 2 MiB 改为 1 MiB；恢复原诊断固件时应连同已备份的分区表一起恢复。备份保留在本机忽略目录，不发布二进制内容。

## 下一步

串口监视已结束；用户已确认 iPhone 出现以太网接口。后续测试维持手机单独供电，不得同时连接 Mac COM 供电与 iPhone。

用户已报告固定 IP 配置完成；S3 为 `192.168.7.1`。首次烧录时 PA1 服务为 `LOCKED`。随后用户明确选择 **USB 免 PSK**，因此不再配置双方密钥；2026-10-04 19:34 已获明确授权并完成 PA2 NCM-only 的 COM 烧录和启动检查，详见 [NO-PSK.md](NO-PSK.md)。配套 App 尚待更新，PA2 的 iPhone PING 尚未验证。此阶段不启动 Agent、不上传屏幕；旧 Host 桥接 Keychain 和模型 API 密钥不变。

首次烧录时并发 STOP 回执覆盖问题尚未修复；后续已完成修复、18 项 TCP 回归与两版固件构建，23:03 经用户明确批准完成 NCM+HID COM 烧录及启动检查，见 [HID 烧录与联调](HID-BRINGUP.md)。设备当前已更换为 HID 版，iPhone 上的复合枚举和真实输入仍待验收。
