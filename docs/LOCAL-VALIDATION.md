# 本次 Mac 验证（2026-10-03）

执行目录为 `/Users/developer/Developer/AI/ios-use/with-esp`。下述结果来自恢复连接后实际运行的命令，日志位于 [local-validation/](local-validation/)。它们与原归档中的云端 [test-results.txt](test-results.txt)、[build-results.txt](build-results.txt) 分开保存。

## 环境

- 系统 `python3`：3.9.6；已有独立 Python：3.12.13。
- Xcode：27.0，27A266a；Apple Swift：6.4，arm64-apple-macosx27.0.0。
- 默认 `xcode-select` 仍指向 CommandLineTools；本次仅对命令设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，未切换系统配置。
- PATH 中未发现 XcodeGen、CMake、idf.py。导入的 iOS 包只有 `project.yml`，没有已生成的 `.xcodeproj`、SPM checkout 或 `Package.resolved`。
- 所检查的现成 Python 3.12 环境缺少 construct、hyperframe、PyYAML、tree-sitter 和 tree-sitter-swift；未安装新依赖。

## 通过

| 检查 | 实际结果 | 输出 |
| --- | --- | --- |
| 原始归档 | 两个版本 2 包的大小与指定 SHA-256 全部匹配 | [来源](IMPORT.md) |
| 解包与原始清单 | 190 个解包文件逐字节匹配归档；188 项原始源文件哈希通过 | [导入清单](import-manifest.json) |
| 正式导入 | `python3 tools/verify_import.py`：190 个正式文件逐字节匹配原包，零源码内容修改；按映射路径进行 Git no-index 比较返回 0 | [import-integrity.log](local-validation/import-integrity.log)、[source-diff.log](local-validation/source-diff.log) |
| `test_host.sh` | 分块 I/O、期限、有界 framing、plist fixture、20000 次 malformed-plist 变异通过 | [test_host.log](local-validation/test_host.log) |
| `test_usb_descriptors.sh` | USB 描述符选择、截断/歧义、20000 次变异通过 | [test_usb_descriptors.log](local-validation/test_usb_descriptors.log) |
| `test_lockdown_probe.sh` | 45 项合成回复 fixture、50000 次变异/随机输入、精确 QueryType 请求独立解码通过 | [test_lockdown_probe.log](local-validation/test_lockdown_probe.log) |
| `test_lockdown_session.sh` | 111 项合成回复 fixture、50000 次变异、192 次分块模拟会话、11793942 个断言通过 | [test_lockdown_session.log](local-validation/test_lockdown_session.log) |
| iOS 独立协议测试 | `python3 ios-app/scripts/test_contract.py`：12/12 通过，不执行 Swift 或真实桥接 | [ios-contract.log](local-validation/ios-contract.log) |
| Swift 语法 | Apple `swiftc -frontend -parse`：15 个 `.swift` 文件通过，无诊断；不是类型检查 | [swift-parse.log](local-validation/swift-parse.log) |
| 静态文件检查 | 隐私 plist 解析通过；17 个 Python 文件 AST 解析、23 个 shell 脚本 `bash -n`、iOS project.yml 的源码目录存在性检查通过 | [layout-checks.json](local-validation/layout-checks.json)、[ios-test-summary.json](local-validation/ios-test-summary.json) |

四组 C 测试沿用原脚本的 ASan/UBSan 标志，`CC=clang`；合成 fixture 所需 `PYTHON` 指向现成 Python 3.12。没有读取真实配对记录、证书或密钥。原脚本设置 `ASAN_OPTIONS=detect_leaks=0`，因此不把这些结果算作 LeakSanitizer 验证。

可复现命令（在 `with-esp`）：

```sh
python3 tools/verify_import.py
python3 ios-app/scripts/test_contract.py
CC=clang bash tools/test_host.sh
CC=clang bash tools/test_usb_descriptors.sh
CC=clang bash tools/test_lockdown_probe.sh
CC=clang bash tools/test_lockdown_session.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swiftc -frontend -parse $(rg --files ios-app -g '*.swift')
```

## 受阻或未运行

- **USBmux 宿主机测试受阻：**`CC=clang bash tools/test_usbmux.sh` 返回 1。Apple Clang 将原 Linux 参数 `-no-pie` 报为 unused argument，且脚本启用 `-Werror`；测试二进制未运行。这不是 USBmux 逻辑测试失败的证据。为保留导入源码原样，本次没有改脚本或关闭警告。见 [test_usbmux.log](local-validation/test_usbmux.log)。
- **完整固件测试与 S3 交叉编译未运行：**完整套件需要 ESP-IDF / mbedTLS / lwIP、CMake 及 Python 第三方模块，并有上述宿主平台参数问题；现成工具不足。本次部分 C 检查不替代云端全套测试或固件目标构建。
- **iOS Xcode 构建、Swift 类型检查、SPM 解析、13 项 XCTest、Simulator 与真机未运行：**尚无生成工程，XcodeGen 及 SPM 依赖未就绪；没有安装或下载依赖。15 文件语法解析不能证明这些步骤通过。
- **原 iOS `scripts/check_source.py` 未运行：**需要当前缺少的 PyYAML / tree-sitter 依赖；本次 Apple 语法解析和 plist 解析只覆盖其部分目标，未将整个静态断言脚本标为通过。
- **Git 工作树 diff 不可用：**`git status --short` 返回 128，`git diff --stat` 返回 129，均因指定目录不是 Git 仓库。本次没有初始化 Git；导入的差异以字节比较及归档映射为依据。
- 没有执行刷机、手机安装、真实配对、实体设备连接、模型 API 调用、两端联调或板上内存测量。

## 文档与布局检查

最终检查涵盖顶层说明、固件文档、iOS 文档的本地 Markdown 链接；结果及计数见 [layout-checks.json](local-validation/layout-checks.json)。导入源码内容不变，固件相对路径由四组实际编译测试覆盖；iOS `project.yml` 的两处 source 目录均存在。通过这些检查仍不代表硬件或 App 功能验收完成。
