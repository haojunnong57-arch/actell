# 可恢复归档

- `history/docs/`：旧 Host 方案、阶段集成、导入、构建及 USB 早期文档；原日期与验证范围保留，不能当作当前状态。
- `history/ios-app/docs/`：旧 UI、Siri、Live Activities、后台和构建阶段说明；截图已移除。
- `history/README.md`、`history/ios-app/README.md`：精简前完整入口，方便追溯。
- `tests/PhoneAgentTests/StatusTests.swift`：非核心 PiP 展示测试。
- `tests/PhoneAgentUITests/SiriEntryUITests.swift`：本次未修改的 Siri UI 流程测试。
- `tests/obsolete/ConversationUITests.swift`：已被设备面板替换的旧导航、调试及视觉验收证据，不直接加入当前 target。

可恢复测试：在仓库根目录运行 `INCLUDE_ARCHIVED_TESTS=1 python3 ios-app/scripts/generate_xcode_project.py`，再用默认测试脚本；完成后不带该变量重新生成工程。归档不删除用户会话、截图或配置，也不抹掉固件历史。

`firmware/`、旧 Host 测试及其脚本保留原位置，避免破坏相对引用；`tools/test_all.sh` 为旧 Host 全量入口，按需运行。本次默认测试仍包括审批记录、Live Activity 导航隔离和 Siri command 的权限/会话隔离回归，它们不是可跳过的展示测试。
