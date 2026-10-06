import SwiftUI
import UIKit

struct ControlDebugView: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject var statusPiP: StatusPiPController
    @State private var cloudConsent = false
    @State private var resumeAfterConsent = false
    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Label(model.mode.label, systemImage: model.mode == .demo ? "play.rectangle" : "cable.connector")
                            .font(.headline).foregroundStyle(model.mode == .demo ? .teal : .orange)
                        Spacer()
                        if model.running { ProgressView() }
                    }
                    Text(model.status).font(.subheadline).accessibilityLabel("当前状态：\(model.status)").accessibilityIdentifier("debugStatus")
                    Picker("运行模式", selection: $model.mode) { ForEach(RunMode.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented).disabled(model.running || model.stopping)
                    if model.mode == .live {
                        if DeviceControlRoute.current == .ncmDeveloper {
                            NavigationLink { ESP32ControlSettingsView() } label: {
                                HStack { Text("ESP32 控制"); Spacer(); Text(PairingFlow.shared.ready ? "已连接" : "未连接").foregroundStyle(.secondary) }
                            }
                            Text("截图和输入经 ESP32 NCM 连接。先配对并连接，再开始任务；保持 App 在前台。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else { USBCapturePanel(model: model, capture: model.capture); bridgeCard }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("任务").font(.headline)
                        TextEditor(text: $model.goal).frame(minHeight: 95).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)).disabled(model.running || model.stopping).accessibilityLabel("任务输入")
                        Text("不要输入密钥或验证码。任务文字与结果仅在本机保留最近 20 项；截图只在内存中保留。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button { requestStart(false) } label: { Label("开始", systemImage: "play.fill").frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent).disabled(model.running || model.stopping).accessibilityIdentifier("debugStart")
                            Button(role: .destructive) { model.stop() } label: { Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered).disabled(!model.running)
                        }
                        if model.canResume {
                            Button("重新开始上次任务（获取新截图）") { requestStart(true) }.font(.subheadline)
                        }
                    }
                    StatusPiPPanel(model: model, controller: statusPiP)
                    screenshotCard
                    if let approval = model.approval { approvalCard(approval) }
                    if let record = model.activeRecord {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("动作记录").font(.headline)
                            ForEach(record.receipts.suffix(12)) { item in
                                HStack(alignment: .top) {
                                    Text(item.date, style: .time).monospacedDigit().foregroundStyle(.secondary)
                                    Text(item.message)
                                }.font(.caption)
                            }
                            if !record.result.isEmpty { Text(record.result).font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)) }
                            if record.mode == .live {
                                Text("已报告 tokens：\(record.reportedTokens)\(record.usageComplete ? "" : "（部分用量未报告）")。这是用量观察值，不是费用硬上限。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let warning = model.storageWarning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
                    Text(DeviceControlRoute.current == .ncmDeveloper ? "当前 NCM 控制会话在 App 进入后台后关闭；实际输入效果以新截图为准。" : "采集有效时可在后台执行本次 USB 控制任务；旧 TLS 设备工具仍仅前台可用并逐次确认。真实跨 App 闭环仍需实测。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
            .navigationTitle("控制调试")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { model.enterControlDebug() }
            .onDisappear {
                model.leaveControlDebug()
            }
            .alert("确认发送到模型服务", isPresented: $cloudConsent) {
                Button("同意本次运行并开始") { model.start(resuming: resumeAfterConsent) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("本次任务文字与后续截图会发送到 \(model.settings.baseURL)，使用模型 \(model.settings.model)。开始后，ESP32 控制会按本次任务自动执行普通点击和拖动，无需逐次确认；你可随时停止。截图可能含个人信息，请先隐藏敏感内容。API 可能计费，最多 12 次模型调用，token 上限依赖服务报告，无法保证金额上限。")
            }
    }
    private var bridgeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.bridgeStatus).font(.caption)
            Text("旧 USB Host 方案的实验 TLS-PSK 入口；Device NCM 方案使用上方连接按钮。")
                .font(.caption).foregroundStyle(.orange)
            HStack { Button("开始监听") { model.listen() }; Button("断开") { model.disconnect() } }.buttonStyle(.bordered).disabled(model.running || model.stopping)
        }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    private var screenshotCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("最新截图").font(.headline); Spacer(); if model.latestImage?.isDemo == true { Text("合成画面").font(.caption.bold()).foregroundStyle(.teal) } }
            if let image = model.latestImage, let uiImage = UIImage(data: image.png) {
                Image(uiImage: uiImage).resizable().scaledToFit().frame(maxHeight: 360).frame(maxWidth: .infinity)
                    .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 16)).accessibilityLabel(image.isDemo ? "演示用合成屏幕，不是真机截图" : "已校验的最新设备截图")
                Text("\(image.width) × \(image.height) · \(image.capturedAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 16).fill(.quaternary).frame(height: 170)
                    .overlay(Label("尚未获取截图", systemImage: "photo").foregroundStyle(.secondary))
            }
        }
    }
    private func approvalCard(_ approval: Approval) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("确认一次动作", systemImage: "hand.raised.fill").font(.headline)
            Text(approval.detail)
            Text("先核对上方截图。无法确定目标或操作涉及付款、账户安全、敏感内容、不可逆删除时，请拒绝并自行处理。本次确认请求 45 秒内有效，从请求出现时开始计时。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("批准一次") { model.approve(true) }.buttonStyle(.borderedProminent)
                Button("拒绝这次动作", role: .destructive) { model.approve(false) }.buttonStyle(.bordered)
            }
        }.padding(16).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16)).accessibilityElement(children: .contain)
    }
    private func requestStart(_ resume: Bool) {
        if model.mode == .live || (resume && model.activeRecord?.mode == .live) { resumeAfterConsent = resume; cloudConsent = true }
        else { model.start(resuming: resume) }
    }
}

private struct USBCapturePanel: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject var capture: ScreenCaptureController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("iOS 27 · USB Device").font(.headline)
            Text(capture.status).font(.caption)
            Text("查看屏幕使用 App 全屏采集，无需连接 ESP32。点击或拖动才需要 USB HID。开始模型任务后，Agent 会按需发送截图，无需额外开启许可。")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("screenCaptureRouteHelp")
            HStack {
                Button("授权全屏采集") { capture.present() }.disabled(capture.active || capture.busy || !capture.isSupported || model.running || model.stopping).accessibilityIdentifier("startScreenCapture")
                Button("停止采集", role: .destructive) { model.stopCapture() }
            }.buttonStyle(.bordered)
            Button("仅在本机预览截图") { model.previewCapture() }.disabled(!capture.active || model.running || model.stopping || model.previewingCapture)
            HStack {
                Button(model.usbConnectionStatus.isReady ? "USB 已连接" : (model.usbConnectionStatus.isConnecting ? "正在连接…" : "连接 USB NCM")) { model.connectUSB() }
                    .disabled(model.running || model.stopping || model.usbConnectionStatus.isConnecting || model.usbConnectionStatus.isReady).accessibilityIdentifier("connectUSBNCM")
                if model.usbConnectionStatus.isConnecting {
                    ProgressView()
                    Button("取消") { model.disconnect() }.accessibilityIdentifier("cancelUSBConnection")
                }
            }
            Text(model.usbConnectionStatus.message)
                .font(.callout).foregroundStyle(model.usbConnectionStatus.isFailure ? Color.red : Color.primary)
                .accessibilityIdentifier("usbConnectionStatus")
            USBDiagnosticsControls(model: model)
            Text("USB 免 PSK，无需配对。可访问此 USB 网络的其他程序也能发送命令；本 App 仅在你开始任务后执行该任务内的输入。")
                .font(.caption).foregroundStyle(.secondary)
            Text("PhoneAgent 自身和其他 App 均可操作。普通点击和拖动按本次任务授权执行，不要求切到后台，也不比对画面是否保持不变。采集任务可在切换 App 后继续；锁屏、采集结束或 USB 故障会停止输入。")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("screenCaptureBackgroundHelp")
            Text(model.backgroundStatus).font(.caption)
            Text("先在 iPhone 的 USB 以太网设置中使用 192.168.7.2 / 255.255.255.0，路由器和 DNS 留空。采集授权不会自动发送图像；预览只在本机显示。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}


private struct USBDiagnosticsControls: View {
    @ObservedObject var model: AgentViewModel
    @State private var showingLog = false
    @State private var report = ""
    @State private var copied = false

    private func refresh() { report = model.usbDiagnosticReport() }
    private func copy() {
        refresh()
        // Only this explicit button writes the clipboard; never read it.
        UIPasteboard.general.string = report
        copied = true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("复制诊断日志", action: copy).accessibilityIdentifier("copyUSBDiagnostics")
                Button("查看日志") { refresh(); showingLog = true }.accessibilityIdentifier("showUSBDiagnostics")
            }.buttonStyle(.bordered)
            if copied { Text("诊断日志已复制").font(.caption).accessibilityIdentifier("usbDiagnosticsCopied") }
            Text("保留本次 App 运行最近 600 条采集与 USB 诊断，含首帧状态及丢帧原因；失败后可直接复制。重启 App 会清空，不含截图、任务正文或密钥。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showingLog) {
            NavigationStack {
                ScrollView {
                    Text(report).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                        .accessibilityIdentifier("usbDiagnosticsReport")
                }
                .navigationTitle("采集与 USB 诊断日志")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("完成") { showingLog = false } }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("刷新", action: refresh).accessibilityIdentifier("refreshUSBDiagnostics")
                        Button("复制", action: copy).accessibilityIdentifier("copyUSBReport")
                    }
                }
            }
        }
    }
}
