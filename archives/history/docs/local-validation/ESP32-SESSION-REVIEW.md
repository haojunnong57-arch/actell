# ESP32-S3 首次实机测试与试错记录

日期：2026-10-04。范围为本会话的本地工具链、首次 Flash 备份、双接口烧录和基础诊断；没有执行 iPhone Host 联调。机器可读结果见 `esp32-bringup-summary.json`（本地文件，已忽略），硬件分析见 [USB 与 Host 方案](../../../../docs/hardware/ESP32-S3-USB.md)。

## 已保留的证据

| 阶段 | 结果 | 文件 |
| --- | --- | --- |
| 首次只读识别 | ESP32-S3 v0.2、16MB Flash；当时尚未烧录或运行 PSRAM 自测 | 初始快照（本地文件 `esp32-initial-probe.json`，已忽略） |
| 首次烧录前备份 | 16,777,216 字节，设备摘要匹配；后续逐字节验证全为 FF | 设备摘要校验日志（本地文件 `esp32-factory-backup-verification.log`，已忽略）；镜像另存于忽略目录 `device-backups/` |
| Hello World | 输出 Hello World 并按示例预期倒计时重启 | 运行日志（本地文件 `esp32-hello-runtime.log`，已忽略） |
| 原生 USB 烧录及运行 | 三个镜像 Hash 校验通过，项目诊断通过 | 烧录日志（本地文件 `esp32-native-flash.log`，已忽略）、运行日志（本地文件 `esp32-diagnostics-usb-runtime.log`，已忽略） |
| COM 烧录及运行 | 115200 下三个镜像 Hash 校验通过，烧录后项目诊断通过 | 烧录日志（本地文件 `esp32-com-flash.log`，已忽略）、烧录后日志（本地文件 `esp32-diagnostics-com-after-flash.log`，已忽略） |
| COM 高波特率 | 460800 下报 packet corruption；原因未定位 | 失败日志（本地文件 `esp32-com-460800-failure.log`，已忽略） |

归档日志省略了设备 MAC 并清理行尾空格，测试内容和结果保留。原理图按二进制原样保存，未改写 PDF 内容。

初始快照中的 `NOT RUN` 只表示首次识别时点，后续进展以实测摘要为准。日志中的绝对路径和串口名保留历史上下文；早期备份校验日志里的 `.build/device-backups/` 是迁移前的位置，当前应保留 `device-backups/` 下的独立备份包。

## 有复用价值的试错

- **COM 高速不稳定：**esptool 5.1.0 下 460800/921600 出现错误；ESP-IDF 自带 4.12.0 在 460800 仍失败，在 115200 读回及标准烧录通过。不能据此归因于某个 esptool 版本，也不能直接判定芯片损坏。后续固定 115200 作基线，再分别排查线材、USB 路径和串口桥。
- **原生 USB 的读法有差异：**esptool 5.1.0 的 stub 完整读取在 4096 字节后失败，ROM `--no-stub` 完整读取通过；4.12.0 的 stub 64KiB 读取及标准烧录通过。备份最终用完整长度、SHA-256 和烧录前设备 MD5 共同确认，不把单次 stub 失败当成 Flash 损坏。
- **构建沙盒与固件错误分开：**Hello World 和原生控制台实验首次在沙盒里配置时，`idf_component_manager` 经 `psutil` 查询父进程触发 `PermissionError: [Errno 1] Operation not permitted (sysctl)`。随后在宿主执行构建通过。这是当时的执行环境权限问题，不需要为此修改固件源码。
- **控制台实验没有成为产品改动：**曾在 `.build/board-bringup/` 使用独立配置试验原生 USB 日志；最终构建/烧录使用项目原有默认诊断配置，固件源码未改。Host 未来占用内部 PHY 时仍应使用 COM 日志。
- **备份名称不能代表内容：**文件名保留 `factory`，但内容是空白 Flash；写回仅恢复空白状态，不会恢复一个厂家演示程序。完整镜像全 FF，因而 ZIP 约 20KB 是正常压缩结果。
- **电气推断需要限制范围：**焊盘双向 1.7Ω 与表笔短接读数一致，支持低阻通路判断；空载 4.95V、亮灯或原生 USB 烧录成功都不能单独证明 J4 的物理短接状态、负载供电能力或 iPhone 接法安全。厂商文字与图纸适用条件的差异保留为未解决项。

## 整理与验证

- 提交范围包括可读结论、结构化结果、必要原始日志、厂家原理图及来源、项目本地 ESP-IDF 启动脚本；购买清单仅是资料核对后的候选方案。
- 前一次 COM 运行日志与烧录后日志仅 ROM boot 字段不同（0x8/0x9），合并保留烧录后版本；原始工作日志仍位于忽略的 `.build/board-bringup/`。大型编译输出、临时构建目录不进入 Git，也不删除已安装工具链或已有可用固件。
- `device-backups/` 与构建缓存分开并加入忽略；保存独立 ZIP 及包外校验文件。备份不靠 Git 保存，Obsidian 归档另外复制一份。
- 本次整理重新校验了三个现有固件镜像的大小/SHA-256、原理图 SHA-256、Flash 备份完整长度/全 FF/SHA-256、备份 ZIP 的 CRC 与内部 `SHA256SUMS`，均与记录一致。
- 本次整理检查 `tools/with_esp_idf.sh` 的 Bash 语法，并实际运行入口得到 `ESP-IDF v5.5.5`。没有重新连接设备、烧录或改变 eFuse；历史硬件日志不能算作本次重跑。
