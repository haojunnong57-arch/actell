import SwiftUI

@main @MainActor struct PhoneAgentApp: App {
    @StateObject private var model: AgentViewModel = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") || ProcessInfo.processInfo.environment["PHONEAGENT_ISOLATED_TESTS"] == "1" {
            let sessions = ConversationStore(inMemory: true)
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-tool-error") {
                sessions.create(mode: .live)
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: ToolErrorFixtureProvider(), bridge: UnavailableBridge()))
            }
            // Existing demo history keeps UI regression tests offline without
            // exposing a demo-creation route in the production conversation UI.
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-demo-history") {
                sessions.create(mode: .demo)
            }
            return AgentViewModel(sessions: sessions, loadPersistentState: false,
                                  liveActivitiesEnabled: ProcessInfo.processInfo.arguments.contains("--ui-test-live-activity"))
        }
        #endif
        return AgentViewModel()
    }()
    @StateObject private var statusPiP = StatusPiPController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView(model: model, statusPiP: statusPiP)
                .onChange(of: AgentStatusSnapshot.make(mode: model.mode, phase: model.activeRecord?.phase, running: model.running, awaitingApproval: model.approval != nil), initial: true) { _, snapshot in
                    statusPiP.update(snapshot)
                }
                .overlay { if scenePhase != .active { Color.black.ignoresSafeArea().overlay(Text("已隐藏任务与截图").foregroundStyle(.white)) } }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.setScene(phase == .active ? .active : phase == .background ? .background : .inactive)
                    model.setProtectedDataAvailable(UIApplication.shared.isProtectedDataAvailable)
                    statusPiP.setForeground(phase == .active)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                    model.setProtectedDataAvailable(false)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                    model.setProtectedDataAvailable(true)
                }
        }
    }
}
