import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var clear = false
    var body: some View {
        NavigationStack {
            Form {
                Section("本地记录") {
                    Text("会话保留最近 200 条消息与工具记录。截图只在内存中保留。会话文件开启完整文件保护并排除备份，打开历史不会自动重放动作。")
                        .font(.caption)
                    Button("清空本地会话与任务记录", role: .destructive) { clear = true }
                        .disabled(model.running || model.stopping)
                }
                Section("后台执行") {
                    Text("采集有效时可在切换 App 后继续。锁屏、系统终止采集、手动停止或设备连接故障会停止输入。普通模型任务的后台运行由系统分配。")
                        .font(.caption)
                }
                if let warning = model.storageWarning { Text(warning).foregroundStyle(.orange) }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .confirmationDialog("删除本机保存的任务和结果？无法在 App 内恢复。", isPresented: $clear, titleVisibility: .visible) {
                Button("清空记录", role: .destructive) { model.clearHistory() }
            }
        }
    }
}
