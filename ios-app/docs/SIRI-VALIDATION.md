# Siri 入口验证记录

日期：2026-10-04。方案与复现命令见 [SIRI-ENTRY.md](SIRI-ENTRY.md)。

## 环境与已完成检查

- Xcode 27.0（27A266a），deployment target iOS 17.0。
- 独立使用现有 iPhone 17 / iOS 27 模拟器 `<SIMULATOR_ID>`。
- DerivedData：`ios-app/.build/SiriEntry`；依赖检出：`.build/SiriPackages`。
- `CODE_SIGNING_ALLOWED=NO`；未安装真机、创建开发者资源或改变全局 xcode-select。
- 构建成功；App Intents 元数据包含三个动作、创建任务的必填 String、明确的本机认证和主 App 执行目标。
- zh-Hans/en App Shortcut 字符串及 NLU 语料生成成功。Bundle ID 保持 `com.ja1chen.PhoneAgent`，显示名为 `PhoneAgent`。
- 提取元数据摘要（本地文件 `siri-validation/intent-metadata.json`，已忽略）来自构建产物，另有 XCTest 对认证与运行模式的语义断言。

## 自动测试

导航与可访问性修复后，定向测试 **12 个命令单元测试 + 5 个 Siri UI 测试全部通过**，进程退出码 0。

- 定向日志（本地文件 `../.build/SiriEvidence/route-fixes.log`，已忽略）
- 定向 xcresult（本地文件 `../.build/SiriEvidence/route-fixes.xcresult`，已忽略）

覆盖：

| 场景 | 验证层 |
| --- | --- |
| 空白、超长、合法听写文本 | 单元测试 |
| 同 commandID 重试、同文本新调用、冷启动持久身份 | 单元测试 |
| 保存失败、损坏归档不覆盖、不虚报已保存 | 单元测试 |
| 忙碌时只保存草稿、不取消旧 run | mock runner + 实际 Intent.perform UI |
| 停止使用捕获的 session/run，过期或重复停止不伤新 run | mock runner + 原 SwiftAgentKit 离线 loop |
| 取消前未落盘、取消后不自动运行、已提交草稿不恢复执行 | 单元测试 |
| 认证不代替执行同意；无 cloudConsent 不允许 send | 原 model + 单元测试 |
| 状态只返回有限公开标签 | 单元测试 |
| 冷启动恢复识别文本、热 Intent 路由、明确确认开始 | 持久测试目录 + 模拟器 UI |
| 取消草稿后重启不路由 | 模拟器 UI |
| 确认任务后仍要求工具批准；UI 拒绝和停止保持有效 | 原审批 UI + 离线 DemoProvider/DemoBridge |

最终代码的完整回归：**57 个单元测试 + 13 个 UI 测试，共 70 项全部通过，0 失败**。`test-without-building` 复用导航修复后已成功编译的相同二进制，进程退出码 0，日志结束为 `TEST EXECUTE SUCCEEDED`。

- 最终 XCTest 摘要（本地文件 `siri-validation/final-test-summary.json`，已忽略）
- 最终完整日志（本地文件 `../.build/SiriEvidence/final-regression.log`，已忽略）
- 最终完整 xcresult（本地文件 `../.build/SiriEvidence/final-regression.xcresult`，已忽略）

13 个 UI 用例包括全部 8 个原有会话回归和 5 个新增 Siri 用例；57 个单元用例包括 12 个新增命令测试。截图来自同一最终实现此前已通过的定向测试，不把早期失败截图当作通过证据。

## 截图证据

全部来自已通过的定向测试，均已目视检查；原始图片没有裁剪或重绘。使用 DEBUG 离线 fixture，图中的任务和屏幕均为合成演示。真实模型会话样式用于验证生产入口，不表示调用过真实模型。

- [草稿已保存，尚未开始](siri-validation/siri-01-persisted-draft.png)
- [退出进程后恢复到同一草稿](siri-validation/siri-02-cold-route.png)
- [确认任务后仍需批准工具](siri-validation/siri-03-tool-approval-still-required.png)
- [拒绝后原轮次结束](siri-validation/siri-04-denied.png)
- [前台 Intent.perform 打开草稿](siri-validation/siri-05-warm-intent.png)
- [忙碌时原审批保留](siri-validation/siri-06-busy-keeps-approval.png)
- [停止旧 run 后打开延期草稿](siri-validation/siri-07-deferred-draft.png)

来源、设备、测试名称和 SHA-256 清单（本地文件 `siri-validation/screenshots.json`，已忽略）。

## 验证中发现并处理的问题

- 相同导航栈位置替换会话时，SwiftUI 可能保留旧会话的 StateObject。导航目的视图现在显式绑定 `.id(sessionID)`；忙碌延期后的 UI 用例已验证新会话与新草稿。
- 确认卡父容器的 accessibilityIdentifier 会覆盖子项标识。现在识别文本和取消按钮各自保留可访问性标识。
- 最早使用的 iPhone 18 Pro 同时被另一独立 worktree 测试同 Bundle App，出现替换安装及测试进程 signal kill。此后切换到独立 iPhone 17；早期受干扰结果不作为通过证据。
- 本机 Xcode 测试后诊断收集仍可能报告找不到 simctl（全局路径是 CommandLineTools），但 XCTest 能完成并生成结果包。请以结果包和 xcodebuild 退出码判断测试结果。
- 运行日志仍出现 `Modifying state during view update` 警告（在原有会话发送路径和忙碌用例均可见）。本轮未扩展修改原 UITextView 输入组件；该警告没有造成已通过用例的断言失败，不宣称构建或运行零警告。

## 分开列出的未验证项

1. **真机中文 Siri**：实际唤醒、应用名称识别、自由文本追问、语音取消和重复口述。UI 测试直接调用 Intent.perform，不等于 Siri 声学/NLU 测试。
2. **真机锁屏/身份认证**：Face ID/Touch ID、解锁取消、文件保护在锁定设备上的系统行为；声明与元数据验证不代替锁屏验收。
3. **Personal Team 签名**：保留既有签名设置，但本轮仅无签名模拟器构建，未注册 App ID、开新 entitlement、申请 profile 或安装真机。
4. **真实模型 + ESP 链路**：没有消费模型额度、读取真实密钥来发请求或控制实体设备。原逐次审批的离线回归通过，不代替端到端硬件验收。
5. **旧版系统运行**：编译目标兼容 iOS 17，但本轮运行环境仅 iOS 27；iOS 17–26 的 Siri/Shortcuts 实际行为仍需分别验证。
6. **与 Live Activities 合并**：两个独立分支未合并，未验证组合后的 App 生命周期。没有依赖或写入 Live Activities 的未合并源码。
