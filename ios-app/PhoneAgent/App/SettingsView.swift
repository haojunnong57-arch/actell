import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject var statusPiP: StatusPiPController
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var psk = ""
    @State private var clear = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { ControlDebugView(model: model, statusPiP: statusPiP) } label: {
                        Label("控制调试", systemImage: "slider.horizontal.3")
                    }.accessibilityIdentifier("controlDebug")
                } footer: { Text("设备连接、截图、逐步控制和状态画中画预览。") }
                Section("视觉模型 · OpenAI Chat Completions 兼容") {
                    TextField("HTTPS API 基础地址", text: $model.settings.baseURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("支持视觉和工具调用的模型 ID", text: $model.settings.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API 密钥（留空保留原值）", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("密钥仅保存到本机钥匙串，并绑定此 API 地址；不会同步或写进任务记录。更改地址后需另行保存对应密钥。没有调用模型列表或测试接口。")
                        .font(.caption)
                    Button("删除当前地址的 API 密钥", role: .destructive) { model.deleteProviderKey() }
                }
                Section("实验桥接 · 独立 PSK") {
                    SecureField("32 字节随机 PSK 的 64 位十六进制", text: $psk).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("通过可信渠道给 USB Device 固件配置相同 PSK。USB TCP 28766 使用 HMAC 认证；旧 Host TLS 入口使用 28765。不是 Apple 配对文件、证书或设备密码。App 不自动生成或传出密钥。")
                        .font(.caption)
                    Button("仅保存桥接 PSK") { model.saveUSBPSK(psk); psk = "" }.disabled(psk.isEmpty || model.running || model.stopping)
                    Button("删除桥接 PSK", role: .destructive) { model.deleteBridgeKey() }
                }
                Section("运行限制") {
                    Text("12 次模型调用 · 16 次输入 · 5 分钟\n每次模型输出最多 1024 tokens\n已报告累计 20,000 tokens 后停止\n图片最长 45 秒有效 · 每次输入均需批准")
                    Text("仅显示状态和工具进度，不展示或记录模型的内部推理。费用由模型服务决定，缺失的用量不能估为零。")
                        .font(.caption)
                }
                Section("本地记录") {
                    Text("会话保留最近 200 条消息与工具记录，包含用户消息和模型公开回复。截图不写入磁盘，会话文件开启完整文件保护并排除备份。打开历史不会自动执行工具；锁屏即停。只有本次明确启用的全屏采集 / USB 路线可在切换 App 后有限继续，其他路线离开前台即停。")
                        .font(.caption)
                    Button("清空本地会话与任务记录", role: .destructive) { clear = true }.disabled(model.running || model.stopping)
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                Text(model.status).font(.caption)
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { key = ""; psk = ""; dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { model.saveSettings(key: key, psk: psk); key = ""; psk = "" } }
            }
            .confirmationDialog("删除本机保存的任务和结果？无法在 App 内恢复。", isPresented: $clear, titleVisibility: .visible) {
                Button("清空记录", role: .destructive) { model.clearHistory() }
            }
        }
    }
}
