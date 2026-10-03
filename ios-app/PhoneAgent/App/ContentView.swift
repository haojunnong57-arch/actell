import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject var statusPiP: StatusPiPController
    @State private var settingsOpen = false
    @State private var cloudConsent = false
    @State private var resumeAfterConsent = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Label(model.mode.label, systemImage: model.mode == .demo ? "play.rectangle" : "cable.connector")
                            .font(.headline).foregroundStyle(model.mode == .demo ? .teal : .orange)
                        Spacer()
                        if model.running { ProgressView() }
                    }
                    Text(model.status).font(.subheadline).accessibilityLabel("当前状态：\(model.status)")
                    Picker("运行模式", selection: $model.mode) { ForEach(RunMode.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented).disabled(model.running || model.stopping)
                    if model.mode == .live { bridgeCard }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("任务").font(.headline)
                        TextEditor(text: $model.goal).frame(minHeight: 95).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)).disabled(model.running || model.stopping).accessibilityLabel("任务输入")
                        Text("不要输入密钥或验证码。任务文字与结果仅在本机保留最近 20 项；截图只在内存中保留。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button { requestStart(false) } label: { Label("开始", systemImage: "play.fill").frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent).disabled(model.running || model.stopping)
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
                    Text("仅前台运行。如果 agent 与目标界面在同一台 iPhone，切换到其他 App 会中断本版运行。真实跨 App 闭环尚未验证。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
            .navigationTitle("Phone Agent")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { settingsOpen = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置").disabled(model.running || model.stopping) } }
            .sheet(isPresented: $settingsOpen) { SettingsView(model: model) }
            .alert("确认发送到模型服务", isPresented: $cloudConsent) {
                Button("同意本次运行并开始") { model.start(resuming: resumeAfterConsent) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("本次任务文字与后续截图会发送到 \(model.settings.baseURL)，使用模型 \(model.settings.model)。截图可能含个人信息；确认你有权发送，并先隐藏敏感内容。API 可能计费，最多 12 次模型调用、5 分钟，token 上限依赖服务报告，无法保证金额上限。每次输入动作仍需单独确认。")
            }
        }
    }
    private var bridgeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.bridgeStatus).font(.caption)
            Text("ESP32 v0.3 未实现 App 通道；本入口是待联调的 TLS-PSK 接口，不代表设备已可控。")
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
            Text("先核对上方截图。无法确定目标或操作涉及付款、账户安全、敏感内容、不可逆删除时，请拒绝并自行处理。审批超过 45 秒会要求新截图。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("批准一次") { model.approve(true) }.buttonStyle(.borderedProminent)
                Button("拒绝并停止", role: .destructive) { model.approve(false) }.buttonStyle(.bordered)
            }
        }.padding(16).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16)).accessibilityElement(children: .contain)
    }
    private func requestStart(_ resume: Bool) {
        if model.mode == .live || (resume && model.activeRecord?.mode == .live) { resumeAfterConsent = resume; cloudConsent = true }
        else { model.start(resuming: resume) }
    }
}
