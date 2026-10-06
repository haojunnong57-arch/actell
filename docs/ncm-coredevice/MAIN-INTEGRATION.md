# 主 App 与 USB Device 固件整合

2026-10-06，当前分支 `feature/ncm-coredevice`。

## 使用入口

安装后的主 App 为 **PhoneAgent**（`com.ja1chen.PhoneAgent`），从“设置 → USB 连接 → ESP32 控制”进入。页面提供系统配对、同一行的连接/重新连接与停止、获取截图、点击验证和截图预览；不恢复独立实验的诊断列表、导入器或权限开关。

主 App 与独立 NCM Probe 使用不同沙盒。不会导出或复制 Probe 的配对身份；主 App 首次使用需系统配对一次。在页面点“系统配对”，待入口发布后前往系统设置的开发者模式，选择 **PhoneAgent NCM** 并输入页面提供的 PIN。回到 App 后连接 S3，获取截图，再在点击验证页使用“经 S3 点击中央目标”，以真实触摸计数增加作为成功标准。更新主 App 保留其已有身份。

## 实现

- `ios-app/PhoneAgent/ESP32Control` 拥有设置子页面、配对/连接状态与点击验证页。`SettingsView` 使用已有导航栈进入子页面。
- `PhoneAgentApp` 启动时注册 `.pairing` 后台任务；有效 NCM 任务通过 `.backgroundRun.*` 持续调度与有限 UIKit 后台资格保留连接，空闲控制关闭；系统配对持续任务单独保留；受保护数据不可用时关闭会话。已有 `.backgroundRun.*` 任务标识保留。
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
- 设置页验证、任务操作与保活共用操作门。任务占用期间禁用重新连接和验证按钮，停止仍可用。正常任务完成释放占用、保留前台连接；操作期间取消则关闭所属会话。重连使旧任务失效；进入后台仅在缺少或失去系统执行资格时停止。
- NCM 会话的后台执行使用已有系统调度，不依赖录屏。各会话的运行状态、审批、检查点与实时活动独立，同一手机控制按整轮排队。仍需有效系统执行资格与未锁定设备；此修改的持续后台时间和真机多会话效果须单独验收。
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

## feature/project-todos 合并验证

保留 NCM 默认截图/输入与 ESP32 设置子页面，整合新增服务商、附件、技能、可读思考展示及串行多工具调用；导航栏设备入口复用 ESP32 控制页面，旧 SCK/PA3 控制保留在已有路由分支。旧 ControlDebugView 按新版导航移除，底层旧链路保留。工程从双方源码清单重建，包含 NCM Rust 构建阶段和核心测试。

2026-10-06：独立模拟器完整核心测试 237 项通过；PA3 C 协议及停止释放检查通过，USB TCP 回环 25 项通过；最终无签名 iPhoneOS 构建通过。结果目录 `.build/validation/core.iOoDa5/Tests.xcresult`，构建日志 `.build/merge-device-build.log`。本次没有刷写、安装或真实设备动作，不能代替 NCM 真机闭环验收。冲突已处理，merge 提交由用户继续完成。

## 2026-10-06：多会话与无录屏后台

- 离开会话或控制调试页面只改变导航。Agent、模型请求、审批、截图、生命周期和检查点按会话隔离；服务商、附件与系统连接仍属于 App。共享实时活动控制器按 runID 分别维护卡片，创建另一个会话不会结束已有卡片。
- NCM 在系统执行资格有效时支持后台设备工具。复用已有持续处理任务，并用真实 UIKit 有限后台任务覆盖调度申请窗口；升级后忽略旧 UIKit 的迟到到期回调。资格到期、锁屏、连接故障与未知结果边界仍有效，不重发旧动作。
- 同一手机的 NCM 控制按整轮排队，避免另一会话在截图和点击之间改变画面。取消等待任务只移除该任务；连接失效清除所有占用与等待标记，旧任务不会在重连后恢复输入。
- 服务商管理位于“设置 → 服务商”，会话列表导航栏移除服务商按钮。子页面通过系统返回按钮回到设置。

验证：245 项核心测试通过（`.build/validation/session-final.xcresult` 的 PhoneAgentTests；同包旧界面断言已由后续专项结果替代）。设置入口、模型发现和移除恢复通过 `.build/validation/session-settings-ui.xcresult`；多服务商与自定义模型选择通过 `.build/validation/session-provider-focus.xcresult`。iOS 27 模拟器键盘会移动弹窗，界面测试先确认输入焦点、结束键盘编辑，再确认选择。USB 25 项回环测试及生产 C 解析/停止释放检查通过 `.build/session-usb-validation.log`。最终无签名 iPhoneOS 构建及签名构建通过，主 App 已安装并启动在 iPhone 15 Pro。

无录屏 NCM 后台截图和点击已通过注入连接的运行集成测试；这不代表已验证真实 ESP32 后台操作。真机需启动会话 A，返回列表启动 B，再切换到其他 App；核对消息继续更新、设备控制按顺序执行、返回后各会话截图与结果各自对应。系统实际授予的后台时长仍需真机验收。


## 2026-10-06：普通聊天与设置简化

NCM 适配器创建时不检查配对/连接，也不占用设备操作门。首次实际设备工具调用才绑定认证代际并申请控制占用；未连接的截图等调用返回工具错误，模型仍可继续正常回复。保持后台连接的运行引用与设备占用分开，普通聊天不会因为连接检查而被拒绝，也不会导致已经连接的后台任务在首次工具请求前失去连接。

设置入口改为“手机操控”，列表入口使用纯文字；移除后台执行说明区、本地记录首尾说明、手机操控说明行和输入区任务授权提醒。

247 项核心测试全部通过：`.build/validation/core.WrTKab/Tests.xcresult`，包括未连接普通回复、失败截图后模型继续回复、连接后延迟绑定和不占用设备的后台连接保留。最终无签名/签名 iPhoneOS 构建通过；新版主 App 已安装到 iPhone 15 Pro。实际远程模型普通聊天与清理后的设置页仍需在用户设备上核对。

### 2026-10-06 消息页面布局

消息页移除右上角设置与设备入口，会话列表入口保留。进入消息页默认定位到最后一条；用系统 ScrollGeometry / ScrollPhase 判断底部，查看历史时暂停跟随，回到底部后恢复。消息内容或可视区域尺寸改变时维持底部位置。实时活动指定步骤仍按原语义定位该步骤。移除手动滚动到底部悬浮按钮。输入区加号、发送/停止按钮垂直居中；输入容器用 regularMaterial，外围用 ultraThinMaterial。

本次核心测试 247 项通过（`.build/validation/core.EnRDGy/Tests.xcresult`）；定向 UI 用例通过（`.build/conversation-layout-ui.xcresult`），确认消息页没有设置/设备/向下按钮、加号和发送按钮中心 Y 相差不超过 1 点，并检查导出页面截图。签名及无签名 iPhoneOS 构建通过，新版已安装并启动。长对话滚动跟随和真机毛玻璃观感尚待实际使用验收。

输入区外层效果随后按反馈调整：移除整块 ultraThinMaterial 底色，改为 safeAreaBar + 底部 scrollEdgeEffectStyle(.soft)，由系统模糊淡出经过底部的消息；输入框自身 regularMaterial 保留。签名和无签名 iPhoneOS 构建通过（`.build/conversation-edge-blur-build.log` / `.build/conversation-edge-blur-device-build.log`）。本次仅调整呈现，未重跑先前已通过的 247 项核心测试；实际模糊观感待真机确认。

输入框自身随后替换为系统 Liquid Glass：使用 `.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 24))`，保持单个完整玻璃表面与现有输入/按钮布局；外侧继续使用系统 soft 滚动边缘。最低 iOS 27 无需旧系统材质回退。签名和无签名 iPhoneOS 构建通过（`.build/conversation-liquid-glass-build.log` / `.build/conversation-liquid-glass-device-build.log`）。本次仅替换显示材质，未重跑核心测试；液态玻璃动态观感待真机确认。

滚动回弹随后修复：移除“followLatest 变为 true 立即 scrollTo”以及按距离底部 24 点判断的逻辑。改为观察最后一条消息可见性；可见性变化只改变跟随状态，不移动滚动位置。tracking / interacting / decelerating 阶段全部禁止内容变化触发定位，保留系统拖动、惯性与回弹；静止后新消息/内容增长才按既有跟随状态定位。签名和无签名 iPhoneOS 构建通过；核心回归 247 项通过（`.build/validation/core.XD4fOQ/Tests.xcresult`）。新版已安装并启动，真机拖动回弹观感尚待使用验收。

### 2026-10-06 输入区激活布局与键盘定位

输入容器宽度保持不变；未激活时为文字、附件、发送的一行布局，激活后文字单独一行，下行放附件、模型选择与发送。模型选择仅在输入激活时出现，移除原顶部模型/阶段/后台状态行。附件左侧内边距从 15 点减少到 4 点，与文字区间距从 12 点减少到 4 点；44 点附件点击区域保留。输入区使用单块 regular Liquid Glass，不对整块容器增加触摸变形；模型菜单固定条目顺序。消息区轻触可收起键盘。

键盘及输入区改变视口高度时：已跟随末条消息则保持底部；阅读历史时补偿可视高度变化，保留原底部内容坐标。手势进行中积累尺寸变化，结束后才补偿，不在普通拖动或回弹中强制定位。

验证：核心回归 247 项通过（`.build/validation/core.r52vc2/Tests.xcresult`）。定向 UI 通过 3 项：底部的键盘出现/收起与按钮布局（`.build/composer-layout-final-ui.xcresult` 中该单项通过）、历史消息的键盘出现/收起、输入区服务商切换和自定义模型（后二项 `.build/composer-models-history-ui.xcresult`）。UI 验收比较同一条消息相对输入区的底部间距，容差 12 点；历史消息按稳定文本标识定位。模型菜单验收使用固定本地服务商数据，避免服务商录入步骤的输入法状态干扰。已检查通过用例的页面截图。

最终签名和无签名 iPhoneOS 构建通过（`.build/composer-final-build.log` / `.build/composer-final-device-build.log`）。新版已安装，真实设备上的键盘动画和拖动手感仍待日常使用确认。

非激活输入区的发送按钮右侧留白随后由 4 点增为 9 点，与默认 44 点行高、38 点发送按钮及 6 点纵向内边距形成的顶部留白一致。激活布局沿用原位置，没有修改状态切换的动画修饰。签名及无签名 iPhoneOS 构建通过（`.build/composer-trailing-padding-build.log` / `.build/composer-trailing-padding-device-build.log`）；本次仅调整布局内边距，未重复核心和 UI 测试。

本次边距版本安装成功，但 devicectl 自动启动连续被 iPhone 的 Security 校验拒绝（可能为签名、权限或开发者信任原因）。本地 codesign 深度验证通过，签名权限与描述文件一致，现有描述文件有效至 2026-10-11；因此未更改签名配置。最新版本的自动启动未确认成功。

### 2026-10-06 会话列表与思考展示简化

会话列表只显示单行标题，以 40 点内容高度及上下内边距保持垂直居中，移除消息预览与状态徽标。首页设备控制入口移除，保留“设置 → 手机操控 → ESP32 控制”。思考、工具和授权卡片的图标共用 MessageHeaderIcon（body 字体、small 缩放）；思考符号改为 brain，标题改为“思考”，移除右侧生成状态与展开说明。展开内容使用动态 secondary 色的 85% 不透明度，稍微调浅。思考数据、取消、失败与历史恢复语义保留。

验证：247 项核心测试通过（`.build/validation/core.pZ4mWA/Tests.xcresult`）；4 项 UI 用例通过（`.build/reasoning-list-ui.xcresult`），覆盖设置中的控制入口、完成后的思考折叠、失败内容保留、流式思考停止以及深色模式历史恢复。已检查思考展开截图。签名和无签名 iPhoneOS 构建通过（`.build/reasoning-list-build.log` / `.build/reasoning-list-device-build.log`），新版已在 iPhone 上安装并成功启动。
