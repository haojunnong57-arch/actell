# 源码导入记录

导入日期：2026-10-03。目标为 `<workspace>/with-esp`。使用此前已在该 Mac 下载并解包的源码，没有再次下载，也没有更换执行环境。

## 原始包

| 文件 | Library ID / 版本 | 字节数 | SHA-256 |
| --- | --- | ---: | --- |
| [esp32-iphone-coredevice-protocol-v0.3.tar.gz](../archives/esp32-iphone-coredevice-protocol-v0.3.tar.gz) | `libfile_7db76be09f0c8191886db04b4e553b4e` / 2 | 362648 | `79702eba413323c38610d1b714e99b85137cfe5a0a13446790af50f643637420` |
| [PhoneAgent-iOS-source.zip](../archives/PhoneAgent-iOS-source.zip) | `libfile_41f5d3e188988191a0712d42c21da5a8` / 2 | 54367 | `57922ed3703d6a0288e5a9dfb014440959d356fd16853faae68b3b9ce138e434` |

原始包完整保存在 `archives/`。解包前检查了路径和条目类型；恢复连接后重新比较解包内容与归档，每个文件完全一致。固件清单包含 158 个源文件，加清单自身共 159 个文件；iOS 清单包含 30 个源文件，加清单自身共 31 个文件。188 项原始清单哈希全部通过。

## 路径映射

| 归档路径 | 正式路径（相对于 with-esp） |
| --- | --- |
| `esp32-iphone-bridge/firmware/**` | `firmware/**` |
| `esp32-iphone-bridge/tests/**` | `tests/**` |
| `esp32-iphone-bridge/tools/**` | `tools/**` |
| `esp32-iphone-bridge/docs/**` | `docs/**` |
| `esp32-iphone-bridge/README.md` | `README.firmware.md` |
| `esp32-iphone-bridge/SOURCE_MANIFEST.json` | `SOURCE_MANIFEST.firmware.json` |
| 固件包其他根文件 | 同名根文件，包括 `.gitignore`、`LICENSE`、`THIRD_PARTY.md` |
| `ios-agent-app/**` | `ios-app/**` |

190 个导入文件均保持原字节内容。两个改名仅用于给总览 README 与来源标识留出位置，不改源码。原文中固件顶层 `SOURCE_MANIFEST.json` 的提法在此对应 `SOURCE_MANIFEST.firmware.json`；iOS 和 zlib vendor 内同名清单仍在原位置。

逐文件来源、正式路径、大小、SHA-256 和归档身份保存在 [import-manifest.json](import-manifest.json)。可用 `python3 tools/verify_import.py` 从 `with-esp` 重跑归档和所有导入文件校验。

## 非破坏性处理与工程状态

正式导入前，`with-esp` 只有本任务的下载暂存目录及 Finder 的 `.DS_Store`。没有同名源码冲突，`.DS_Store` 保留。所有新增源码、文档、校验脚本与测试输出都在 `with-esp`；没有写入 `app-only`，也没有操作其他本地 Codex 会话。

本次两轮检查均未发现工程/祖先 AGENTS.md，工程根目录没有 README 或 `.agents/skills`。`git status --short` 确认这里不是 Git 仓库。本次没有初始化仓库，无法生成正常工作树 Git diff；另将原包按正式路径映射，与导入文件运行 `git diff --no-index --exit-code`，返回 0，无内容或执行权限差异。见 source-diff.log（本地文件 `local-validation/source-diff.log`，已忽略）。

完成比较后，已清除本任务创建且逐项核对过的 `.library-import-hwelziyz` 暂存目录；两份原始归档及下载时记录的文件元数据随原文件移动至 `archives/`。

新增整理文件为顶层 `README.md`、本导入记录、`STATUS.md`、`LOCAL-VALIDATION.md`、`import-manifest.json`、`local-validation/` 输出及 `tools/verify_import.py`；不覆盖原始云端测试记录。
