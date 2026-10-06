# 主 App 与 USB Device 固件整合

2026-10-06，当前分支 `feature/ncm-coredevice`。

## 使用入口

安装后的主 App 为 **PhoneAgent**（`com.ja1chen.PhoneAgent`），从“设置 → USB 连接 → ESP32 控制”进入。页面提供系统配对、同一行的连接/重新连接与停止、获取截图、点击验证和截图预览；不恢复独立实验的诊断列表、导入器或权限开关。

主 App 与独立 NCM Probe 使用不同沙盒。不会导出或复制 Probe 的配对身份；主 App 首次使用需系统配对一次。在页面点“系统配对”，待入口发布后前往系统设置的开发者模式，选择 **PhoneAgent NCM** 并输入页面提供的 PIN。回到 App 后连接 S3，获取截图，再在点击验证页使用“经 S3 点击中央目标”，以真实触摸计数增加作为成功标准。更新主 App 保留其已有身份。

## 实现

- `ios-app/PhoneAgent/ESP32Control` 拥有设置子页面、配对/连接状态与点击验证页。`SettingsView` 使用已有导航栈进入子页面。
- `PhoneAgentApp` 启动时注册 `.pairing` 后台任务；后台普通控制关闭，系统配对持续任务单独保留；受保护数据不可用时关闭会话。已有 `.backgroundRun.*` 任务标识保留。
- 主 App 直接编译复用 `ncm-dev/PhoneAgentNCM` 的 Swift/C ABI，Xcode 构建阶段调用 `tools/build_ncm_rust.sh` 构建相应平台静态库。arm64 真机与 arm64 模拟器均可构建。项目生成脚本和 `project.yml` 同步接入。
- `firmware-device` 仅初始化一次 USB/NCM 网络。`28766` 保留 PA3；`28767` 启动 ND1/NR1/NL1 发现与有界转发。NCM-only 也能执行新的开发者服务截图和触控，PA3 的 HID 支持取决于固件构建模式。
- 网络增加 IPv6 link-local、IGMP/MLD，不新增默认路由、DHCP、Wi-Fi/BLE。USB epoch 变更仍撤销连接。
- `firmware-device/main/developer_service.c` 是共用服务实现，独立诊断固件引用同一份源码。Probe 引用主 App 的设置界面，避免维护两份 UI。
- 主任务的 `screenshot`、`tap`、`drag` 默认经 `NCMDeviceBridge` 使用设置页建立的认证会话；旧的 ScreenCaptureKit/PA3 USB HID 和 TLS 实现完整保留。`DeviceControlRoute.current` 是统一路由选择入口，暂不新增设置开关。每次任务固定路由与会话世代，NCM 未就绪时提示连接，不会偷偷回落到旧链路。

## 当前验证

| 验证 | 结果 |
|---|---|
| 原 PA3 协议/运动与 TCP 回归 | ASan/UBSan 通过，TCP 24 项通过；USB/HID 为模拟环境 |
| ND1/NR1/NL1 协议回归 | ASan/UBSan 通过，含有界转发、取消、会话隔离和真实 loopback socket |
| 主固件 NCM-only、NCM+HID 构建及 USB 描述符检查 | 两种通过；未引入 radio/DHCP/forwarding |
| 主 App 无签名真机、签名真机、arm64 模拟器构建 | 通过 |
| 主 App 安装与启动 | 当前 iPhone 15 Pro 上成功，保留 App 原有数据 |
| 独立 Probe 模拟器、独立诊断固件兼容构建 | 通过 |
| S3 主固件刷写 | NCM-only，57600 baud、ROM 无 stub/无压缩；bootloader、partition、app 三段 hash 验证通过；未写入 NVS |
| S3 启动 | UART 确认 `pa_developer` 转发服务与 `pa_device` PA3 服务启动，无本次捕获窗口内 panic |
| 主 App 新身份配对、截图与点击实际效果 | 待用户验证；独立 Probe 先前的实际成功不替代主 App 此项验收 |

主固件 NCM-only：394624 bytes，SHA256 `72b311ca9e9e09f7b0d4e7798d52b3dac42d5a20c45cd04ff67881acdc9cf92f`。NCM+HID：397712 bytes，SHA256 `21f36e6fd7fe1112f664c145d811552e638106dcf494f9eac62d77e6bc0af953`，仅构建未刷写。

本地原始日志保留在忽略目录 `.build/integration-*.log`，不提交设备日志或身份数据。已有主工程签名设置保持原值。

## 系统设置跳转验证

2026-10-06，在当前 iPhone 上对比了 Mac 发起的 URL payload 与主 App 实际调用 `UIApplication.open`。两者不能当成同一个运行场景。

- Mac 发起的 `App-prefs:root=Privacy&path=DEVELOPER_MODE` / `settings-navigation://com.apple.Settings.PrivacyAndSecurity/developerMode`：用户先报告 App 列表，随后报告隐私页；没有确认进入开发者模式。
- 主 App 按钮尝试上述新版设置导航路径、隐私页路径及 `App-prefs:root=Privacy`：用户报告 App 列表，没有确认正确落点。
- 临时 Debug 探针从主 App 自身调用 `prefs:root=Privacy&path=DEVELOPER_MODE`：`open` 返回 false，系统未接受。
- 临时 Debug 探针从主 App 自身调用 `App-prefs:com.apple.settings.PrivacyAndSecuritySettings`：`open` 返回 true，用户确认实际仍是 App 列表。组件标识来自本机 iOS 27 设置资源，仅用于构造候选，不能证明 URL 支持。
- `settings-navigation://com.apple.Settings.PrivacyAndSecurity#developerMode` 的最后一项尝试因 devicectl 超时没有得到 App 启动/调用结果，不记作 URL 拒绝或落点测试成功。

结论：本轮未找到普通 App 可以使用的开发者模式直达链接，**不等于 Apple 明确禁止或所有 URL 写法均不可行**。公开的 [`openSettingsURLString`](https://developer.apple.com/documentation/uikit/uiapplication/opensettingsurlstring) 指向 App 自身设置，不能作为配对页跳转。失败的跳转按钮和临时 Debug 探针已移除；最终版本保留准确的手动路径，没有宣称已经能直达隐私页或开发者模式。

原始日志留在忽略目录 `.build/settings-*.log`。此前主工程整合、签名和身份保存保持不变，不重新刷写固件。

跳转实验清理状态：源码中的跳转按钮和临时探针已移除，清理版签名构建成功。无线安装多次超时，延长等待后报 `Failed to allocate RSD device`（CoreDevice -1 / mobiledevice 0xE8000003），因此尚未将清理版装回手机。手机仍可能运行实验时的 Debug 版本；不能把源码清理或构建通过写成已完成装机。需要恢复可用的 Mac 开发连接后继续安装，不改动配对身份。

## ESP32 控制页面简化

页面和设置入口改为“ESP32 控制”。连接/配对状态、必要提示、配对 PIN 与当前可用的控制按钮合为一行：未配对显示“配对”，已配对未连接显示“连接”，已连接显示“重新连接”和“停止”，处理中只显示“停止”。状态使用文字与处理进度，不使用空圈。未连接时隐藏整个验证与截图区域；连接后显示“服务验证”的截图/点击入口。底层身份和控制链路保持原有行为。

ESP32 控制页面简化后的签名真机构建通过，源码检查无空圈状态和旧“操作”section。尝试安装新版仍报 CoreDevice/RSD 0xE8000003，手机尚未完成此次界面更新；本次未改协议/固件或配对身份。

## 主任务切换 NCM

- 截图返回手机 PNG 的真实像素尺寸，沿用 Agent 的截图坐标归一化、任务授权和动作后重新截图规则。
- 点击和拖动使用同一认证隧道的 UniversalHID 服务；仅首次输入准备触控所需屏幕会话，不依赖截图结果或视频包到达。拖动范围 100–2000 ms；不确定发送结果不自动重发。
- 设置页验证、任务操作与保活共用操作门。任务占用期间禁用重新连接和验证按钮，停止仍可用。正常任务完成释放占用、保留前台连接；操作期间取消则关闭所属会话。重连/进入后台使旧任务失效。
- 当前 NCM 会话只在主 App 前台使用；保留旧链路的后台能力，但切换到 NCM 不意味着获得后台持续控制能力。
- 主 App 沙盒身份沿用，不需重刷固件或重复备份。

### 本次验证与安装（2026-10-06）

- 最终签名 iPhone 构建通过；已安装并启动 `com.ja1chen.PhoneAgent`。本次无线开发连接已恢复，覆盖此前界面更新安装失败的状态。
- Rust 后端 27 项、vendored idevice 175 项通过；Swift/C/Rust/C 中继离线调用链 20 项通过，含拖动参数验证与不确定发送后关闭。
- 主 App 新增 NCM 路由 6 项全部通过：远端像素尺寸、输入授权、图像一次消费、重连失效、取消屏障、拖动转发和坏截图撤销旧图像授权。
- 完整单元测试首次运行 171 项，出现 17 条失败断言（6 个测试用例）；旧 USB 后台任务复测通过。其余旧断言要求 finish 必须有截图、前台禁止任务授权/输入、画面变化或旋转阻止输入；与现有旧链路实现不一致。对应旧实现及测试本次未修改，不能报告全套测试通过。日志 `.build/ncm-route-app-tests.log` 和 `.build/ncm-route-focused-tests.log`。
- 主任务走 NCM 的真机闭环、拖动实际效果仍待用户验证，离线 spy/中继测试不是触摸实际生效的证明。保持主 App 前台，先在 ESP32 控制连接，然后在会话请求截图和输入，以动作后截图或真实触摸计数确认效果。

## 连接状态与通用 ESP32 命名

- 截图复用已有认证控制会话，不重新配对或重建 NCM 隧道。原 UI 将 `running`（任意操作忙碌）优先显示为“处理中”，因此看起来像连接刷新。
- 已就绪时持续显示“已连接”；截图进度只放在“获取截图”按钮，服务控制按钮保持位置，忙碌期间禁用重新连接。仅实际配对/连接时在连接状态旁显示进度。
- 共用界面目录改为 `ios-app/PhoneAgent/ESP32Control`，文件及类型为 `ESP32ControlSettingsView`，同步主 App、Probe、工程引用、生成脚本和说明；不改底层实际 S3 芯片/固件标识。
- 主 App 签名真机构建与独立 Probe 无签名真机构建通过；新版主 App 已成功安装到当前 iPhone。状态显示实机视觉效果待用户复核。
