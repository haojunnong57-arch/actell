import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject var statusPiP: StatusPiPController
    @ObservedObject private var sessions: ConversationStore
    @ObservedObject private var liveActivities: AgentLiveActivityController
    let commands: SessionCommandService
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [UUID] = []
    @State private var search = ""
    private enum Panel: String, Identifiable { case settings, providers, device; var id: String { rawValue } }
    @State private var panel: Panel?
    init(model: AgentViewModel, statusPiP: StatusPiPController, commands: SessionCommandService) {
        self.commands = commands
        self.model = model; self.statusPiP = statusPiP; self.sessions = model.sessions
        self.liveActivities = model.liveActivities
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
                                VStack(alignment: .leading, spacing: 3) {
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
                                    }
                                    Text(session.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 16))
                            .swipeActions { if !model.isRunning(in: session.id) { Button("删除", role: .destructive) { sessions.delete(session.id) } } }
                        }
                        if visible.isEmpty { ContentUnavailableView.search(text: search) }
                    }.listStyle(.plain)
                }
            }
            .navigationTitle("会话")
            .searchable(text: $search, prompt: "搜索会话")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { panel = .settings } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置") }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { panel = .providers } label: { Image(systemName: "server.rack") }
                        .accessibilityLabel("服务商").accessibilityIdentifier("openProviders")
                    Button { panel = .device } label: { Image(systemName: "iphone.gen3.radiowaves.left.and.right") }
                        .accessibilityLabel("设备控制").accessibilityIdentifier("deviceControls")
                }
                ToolbarItem(placement: .topBarTrailing) { Button(action: createConversation) { Image(systemName: "square.and.pencil") }.accessibilityLabel("新建会话").accessibilityIdentifier("newConversationToolbar") }
            }
            .navigationDestination(for: UUID.self) { id in
                ConversationView(model: model, conversationID: id,
                    openSettings: { panel = .settings }, openDevice: { panel = .device }, openProviders: { panel = .providers }).id(id)
            }
            .sheet(item: $panel) { item in
                switch item {
                case .settings: SettingsView(model: model)
                case .providers: ProvidersView(model: model)
                case .device: DeviceControlsView(model: model)
                }
            }

        }
        .onOpenURL { url in model.openActivityURL(url) }
        .onChange(of: model.activityNavigation) { _, destination in
            guard let destination else { return }
            panel = nil
            path = [destination.route.sessionID]
        }
        .alert("实时活动链接", isPresented: Binding(get: { model.activityLinkError != nil }, set: { if !$0 { model.activityLinkError = nil } })) {
            Button("知道了") { model.activityLinkError = nil }
        } message: { Text(model.activityLinkError ?? "") }
        .safeAreaInset(edge: .bottom) {
            if let notice = liveActivities.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(8) }
        }
        .onChange(of: commands.pendingRoute, initial: true) { _, _ in routePreparedTask() }
        .onChange(of: model.running) { _, _ in routePreparedTask() }
        .onChange(of: model.stopping) { _, _ in routePreparedTask() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { routePreparedTask() } }
        .onChange(of: panel) { _, value in if value == nil { routePreparedTask() } }
    }
    private func routePreparedTask() {
        guard scenePhase == .active, panel == nil, let id = commands.pendingRoute,
              path.last != id else { return }
        if case .open(let destination) = try? commands.perform(SessionCommand(.open, sessionID: id, source: .app)) {
            path = [destination]
        }
    }
    private func createConversation() {
        path.append(model.createConversation(mode: .live))
    }
}
