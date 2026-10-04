// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main struct NCMProbeApp: App {
    var body: some Scene { WindowGroup { NCMProbeView() } }
}
struct NCMProbeView: View {
    @Environment(\.scenePhase) private var phase
    @State private var client = NCMProbeClient()
    @State private var backend = NativeDeveloperServices()
    @State private var job: Task<Void, Never>?
    @State private var busy = false
    @State private var reply: DiagnosticReply?
    @State private var message = "等待手动诊断"
    @State private var deviceIdle = false
    var body: some View {
        NavigationStack {
            List {
                Section("实验范围") {
                    Text("通过 S3 的 NCM 网络检查开发者服务入口。此页面仅执行只读诊断。")
                    Text("原生后端 ABI：\(NativeDeveloperServices.linkedABIVersion)。控制会话需要显式提供已授权的内存身份；此页面不读取或生成凭据。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("已确认设备空闲，可运行只读诊断", isOn: $deviceIdle)
                    Text("请先安装本分支诊断固件。使用 IPv4 192.168.7.2/24，网关与 DNS 留空；此 App 不改网络设置。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("NCM 诊断") {
                    action("检查 S3 通道", command: .status)
                    action("IPv4 发现", command: .discoverIPv4)
                    action("IPv6 发现", command: .discoverIPv6)
                    action("Lockdown QueryType", command: .lockdownQueryType)
                }.disabled(!deviceIdle || busy)
                if let reply, let endpoints = reply.endpoints, let generation = reply.generation {
                    Section("发现候选（5 秒内有效）") {
                        ForEach(endpoints) { endpoint in
                            Button("\(endpoint.service) · IPv\(endpoint.family) · \(endpoint.port)") {
                                run(.probe(generation: generation, index: endpoint.index))
                            }.disabled(busy || !deviceIdle || endpoint.service == "pairable-host")
                        }
                    }
                }
                Section("最近结果") {
                    if busy { ProgressView("诊断中") }
                    Text(message).textSelection(.enabled).accessibilityIdentifier("diagnosticResult")
                    Text("TCP、问候或服务列表均不能证明截图和输入成功。结果仅留在内存中。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if busy { Button("停止", role: .cancel) { job?.cancel(); client.cancel() } }
                }
            }
            .navigationTitle("NCM 开发者通道")
        }
        .onChange(of: phase) { _, value in
            if value == .background { job?.cancel(); client.cancel(); backend.close(); reply = nil }
        }
        .onChange(of: deviceIdle) { _, value in
            if !value { job?.cancel(); client.cancel(); backend.close(); reply = nil }
        }
        .onDisappear { job?.cancel(); client.cancel(); backend.close() }
    }
    private func action(_ title: String, command: DiagnosticCommand) -> some View {
        Button(title) { run(command) }
    }
    private func run(_ command: DiagnosticCommand) {
        guard deviceIdle, !busy else { return }
        busy = true; reply = nil; message = "正在执行只读探测"
        job = Task { @MainActor in
            defer { busy = false; job = nil }
            do {
                let value = try await client.request(command)
                try Task.checkCancellation()
                reply = value
                message = "阶段：\(value.layer)\n结果：\(value.result)\nTCP 已连接：\(value.tcpConnected == true ? "是" : "未确认")\n认证：未完成\n截图 / 输入：未执行"
                if let code = value.osError, code != 0 { message += "\n系统错误：\(code)" }
                if let version = value.wireVersion, version != 0 { message += "\n问候版本：\(version)" }
            } catch is CancellationError { message = "已停止" }
            catch { message = (error as? NCMError)?.rawValue ?? "诊断失败" }
        }
    }
}
#Preview { NCMProbeView() }
