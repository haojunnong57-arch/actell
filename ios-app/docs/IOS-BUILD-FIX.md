# iOS 模拟器编译修复

日期：2026-10-04（Mac 本地时间）。用户提供的 Xcode 日志在 Swift 编译阶段失败，尚未到 App 启动阶段。

## 原因与修复

固定版本 SwiftAgentKit 的 `FileAgentSkillStore`、`FileAgentGoalStore` 和 `FileAgentMemoryStore`
无条件使用 `FileManager.default.homeDirectoryForCurrentUser`，该 API 在 iOS 不可用。
即使 App 不调用这些便利方法，依赖库整体编译也会失败。

现在工程使用 [Vendor/SwiftAgentKit](../Vendor/SwiftAgentKit/README.md)。这份 MIT 核心快照
来自已固定的 `84ddf324fd2a223834323537eb3f8746d669753b`，43 个 Swift 文件与许可证的原始
SHA-256 记录在 [UPSTREAM.json](../Vendor/SwiftAgentKit/UPSTREAM.json)。仅三个方法增加平台分支：
移动平台使用 App 沙盒内的 Application Support，macOS/Linux 保留原目录行为。
宏源码未修改。没有编辑 DerivedData 或 SPM checkout 中的依赖源码。

本地 manifest 只保留 App 使用的 core 与宏 target；LLMProviderKit `0.1.0-alpha.35` 和
SwiftSyntax `603.0.2` 保持原来解析的版本。Xcode 工程、Python 生成器和 `project.yml` 同步
指向本地路径。新增 XCTest 检查三个存储目录在 iOS Application Support 下可写。

命令行构建同时去掉全局 `-sdk iphonesimulator`，避免把 Mac 编译期宏也编译为 iOS target。
按 [README](../README.md) 只指定 Simulator destination，让 Xcode 为各 target 选择 SDK。

## 验证结果

- Xcode 27 / iOS Simulator 27 SDK，无签名 `build-for-testing` 返回 0、`TEST BUILD SUCCEEDED`。
- 完整 PhoneAgent App、SwiftAgentKit core/宏及 PhoneAgentTests 编译成功，arm64/x86_64 两种架构均生成。
- 18 项 XCTest 已编译，**未执行**。当前没有已启动的模拟器，本次未启动模拟器或安装、启动 App。
- 12 项 Python wire-contract 测试通过；vendor 原始文件哈希核对只发现上述三处有意修改。
- 保留原有 Swift 并发/捕获警告：TLSBridge 的泛型 continuation、AgentViewModel 的 runner 捕获、SafetyTests 的字典跨 actor 传递。当前 Swift 5 language mode 下不阻断构建；尚未做 Swift 6 迁移。
- 未使用 `-skipMacroValidation` 或修改全局宏信任。未增加后台能力、签名 Team、真实设备安装或配对操作。

验证摘要见 ios-compat-summary.json（本地文件 `xcode-validation/ios-compat-summary.json`，已忽略），构建诊断节选见
ios-compat-diagnostics.log（本地文件 `xcode-validation/ios-compat-diagnostics.log`，已忽略）。完整日志在本地忽略目录
`.build/validation/ios-compat-build.log`，历史失败日志保留为此前的证据。

## 在 Xcode 中重试

重新打开 `PhoneAgent.xcodeproj`，选择 PhoneAgent scheme 和 iOS Simulator，按 `⌘R`。
若仍报旧目录下的相同错误，检查 Package Dependencies 中 SwiftAgentKit 的路径应为
`Vendor/SwiftAgentKit`，重新打开工程以加载本地包引用。此验证不代表 PiP 跨 App、模型 API
或 ESP32 实体联调已经通过。

## 具体模拟器架构修复（2026-10-04 后续）

第二份日志显示 PhoneAgent 正在编译 `x86_64`，但 SwiftAgentKit、LLMProviderKit 和
LLMProviderKitOpenAI 只有 `arm64` 模块。此前通用 destination 会为 App 和依赖都生成
两种架构，因而没有发现这一配置差异。

在全新的 `.build/SimulatorRunBuild` 目录中，以 iPhone 18 Pro / iOS 27.0 的具体设备为
destination，先成功复现相同的三个 `Unable to resolve module dependency` 错误，退出码 65。
这说明问题来自配置，不能仅靠删除 DerivedData 解决。

现在 Python 工程生成器、`project.yml` 和 `.pbxproj` 均设置 Debug `ONLY_ACTIVE_ARCH = YES`，
使 App、测试与 SPM 依赖在具体设备上采用相同架构；Release 保持 `NO`。没有硬编码架构，
没有全局 `EXCLUDED_ARCHS`，也没有更改依赖版本或平台支持范围。

使用同一具体 destination 再执行无签名 `build-for-testing`，退出码 0、
`TEST BUILD SUCCEEDED`。App 和测试已按 arm64 编译，三个模块错误均不再出现。
本阶段未执行 XCTest 或启动 App。原有非致命 Swift 警告仍按前文记录。

证据：修复前诊断（本地文件 `xcode-validation/simulator-architecture-before.log`，已忽略）、
修复后诊断（本地文件 `xcode-validation/simulator-architecture-after.log`，已忽略）、
结果及完整日志哈希（本地文件 `xcode-validation/simulator-architecture-summary.json`，已忽略）。
