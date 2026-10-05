# PhoneAgent iOS

最低 iOS 27，Bundle ID 保持 `com.ja1chen.PhoneAgent`。导航栏的设备按钮管理采集与 USB NCM；独立服务商页支持添加、编辑、确认移除及恢复。会话选择服务商/模型，当前运行不允许切换配置。现有单服务商配置与 Keychain 引用自动保留；修改服务地址不会转发旧地址的密钥。

真实模型使用 screenshot / tap / drag / wait 设备工具，最终文字回复结束本轮。启用用户导入的技能后，额外提供 list_skills / search_skills / load_skill，只按需读取该技能包的文本。同一响应可含多个工具，按返回顺序串行执行；每个动作仍须经过原有授权、截图与故障检查，ID 不得重复或重用。模型调用数、输入数、累计 token 与固定运行时长不再作为产品预算。图像/协议大小、网络故障、系统后台资格、锁屏、手动停止、未知动作不重放仍然生效。App 不保证系统无限后台执行。

输入区支持系统照片／文件选择、预览与移除；仅显式发送时传给所选模型。截图与消息图片可保存原图并在重启后查看；历史资源不恢复设备授权。设置内可管理用户主动导入的 SKILL.md／文本技能包，导入不执行脚本。服务商支持模型发现、能力缓存和每模型参数；原生 Anthropic/Gemini 目前仅支持发现，尚不提供原生推理。详细范围和验收见 [本次证据](../docs/PROJECT-TODOS.md)。

## 构建

使用已安装 Xcode 27，不更改本机签名。新增源文件后运行 `python3 ios-app/scripts/generate_xcode_project.py`（在仓库根目录）。构建缓存放 `.build/`，可使用已解析依赖的独立副本。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceBuild \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO build
```

## 测试

```sh
CC=clang bash tools/test_usb_device.sh
bash ios-app/scripts/test_core.sh <隔离模拟器-UDID>
RUN_UI_TESTS=1 bash ios-app/scripts/test_core.sh <隔离模拟器-UDID>
```

测试使用合成模型、临时持久化目录和回环 USB peer；无真实凭据/设备动作。UI 模式会向指定的独立模拟器添加一张合成图片及 `ProjectTodosFixtures` 文件，用于系统选择器；只运行定向 UI 用例前可先执行 `python3 ios-app/scripts/prepare_ui_fixtures.py <UDID>`。默认 target 保留所有核心协议、审批、隔离、迁移、捕获和停止释放用例。可选归档用例与恢复方式见 [归档入口](../archives/README.md)。历史日期、旧测试计数不代表本次验收，最新结果见 [本次证据](../docs/PROJECT-TODOS.md)。
