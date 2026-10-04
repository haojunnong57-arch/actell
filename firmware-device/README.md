# PhoneAgent USB Device 固件（实验，未烧录）

入口是 `main/main.c`，ESP32-S3 原生 USB Device。默认仅 NCM；HID 需要独立构建。源代码、构建通过、USB 枚举成功、iPhone 控制成功是四个不同的状态，当前只完成前两项。

从仓库根目录：

```sh
./tools/build_usb_device.sh ncm
./tools/build_usb_device.sh hid
./tools/test_usb_device.sh
./tools/with_device_idf.sh python tools/verify_usb_device_builds.py
```

构建入口复用本机 `../with-esp/.build/toolchains/` 中已安装的 ESP-IDF 5.5.5，所有新 build/cache 在本 worktree 的 `.build/`。其他机器可通过 `IDF_PATH`、`IDF_TOOLS_PATH` 指向已安装工具链。没有安装脚本，没有 flash/monitor 命令。

依赖固定为 `esp_tinyusb ==2.2.0`、`tinyusb ==0.21.0~2`，锁文件带组件 hash。`SDKCONFIG` 为每个构建独立保存，不使用原 Host 项目的配置。不开 Wi-Fi/BLE，不借调试 CDC，console 为 UART；PSRAM 当前未使用，flash 配置 16 MB。没有触碰真实串口或 USB 设备。

构建产物：

```text
.build/device-{ncm,hid}/
  phoneagent_usb_device.bin
  phoneagent_usb_device.elf
  bootloader/bootloader.bin
  partition_table/partition-table.bin
  flash_args
  flasher_args.json
  sdkconfig
```

这是实际本机交叉编译生成的镜像，不是把源码压缩包改名。它们未烧录、未签名，不是已验证产品固件。默认未配置 PSK 时输入锁定；测试中的公开密钥仅存在宿主机夹具，不进入生产固件。

凭据接口是 NVS namespace `pa_usb` 中 32-byte blob `psk`。需要用户选择独立随机 PSK，在 App 设置中保存同一值，并在明确同意后用 ESP-IDF 的 NVS 分区生成/写入流程配置设备。不要把密钥放进 Git、命令行日志或截图；不要自动擦除其他 NVS 内容。本次没有生成、读取或写入任何真实 PSK，没有增加钥匙串访问权限。

接线初步要求：只通过已确认 D−/D+ 接 GPIO19/20 的原生 USB 口连接 USB-C iPhone，由 iPhone 供电。不要误用 CH340/COM 口，也不要默认同时接 Mac COM 供电；板上 VBUS 回流路径、现有焊盘状态和额定电流需确认。N16R8 不是板型证据。不要求新增 Hub、Wi-Fi/BLE 模块或其它设备。

固定 IP 验证：设备 `192.168.7.1/24`，iPhone `192.168.7.2/24`，Router/DNS 留空。如果 iOS 不接受空 Router 或不枚举以太网，不填假网关，记录现象后停止。现有蜂窝/系统 VPN 是否仍能访问模型必须单独测试，不修改 VPN。

详细协议、架构和验收顺序见 [架构](../docs/usb-device/ARCHITECTURE.md)、[协议](../docs/usb-device/PROTOCOL.md)、[验证记录](../docs/usb-device/VALIDATION.md)。
