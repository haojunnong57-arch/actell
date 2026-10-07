# 屏幕流停止与任务完成提醒（2026-10-07）

## 屏幕控制会话

旧的 `Session.stop_touch_media` 只丢弃本地 DisplayService/HID 连接、接收任务和视频缓存，没有发出 `stopmediastream`。App 的 `control.mediaReleased` 日志因此只证明本地释放，不能证明 iPhone 已结束远程查看。

通过 Mac 对本次诊断自己建立的流进行对照：

- `stopAll=false, identifiers=[LocalSSRC]` 返回 `serverInfo`，会话仍为 1。
- `stopAll=false, identifiers=[RemoteSSRC]` 返回 `stoppedStreams`，会话变为 0。
- 停止请求使用全新的 DisplayService 连接，不复用启动流的 RemoteXPC 连接。

修复按协商响应保存本流的 RemoteSSRC，异步发出定向停止，并校验返回的 `serverInfo.sessions` 已不含该流。无效回复和仍残留的本流不能报告成功。保持认证隧道，保留其他任务排队与设备所有权；不发送全局 `stopAll`。设置页的单次截图／点击验证完成后也调用相同释放链路。

原始诊断数据在忽略目录 `.build/last-run-investigation/`：`session-release-events.log`、`media-start-answer.json`、`media-stop-LocalSSRC.json`、`media-stop-RemoteSSRC.json`、`media-live-stop-after.json`。不提交设备地址、会话全文或画面数据。

## 完成提醒

旧实现收到 completed 后直接调用 `Activity.end(.after(...))`，未先发送带提醒的完成更新。五分钟保留策略适用于结束后的锁屏卡片，无法提供持续的完成灵动岛。

现在后台完成时通过 [ActivityKit update 的 alertConfiguration](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) 发送一次“任务已完成”提醒，保留完成状态至回到 App 或下一轮任务开始。其他已有任务的进度更新不会收起这条完成活动。前台完成、用户主动停止仍正常结束活动；后台失败／中断保留真实终态，不再继续更新心跳。新进程清理遗留活动时保留已有完成／停止等终态，只有未结束的任务才改为中断。

后续后台完成提醒缺失的排查中，标题与间距改动没有删除提醒分支，但发现收尾时序缺口：任务把完成状态交给异步 FIFO 后，立即结束执行资格和运行状态，音频／PiP 观察者可在 ActivityKit 更新返回前开始停止媒体。通过挂起模拟 ActivityKit 的完成更新，修复前可确定性复现“更新未返回但任务与执行资格已结束”。现提前提交终态，并等待已排队更新返回，再释放执行资格、控制服务和任务媒体；等待期间的主动停止仍按 generation 拦截旧收尾，不恢复完成状态。新增终态请求与无活动可更新的诊断事件。此处验证证明收尾顺序已修复；没有读取用户这次真机日志，不能据此认定其现场原因。

### 2026-10-08 真机定位：音频运行资格不等于活动更新资格

用户重新允许连接真机后，先导出故障现场再安装诊断版。原任务在 2026-10-07 23:50:47（本地时间）提交 completed，ActivityKit 返回后才停止媒体和控制服务，没有后续 working 覆盖；因此收尾等待已生效，并非本次卡在“处理中”的原因。

同一时间的 `liveactivitiesd` 明确记录 `Process is only playing background media so is forbidden to update activity: 5178`，随后是 `Client is not permitted to update activity`。该进程在前台和刚进入后台时获准更新，23:50:12 仍获准，23:50:14 起被拒绝。后半段进度与最终完成都没进入系统；App 能继续执行与 ActivityKit 能接受更新是两个不同条件。`Activity.update` 无抛错且正常返回，不能当作展示成功。

三轮离线真机实验分别验证每次更新申请 UIKit 短时任务、仅终态申请，以及仅终态申请后等待 200ms 排除异步断言竞争。三者在媒体后台状态下均被 `liveactivitiesd` 拒绝；最后一轮 ID 有效，`backgroundTimeRemaining` 为最大浮点值，系统内容仍停在 thinking。未把这些无效方案留在产品中，未新增延迟、重试或系统持续任务申请。仅保留 requested/observed/activityState 回读日志，并将 `terminalPresented` 日志改名为 `terminalUpdateReturned`，避免把请求返回误报为展示成功。读回状态也不是灵动岛渲染确认。

证据保存在 `.build/activity-stuck-investigation/`：原始 App 日志 `device-background-before.log`，系统判定 `activity-daemon.log`，三轮实时系统日志 `activity-live.jsonl`、`activity-terminal-only-live.jsonl`、`activity-grant-probe-live.jsonl`，以及对应 `device-background-*-probe.log` / `device-background-terminal-only-final.log`。完整系统 trace 导出后仅按 trace/timesync 重建本地 Info.plist 读取索引；没有更改 trace。首次传输中断的目录不作为证据。

音频保活模式仍保留。针对已证实的媒体后台资格拒绝，可再评估其他获系统批准的后台执行来源或 ActivityKit 的 APNs 更新；这不表示所有完成展示故障都已归因于此。系统持续任务会带自己的状态卡片，PiP 又会影响灵动岛展示优先级，不能用两者冒充已解决自定义活动展示。用户选择后续再处理，当前不接入新更新路线。

### 同日复核：不能把后台资格拒绝视为所有完成故障的唯一原因

用户指出多次观察到中间状态持续变化、只有完成状态缺失。重新逐条对齐已导出的 App、`liveactivitiesd`、`chronod` 与 SpringBoard 日志后，确认两轮真实任务的结果不同：

- 23:49:43 开始的任务于 23:49:50 进入后台；23:50:12.756 的 working（已完成 18 次工具调用）仍被接收并刷新。23:50:14 起，后续 working／thinking／executing 都遭媒体后台资格拒绝，包括 23:50:46.796 的最后 working 和 23:50:47.460 的 completed。因此这一轮并非只丢最后一步，且拒绝发生在停止媒体之前。
- 00:00:41 开始的任务于 00:00:42 进入后台，00:01:01.087 的 working 与 00:01:01.653 的 completed 都获准更新。终态 payload `3C0D4F4A-7775-4300-B397-ACC4A0D0B595` 携带“任务已完成”提醒、无 staleDate，00:01:01.656 被 chronod 接收；活动扩展于 00:01:01.771 完成处理，00:01:01.774 记录 reload succeeded，SpringBoard 于 00:01:01.679 报告已展示提醒。后台终态保持 active，直到 00:01:32 返回 App 才结束；未见后续进度覆盖终态。

后者证明完成更新本身没有一律被系统禁止，日志也没有显示这一轮终态在扩展刷新环节失败。系统的“已展示提醒”和刷新成功不是对用户实际看到的像素内容的验证，不能据此否定其观察。现有证据能解释第一轮，但不足以把“每次仅最终完成不更新”归结为同一个原因；特别是“紧邻完成前的进度已实际展示、完成未展示”仍缺少同一轮的视觉与系统日志对照。不新增兜底或改变保活路线来掩盖这一未验证边界。

本次仅复查已有导出记录并更正文档，没有重新安装、启动诊断任务或改动运行逻辑。新增摘录为 `.build/activity-stuck-investigation/second-real-task-daemon.log`、`second-real-task-display.log`；前一轮的 App 与全进程记录分别为 `device-background-before.log`、`activity-system-complete.log`。

### 最新现场：通知中心卡片被五分钟保留策略移除

用户随后反馈通知中心也没有卡片。2026-10-08 00:41 导出当前 App 的有限生命周期日志，再读取本轮系统记录，确认最后一轮活动为 `15E376DE-F63F-4801-BB38-3342D3B6C460`，App 进程为 5330：

- 00:30:30.285，liveactivitiesd 创建活动并置为 active，chronod 随后多次成功刷新活动扩展。
- 00:31:00.274，最后一条获准更新进入系统；00:31:01.216 起，后续进度被判定为仅播放后台媒体并拒绝。00:31:16.433 的 completed 同样被拒绝，App 回读仍为 thinking。这一轮再次证明更新停住发生在最终完成之前，不是只拒绝 completed。
- 00:31:45.105，App 已回到前台，主动调用 end；系统明确记录 `should be discarded at ...16:36:45 +0000`。这一时间来自代码的 `Date().addingTimeInterval(300)`，不是系统随机回收。
- 00:31:45.228，结束状态的活动扩展刷新成功。
- 00:36:45.110，liveactivitiesd 记录该活动 `should be discarded now`，随后 `Activity discarded`；00:36:45.132，chronod 收到 dismissed 并移除订阅。其他几轮旧卡片也各自在自己的五分钟期限被移除。

因此这次读取现场时通知中心为空，有独立且明确的到期移除原因；不能据此认定新任务没有创建活动，或授权被关闭。此证据解释的是最近已完成任务的卡片消失，不等于验证用户在执行期间实际看到的画面。已另行询问缺失发生在执行期间还是结束之后，未把未回答的问题当作已确认。

本次没有修改卡片保留策略、安装 App 或启动额外任务。证据在 `.build/activity-missing-investigation/`：`device-before.log`、`activity-daemon.log`、`activity-display.log`。两次系统归档在解包末尾均报 `ReadError: unexpected end of data`；保留导出错误记录，只使用成功解码且明确存在的创建、拒绝、结束和移除事件，未用归档中的缺失记录证明某事件没有发生。读取索引重建未修改原 trace 内容。

移除实验后的 12 项活动测试全部通过，无签名与签名 iPhoneOS 构建通过，普通 App 已重新安装并不带诊断参数启动。实验阶段默认核心回归 320 项中 319 通过，唯一失败仍是已有的 Siri `alwaysAllowed` 与测试期望 `requiresLocalDeviceAuthentication` 不一致；未改动该策略或断言。最终产物与日志见 `final-activity-tests.log`、`final-unsigned-build.log`、`final-signed-build.log`、`final-install.log`、`restored-normal-launch.log`。

### 再次定位：早期更新资格的来源、到期边界与完成 API 差异

进一步对齐 runningboardd 断言后，已找到上述“前面能更新、后面完成不能更新”的具体时间边界。liveactivitiesd 会为 App 建立 `com.apple.sessionkitd / DeliverEvent` 断言，日志名称为 `Activity change delivery` 或 `Push token delivery`。它与 App 的音频播放断言不同，也不是本项目主动申请的 UIKit 短时任务。在本机这些轮次中，该断言约 30 秒后到期；到期后仅剩媒体执行资格时，ActivityKit 更新开始被拒绝。

| 真实任务 | 系统投递断言 | 最后获准更新 | 首次拒绝 | 完成结果 |
| --- | --- | --- | --- | --- |
| 23:49 开始 | 23:49:42.512 建立，23:50:12.766 超时 | 23:50:12.756 | 23:50:14.030 | 23:50:47.460 被拒绝 |
| 00:00 开始 | 00:00:41.515 建立，00:01:11.515 撤销 | 完成更新仍在有效期内 | 此处不作缺失事件推断 | 00:01:01.653 获准，约 20 秒完成 |
| 00:30 开始 | 00:30:30.291 建立，00:31:00.291 撤销 | 00:31:00.274 | 00:31:01.216 | 00:31:16.433 被拒绝 |

这补齐了“为什么一开始可以”的原因。对于已证实的失败轮次，系统没有专门拒绝 completed；较晚的普通进度也停止进入系统，旧的“处理中”仍显示。约 30 秒是本次设备的多轮实测值，不能当成所有 iOS 版本公开保证的固定限制，也不能据此否定尚未取得对应日志的其他视觉故障。

另有一条独立路径：最新 App 日志显示 00:48:32 恢复 active，00:48:54 完成时 `foreground=true`，代码直接 end，00:48:57 才再进入后台。这条前台完成分支本来就不请求完成提醒，而会收起灵动岛；不是后台更新拒绝。这里只陈述 App 生命周期日志，不推断用户当时实际看到的屏幕。

随后用临时离线入口作两轮真机对照：不请求模型、不调用 ESP32 工具，保持同一音频播放器一直运行；同时创建两条活动，第一条约 20 秒完成，第二条约 35 秒先发普通进度再发完成，随后单独 end。两轮均复现以下差异：

- 约 20 秒的 completed update 获准，系统收到带提醒的 payload；第二轮扩展明确处理了展开灵动岛的完成 payload。
- 系统 DeliverEvent 断言到期后，约 35 秒的普通 update 和 completed update 都被 `Process is only playing background media so is forbidden to update activity` 拒绝。音频此时仍在播放。
- 两秒后在同一后台、同一媒体资格下，`end(completed, .after(...))` 获准。系统收到最终 payload、将活动置为 ended，App 回读为 completed/ended，音频直到此后才停止。end 能提交最终内容，但结束后的灵动岛会收起，锁屏／通知中心卡片按保留策略存在；它不能代替“完成后仍在灵动岛展示并提醒”的产品要求。

第二轮明确的系统时间为：01:03:17.881 投递断言超时，01:03:25.447 普通更新拒绝，01:03:25.460 完成更新拒绝，01:03:27.503 end 接收，01:03:27.509 系统状态变为 ended。不存在完成前停止音频或重新调回 working 的时序。

因此当前后台完成分支为保留完成灵动岛而选择 update，恰好受媒体后台更新限制；与可获准的 end 不是相同系统行为。诊断没有把实现改回立即 end，也没有接入用户已暂缓的 APNs／系统持续任务路线，没有增加重试或延迟。临时入口和状态控制改动已移除，普通版本重新构建并恢复安装。

证据在忽略目录 `.build/activity-final-investigation/`：`first-two-run-assertions.log`、`successful-run-assertion-end.log`、`transitions.log`、`device-preinstall.log`、两轮 `differential-live.jsonl` / `differential-end-live.jsonl` 与 `probe-events-final.log` / `probe-end-final.log`。第一轮实时采集未覆盖 end，关于系统接收 end 的结论使用完整覆盖该阶段的第二轮记录；不使用缺失日志作否定结论。无签名与签名普通构建及恢复安装日志为 `normal-unsigned-build.log`、`normal-signed-build.log`、`normal-install.log`、`normal-launch.log`。

### 证据边界：尚不能解释用户观察到的所有“只丢完成”场景

用户再次明确指出多次看到临近结束仍有进度变化。前述对照只证明已匹配轮次的拒绝边界，不能据此认定用户之前看到的所有变化均在 30 秒内，更不能把约 30 秒当作任务总时长限制。00:48 那一轮运行约 44 秒，43 秒处仍有更新，但其生命周期记录显示已恢复前台；它不能证明持续后台长任务的完成失败。当前导出的有限日志没有新一轮可以与用户该观察直接对应，整体问题仍未定位完毕。

新增普通运行诊断按活动 ID、run ID、写入序号和内容时间关联以下事件：

- `activity.writeBegin`：App 准备调用 update 或 end，包含 phase、operation、工具数量和是否请求提醒。
- `activity.systemUpdateReturned` / `activity.systemEndReturned`：API 返回时的读回值，仅表示调用返回。
- `activity.contentObserved` / `activity.stateObserved`：持续订阅 ActivityKit 提供的系统内容和生命周期变化，区别于立即读回。
- `activity.widgetEvaluated`：扩展分别为 card / island 计算界面时收到的 phase、operation、stale 与内容时间。它证明界面配置收到什么数据，不证明用户看到了相应像素。
- `activity.scene` 和带 run ID 的 `activity.terminalRequested`：核对完成分支采用的前后台状态。

App 和扩展均写入 `com.ja1chen.PhoneAgent / ActivityLifecycle` 系统日志；App 同时保留原有限生命周期文件。只记录状态元数据，不记录任务正文、工具参数、图片或凭据。诊断没有改变更新资格申请、提醒、活动结束、重试或执行收尾行为。后续必须把同一轮最后一次已显示的进度与 completed 对齐：如前者进入扩展而后者未进入，继续区分 App 提交、系统接收和扩展刷新；不能继续用另一轮离线超时替代这条证据。

新增记录通过现有隔离内存流式任务验证，没有调用模型或设备操作：活动 `23290CA1-F3E3-410A-B3BB-5F389FCCA369` 在 01:20:06 的请求内容时间 `1791393606.247833` 同时出现在 `contentObserved` 和 card / island 的 `widgetEvaluated` 中。后续系统明确拒绝普通更新；01:21:30 的 working 和 completed 请求已发出，读回仍是 thinking，完成返回后才停止音频。回到前台结束该测试活动后，01:22:52 的 completed 又同时进入系统内容观察与 end 返回。这证明新记录能关联提交和系统内容变化，不表示本轮复现了用户的“只有完成缺失”。名义 90 秒流式任务实测约 104 秒自然结束，已恢复不带测试参数的普通 App。

本次无签名与签名 iPhoneOS 构建通过，12 项活动测试通过；默认核心回归 319 项中 318 通过，唯一失败仍为工作区已有 Siri `alwaysAllowed` 策略与 `requiresLocalDeviceAuthentication` 断言不一致，未改动该策略或断言。证据：`.build/activity-final-correlation/` 内的 `correlation-live.jsonl`、`device-final-probe.log`、构建／安装／普通启动日志，以及 `.build/validation/core.J771zt/Tests.xcresult`。没有取得新的真实任务视觉对照，问题保持未解决。

提交前核对当前全部改动时，同步了 Siri 直接执行入口的旧策略断言：创建任务为 `alwaysAllowed`，查询状态和停止仍为 `requiresLocalDeviceAuthentication`；前台与受保护数据的实际启动条件保持。随后 319 项默认 App 核心测试全部通过，Rust 后端 42 项、协议库 176 项以及默认 PA3 回归通过，最终无签名 iPhoneOS 构建通过。日志位于 `.build/commit-validation/`。这次验证不改变上述实时活动问题尚未解决的结论。

工具与思考折叠卡片的上下内边距从每侧 4 pt 调整为 2 pt，消息列表间隔保留。后续整行点击样式曾加入 44 pt 最小标题行高，抵消了紧凑布局；现移除这项固定最小行高，标题按内容自然排布。模拟器进一步确认展开正文的文本选择区域延伸至标题下缘，缩小标题后会拦截收起点击；现通过正文的 `contentShape(Rectangle())` 限制交互范围，保留整行点击与单次展开／收起行为，默认字体下标题约为 20.3 pt。

活动标题从 Bundle 读取产品显示名，主 App 与活动扩展共用 `APP_DISPLAY_NAME`（当前为“执言”）。活动卡片和展开的灵动岛移除“已返回 N 步”；完成标题改为“任务已完成”，移除完成状态的核对说明及其空白行；导航入口改为“查看会话”。系统后台任务标题也使用相同产品名。

## 验证

- 311 项 App 核心测试通过：`.build/validation/core.Z30Nhz/Tests.xcresult`。新增完成提醒只发一次、前台确认后结束，以及其他已有任务不提前收起完成活动的覆盖。
- Rust 后端 42 项、协议库 176 项测试通过；跨 Swift/C ABI/Rust 回环链路 36 项通过；PA3 默认回归通过。
- iPhoneOS 无签名与已有开发签名构建通过，新版已安装。
- ESP32 真机链路连续收到 3 张 1179 × 2556 截图；停止时记录 `control.mediaReleased peerConfirmed=true connectionRetained=true`。随后从 Mac 独立查询 iPhone，`sessions.count=0`、`running=false`，确认服务端屏幕流已结束。证据：`scoped-stop-device-probe.log`、`scoped-stop-device-events.log`、`media-server-before.json`（最后一次只读查询）。
- 真机 30 秒离线后台任务记录 `activity.terminalPresented phase=completed alerted=true`，返回前台后才记录 `activity.ended phase=completed foreground=true`。完成提醒 API 与保留时机已验证，实际灵动岛显示仍以用户观察为准。
- 后续活动文案调整通过 311 项核心测试（`.build/validation/core.iNcg0a/Tests.xcresult`）及无签名 iPhoneOS 构建；主 App 和扩展的构建产物 `CFBundleDisplayName` 均为“执言”。按用户要求，这次文案调整未安装或验证真机。
- 卡片间距修复通过 311 项核心测试（`.build/validation/core.nqQ8OC/Tests.xcresult`）及无签名 iPhoneOS 构建。最终样式的两个模拟器 UI 用例通过（`.build/validation/spacing-final.2X293d/Tests.xcresult`），覆盖标题空白处／箭头连续单击展开收起、长思考与工具展开时保留滚动位置；未使用真机。
- 完成更新收尾顺序：新增测试在修复前确定性失败（`.build/validation/activity-order-before.GgXZ1C/Tests.xcresult`），修复后的 12 项 LiveActivity 测试全部通过，含更新等待与等待期间主动停止的两个新增用例；无签名 iPhoneOS 构建通过。完整核心回归共 319 项，318 通过，1 项 `SessionCommandTests.testAuthenticationAndForegroundPolicy` 失败，原因是工作区另有 Siri 启动 Intent 改为 `alwaysAllowed`，该测试仍断言 `requiresLocalDeviceAuthentication`；本次未改动这项策略或测试（`.build/validation/core.liagvP/Tests.xcresult`）。按用户要求未安装或测试真机。
