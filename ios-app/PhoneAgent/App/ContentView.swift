import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject var statusPiP: StatusPiPController
    @ObservedObject private var sessions: ConversationStore
    @State private var path: [UUID] = []
    @State private var search = ""
    @State private var settingsOpen = false
    init(model: AgentViewModel, statusPiP: StatusPiPController) {
        self.model = model; self.statusPiP = statusPiP; self.sessions = model.sessions
    }
    private var visible: [AgentConversation] {
        sessions.conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.preview.localizedCaseInsensitiveContains(search) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sessions.conversations.isEmpty {
                    VStack(spacing: 22) {
                        Spacer()
                        Image(systemName: "sparkle").font(.system(size: 46, weight: .light)).foregroundStyle(.blue)
                            .frame(width: 98, height: 98).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 30))
                        VStack(spacing: 8) {
                            Text("从一个想法开始").font(.title2.bold())
                            Text("与 Agent 对话，查看执行过程，\n在需要时确认下一步。").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }
                        Button(action: createConversation) { Label("新建会话", systemImage: "plus").padding(.horizontal, 20).padding(.vertical, 6) }
                            .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("newConversation")
                        Spacer(); Spacer()
                    }.padding(28).frame(maxWidth: .infinity)
                } else {
                    List {
                        if let warning = sessions.warning { Label(warning, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
                        ForEach(visible) { session in
                            NavigationLink(value: session.id) {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(spacing: 8) {
                                        Text(session.title).font(.headline).lineLimit(1)
                                        if session.phase == .awaitingApproval, model.approval(in: session.id) != nil {
                                            Text("待确认").font(.caption2).foregroundStyle(.orange)
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(.orange.opacity(0.10), in: Capsule())
                                                .fixedSize()
                                                .accessibilityIdentifier("conversation-needs-approval")
                                        }
                                        Spacer(minLength: 0)
                                        Text(session.updatedAt, style: .date).font(.caption2).foregroundStyle(.tertiary)
                                            .fixedSize()
                                    }
                                    Text(session.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }.padding(.vertical, 8)
                            }
                            .swipeActions { if !model.isRunning(in: session.id) { Button("删除", role: .destructive) { sessions.delete(session.id) } } }
                        }
                        if visible.isEmpty { ContentUnavailableView.search(text: search) }
                    }.listStyle(.plain)
                }
            }
            .navigationTitle("会话")
            .searchable(text: $search, prompt: "搜索会话")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { settingsOpen = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置") }
                ToolbarItem(placement: .topBarTrailing) { Button(action: createConversation) { Image(systemName: "square.and.pencil") }.accessibilityLabel("新建会话").accessibilityIdentifier("newConversationToolbar") }
            }
            .navigationDestination(for: UUID.self) { id in
                ConversationView(model: model, conversationID: id) {
                    if model.running { model.stop(message: "打开设置，本轮执行已中断", interrupted: true) }
                    settingsOpen = true
                }
            }
            .sheet(isPresented: $settingsOpen) { SettingsView(model: model, statusPiP: statusPiP) }
        }
    }
    private func createConversation() {
        path.append(model.createConversation(mode: .live))
    }
}
