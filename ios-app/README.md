> **本地工程更新（2026-10-04）**：已修复 SwiftAgentKit 的 iOS 不可用路径 API，以及选择具体模拟器时 App/依赖架构不一致的问题。Xcode 27 无签名 Simulator `build-for-testing` 成功：通用目标生成 arm64/x86_64，具体 iPhone 18 Pro / iOS 27 目标生成 arm64，均包含完整 App 和 18 项 XCTest 的编译。测试执行、界面启动和真机运行尚未验证。主 Bundle ID 为 `com.ja1chen.PhoneAgent`。PiP 后台能力仍未启用。详见[编译修复与验证](docs/IOS-BUILD-FIX.md)。

# Phone Agent iOS · 0.1 source candidate

轻量 iOS agent App 的源码开发版。**已通过模拟器编译，未安装到 iPhone，也未完成 ESP32 真机闭环。** 本工程仍不是可宣称已运行验收的发行版。

## 已实现到源码的内容

- 原生 SwiftUI：任务输入、最新截图、实时状态 / 工具进度、动作记录、单次确认、停止、重新开始
- 实际 SwiftAgentKit `Agent` loop，固定五个工具：screenshot / tap / drag / wait / finish；无 shell、打字、home 或任意扩展工具
- 离线演示：确定性脚本驱动合成计数器画面，不调用云模型、不连接或控制真实设备，始终带演示标识
- 真实模式：用户自填 HTTPS OpenAI Chat Completions 兼容地址、支持视觉和工具调用的模型 ID、自己的 API key；未配置或未获本次截图发送确认时不调用模型
- API key 与独立桥接 PSK 存入本机 Keychain，不打包密钥，不把密钥 / 原始 HTTP 响应 / 模型内部推理写入任务记录
- 每次 tap/drag 必须单独批准；审批后重验截图时间、图像 ID、像素边界；串行输入、5 分钟 / 12 次模型调用 / 16 次输入限制；已发送但结果丢失的输入绝不自动重试
- 有界上下文：保留最新一张图像，旧图像从框架会话移除；最多 30 条上下文消息。云端请求只携带最新图像
- 本地最近 20 个任务，每个最多 100 条简短记录；完整文件保护、排除备份；重启后正在运行的任务标为中断，不恢复排队动作
- 实验性 `NWListener` TLS-PSK 通道、请求关联和 PNG 分块校验，协议见 [BRIDGE_PROTOCOL_V1.md](docs/BRIDGE_PROTOCOL_V1.md)

## 必须明确的边界

1. **同机跨 App 持续执行尚未解决。** 此版 App 离开前台就取消任务和连接。若 agent 和目标界面在同一台 iPhone，切到另一个 App 会中断 agent；没有宣称原生后台持续执行，没有音频 / VPN 保活
2. **ESP32 固件 v0.3 尚无这个 App 通道。** 有认证握手、`backend_ready` 和真实截图之前不能当作已连通。已有 Mac 上的截图 / 触控成功不等于本 App + ESP32 成功
3. **模型/API 兼容性未实测。** 仅支持 Chat Completions 形状和原生 function calls；不是 Responses API。模型须支持图片和工具调用；不兼容参数会明确报错，不能冒充成功
4. **计费上限不是金额硬上限。** 20,000 tokens 是服务实际报告后的停机门槛，当前请求可能已产生费用，缺失 usage 时无法完整统计。还有请求次数、输出 tokens 和运行时间上限
5. **“完成”是模型 / 演示脚本报告并提交新截图后的状态。** 用户应核对结果。命令送达不能证明屏幕变化。普通坐标无法在本地可靠识别付款等后果；此版强制逐动作人工复核，高风险步骤应自行处理
6. 本工程不含个人截图、配对记录、证书私钥或 API keys；只将带来源及 MIT 许可证的 SwiftAgentKit 核心兼容快照纳入 `Vendor/`，其余下载依赖与工具缓存不纳入版本管理

## 打开工程与构建

目标为 iOS 17+。SwiftAgentKit 的 package manifest 要求 Swift tools 6.2+；本机使用 Xcode 27 / Swift 6.4 完成编译。App 自身使用 Swift 5 language mode + complete concurrency checking。SwiftAgentKit 使用仓库内兼容快照，两个远程依赖已解析并锁定。

1. 用 Xcode 打开 `PhoneAgent.xcodeproj`，选择共享 scheme `PhoneAgent` 和 iOS Simulator。主 Bundle ID 固定为 `com.ja1chen.PhoneAgent`，不要改成随机 ID。
2. 等待 Xcode 解析依赖，再按 `⌘R`。若 Xcode 仍显示旧的远程 SwiftAgentKit 报错路径，关闭并重新打开工程，确认 SwiftAgentKit 指向 `Vendor/SwiftAgentKit`。本次未绕过宏验证或修改全局信任配置。
3. 模拟器不需要选择 Team。真机签名、Team、App ID 注册和设备安装属于单独步骤，本次没有执行。
4. PiP 状态预览默认关闭，在主界面主动开启。当前构建未增加后台模式，跨 App PiP 按钮禁用；不影响前台原型的展示。
5. `project.yml` 保留为 XcodeGen 来源；也可以用 Python 标准库脚本重新生成同一工程，新增 Swift 源文件后运行：

```sh
python3 scripts/generate_xcode_project.py
# 无签名编译 App 和测试（不启动模拟器）：
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/VerifiedBuild \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -scmProvider system -disablePackageRepositoryCache -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

不要添加全局 `-sdk iphonesimulator`：编译期宏需要在 Mac 上构建，Xcode 应根据 destination 分别选择平台。`build-for-testing` 只编译测试，不执行测试。真实解析产生的 `PhoneAgent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` 已随工程保存。

Debug 使用 `ONLY_ACTIVE_ARCH = YES`，与 SPM 在具体模拟器上的架构选择一致；Release 保持 `NO`。
没有硬编码 arm64 或排除 x86_64。模拟 Xcode 的具体设备构建时，可将 destination 替换为
`platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0`（按本机可用设备调整）。

## 依赖固定点与许可证

- SwiftAgentKit：MIT，基于 revision `84ddf324fd2a223834323537eb3f8746d669753b` 的[本地核心快照](Vendor/SwiftAgentKit/README.md)，仅三个移动平台存储路径补丁
- LLMProviderKit：MIT，exact tag `0.1.0-alpha.35`，本次实读 revision `f55aeb4d7a935b9f20c5c85d32cd21eb635ee38d`
- 项目只链接 SwiftAgentKit core、LLMProviderKit core 与 OpenAI provider，没有链接 Mac / Simulator 驱动模块
- 上游许可证保存在 `Licenses/`。TLS-PSK public API 参考 Apple 官方 TicTacToe sample 与 TN3213，见协议文档；本包未引入私有 iOS 控制 API
- SwiftSyntax：`603.0.2`；未使用的 MCP、桌面控制和示例 target 未纳入本地快照，当前解析图只有 LLMProviderKit 和 SwiftSyntax 两个远程包

## 原始交付验证（历史）

在 dot 自带 Linux 云环境执行，未切换到 Work/Codex 子任务、用户电脑或保存的编码环境：

- 12 个 Python 独立 wire-contract 测试通过，覆盖分帧 / 拆包 / 截断 / 越界 / 图片提交 / 错误 ID / hash / 顺序 / 重复块
- 15 个 Swift 文件通过 tree-sitter 语法解析；项目 YAML、隐私 plist、依赖固定点和关键安全约束静态断言通过
- 13 个 XCTest 用例已写入，包括动作拒绝、停止后阻断、输入后新截图、布尔值坐标拒绝、OpenAI 图片工具结果适配；**未运行**
- 没有 Swift compiler / Xcode / iOS SDK，所以 **未 Swift type-check、未构建、未 UI 运行、未网络或硬件联调**

详情及未验证项见 [VERIFICATION.md](docs/VERIFICATION.md)。

```sh
python3 scripts/test_contract.py
# 使用单独的 venv / 环境安装 scripts/requirements-qa.txt 后：
python3 scripts/check_source.py
```
