import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var clear = false
    @State private var clearAssets = false
    @State private var assetStatus = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("USB 连接") {
                    NavigationLink { ESP32ControlSettingsView() } label: {
                        Label("ESP32 控制", systemImage: "cable.connector")
                    }.accessibilityIdentifier("esp32ControlSettings")
                    Text("主任务截图与输入使用此处建立的 NCM 认证连接。")
                        .font(.caption)
                }
                Section("扩展能力") {
                    NavigationLink { SkillsView(model: model, store: model.skills) } label: {
                        Label("技能", systemImage: "books.vertical")
                    }.accessibilityIdentifier("manageSkills")
                }
                Section("本地记录") {
                    Text("一般消息保留最近 200 条；带附件的历史不自动裁剪。新截图与已选入附件的原文件保存在本机，打开历史不会重放动作。旧版本未保存的截图无法恢复。会话与附件开启完整文件保护并排除备份。")
                        .font(.caption)
                    Button("清空本地会话与任务记录", role: .destructive) { clear = true }
                        .disabled(model.running || model.stopping)
                    Button("清理未引用附件", role: .destructive) { clearAssets = true }
                        .disabled(model.running || model.stopping).accessibilityIdentifier("clearUnusedAttachments")
                    Text("原图不会自动淘汰。清理只删除已不被任何消息或草稿引用的文件；需要释放已引用资源时，先明确删除对应历史。")
                        .font(.caption)
                    if !assetStatus.isEmpty { Text(assetStatus).font(.caption) }
                }
                Section("后台执行") {
                    Text(DeviceControlRoute.current == .ncmDeveloper ? "当前 NCM 截图与输入需保持 App 在前台；进入后台或锁屏会关闭控制会话。原截图与 USB HID 链路保留，暂未提供切换开关。" : "采集有效时可在切换 App 后继续。锁屏、系统终止采集、手动停止或设备连接故障会停止输入。普通模型任务的后台运行由系统分配。")
                        .font(.caption)
                }
                if let warning = model.storageWarning { Text(warning).foregroundStyle(.orange) }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .confirmationDialog("删除本机保存的任务和结果？无法在 App 内恢复。", isPresented: $clear, titleVisibility: .visible) {
                Button("清空记录", role: .destructive) { model.clearHistory() }
            }
            .alert("清理未引用附件？", isPresented: $clearAssets) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) {
                    Task {
                        do { assetStatus = "已清理 \(try await model.clearUnreferencedAttachments()) 个未引用文件" }
                        catch { assetStatus = "未能清理附件；原文件保留" }
                    }
                }
            } message: { Text("现有消息与草稿引用的原图和文件会保留。未引用文件删除后无法恢复。") }
        }
    }
}
