# Xcode 工程与最小状态 PiP 原型

记录时间：2026-10-03 UTC（Mac 日志为 2026-10-04 本地时间）。本次只修改 `with-esp/ios-app`，开始前逐项核对原始清单，未发现用户后续修改；未修改 `app-only` 或固件。

## 可打开的工程

- 入口：[`PhoneAgent.xcodeproj`](../PhoneAgent.xcodeproj)，共享 scheme：`PhoneAgent`。
- 主 target：`PhoneAgent`，Bundle ID 固定为 **`com.ja1chen.PhoneAgent`**；测试 target：`PhoneAgentTests`，ID 为 `com.ja1chen.PhoneAgentTests`。
- iOS 17+，Swift 5 language mode，complete concurrency checking。主 target 包含 16 个 Swift 文件、PrivacyInfo.xcprivacy；测试 target 包含 3 个 Swift 文件，共 17 项 XCTest。
- 主 target 的既有本地网络用途说明被保留，没有添加麦克风、相机、通知、后台模式或其他 entitlement。Team 留空，未注册 App ID、签名、安装或启动设备。
- 使用 Python 标准库[生成脚本](../scripts/generate_xcode_project.py)，不要求 XcodeGen。`project.yml` 的主 Bundle ID 同步更新；生成脚本包含源文件、资源、包依赖、测试 host 和共享 scheme。
- SwiftAgentKit 仍固定 revision `84ddf324fd2a223834323537eb3f8746d669753b`；LLMProviderKit 仍固定 `0.1.0-alpha.35`。真实解析产生的 [Package.resolved](../PhoneAgent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) 锁定 10 个包，没有伪造锁文件或替换为 mock 依赖。

## PiP 能力与边界

Apple 将 PiP 定义为媒体播放或视频通话体验。公开的 [sample-buffer ContentSource](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class/init(samplebufferdisplaylayer:playbackdelegate:)) 可以展示 `AVSampleBufferDisplayLayer` 的像素内容；它不是承载任意 SwiftUI 控件的全局悬浮窗口。系统管理 PiP 的位置、尺寸和控制按钮，App 不能借此在别的 App 上放置自己的审批按钮。

[Apple 媒体配置文档](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback) 明确要求音频会话及 Background Modes 中的 **Audio, AirPlay, and Picture in Picture** 配置来支持 PiP。该设置对应 `UIBackgroundModes` 的 `audio`，属于后台能力配置，不是麦克风录音许可。本次用户要求额外权限先报告，因此没有自动添加它。

本次实现是 **只读、暂停的单帧 sample-buffer 原型**，并不宣称 Apple 官方支持“通用 agent 状态悬浮窗”或保证通过 App Store 审核。[审核指南 2.5.1、2.5.4](https://developer.apple.com/app-store/review/guidelines/#software-requirements) 要求按框架和后台服务的预定用途使用。即使公开 API 接受某种像素内容，也不能据此断言用途合规或后台持续刷新可行。

当前交付行为：

1. 主界面提供“预览最小状态卡片”，默认关闭，用户主动开启后显示 640×360 状态画面。
2. 卡片只取应用定义的任务类别、运行阶段、是否需要返回 App 确认。真实模式统一显示“当前授权任务”；不外显任务正文、模型输出、原始状态字符串、截图、API 地址、Keychain 或配对信息。
3. PiP 内容是显示状态，不提供批准、拒绝、执行动作或继续任务的能力。系统的播放/跳转按钮也不会触发 agent。
4. 使用 `AVPictureInPictureController` 的 sample-buffer 内容源，不使用视频通话 API、私有 API、隐藏音频、循环视频、定时保活或后台任务续期。自动进入 PiP 保持关闭。
5. App 离开前台仍调用原有 `AgentViewModel.setForeground(false)`，取消审批并停止任务与桥接。状态控制器独立更新一次中断画面，之后不进行后台刷新。返回 App 不自动恢复任务。
6. **当前构建未启用后台媒体能力，跨 App PiP 按钮禁用。** 这项限制在界面中明确说明。只有前台预览可用；不能把源码存在说成已实现全局悬浮。
7. 若后续获准启用后台媒体配置，代码也仍会检查设备支持与 `isPictureInPicturePossible`，并处理启动失败、用户关闭、系统关闭和返回 App。单帧暂停内容能否在具体 OS/设备持续保留，仍需实测，不承诺无限显示或后台刷新。

## 实际验证结果

本次隔离使用 `.build/SourcePackages` 和 `.build/VerifiedBuild`，没有更改 `xcode-select`、中断其他 Xcode/Codex 任务或操作模拟器。

| 检查 | 结果 |
| --- | --- |
| 工程结构 | `plutil -lint` 通过；`xcodebuild -list -json` 识别 PhoneAgent / PhoneAgentTests 和共享 scheme |
| 依赖解析 | 成功，包含真实 checkout 和 10 个版本锁定项 |
| 核心状态/PiP Swift 类型检查 | 使用 iOS Simulator 27 SDK、arm64 iOS 17 target、complete concurrency checking 通过；最后一次无诊断 |
| 独立协议测试 | `python3 scripts/test_contract.py`，12/12 通过 |
| 全 App 无签名 Simulator build | **失败/受阻**：依赖图确认包含 SwiftAgentKit、LLMProviderKit、OpenAI provider，但 Xcode 要求先启用 `SwiftAgentKitMacros`；未进入完整 App 编译 |
| XCTest、界面、PiP 跨 App、真机 | **未运行**；不能宣称通过或 App 已可运行 |

实际构建命令见 [README](../README.md)。最终构建错误为：

```text
Macro “SwiftAgentKitMacros” from package “SwiftAgentKit” must be enabled before it can be used
** BUILD FAILED **
```

没有使用 `-skipMacroValidation`，没有写全局宏信任配置。已只读检查固定 revision 的 `Sources/SwiftAgentKitMacros/ToolMacro.swift`，其用途为编译期 `@Tool` 语法生成；该检查不替代 Xcode 的信任决定。

可读日志放在本目录的 `xcode-validation/`；完整中间输出在 `.build/validation/`。之前的 `VERIFICATION.md` 和原始 `SOURCE_MANIFEST.json` 保留为交付时历史证据，不改写为本次构建通过。原始导入校验工具会发现本次有意修改的 iOS 文件，这不表示下载归档损坏。

## 待确认的两项

- 为继续完整构建，需要用户在 Xcode 的提示中信任这个固定版本的 `SwiftAgentKitMacros`，或明确授权本次构建执行该编译期宏；不涉及模型调用、账号注册或设备操作。
- 若要继续测试跨 App PiP，需要另行确认添加仅 `audio` 的后台媒体/PiP 配置。可审阅的增量是 `UIBackgroundModes = [audio]`，不包含其他后台模式。此项仍不能解决通用状态窗的用途限制、后台刷新或 agent 前台生命周期问题。

这两项当前均未自动执行。选择 Team、签名、设备安装、额外系统权限和实体桥接验收仍属于后续明确授权的步骤。
