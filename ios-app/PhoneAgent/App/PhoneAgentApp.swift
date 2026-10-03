import SwiftUI

@main @MainActor struct PhoneAgentApp: App {
    @StateObject private var model = AgentViewModel()
    @StateObject private var statusPiP = StatusPiPController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView(model: model, statusPiP: statusPiP)
                .overlay { if scenePhase != .active { Color.black.ignoresSafeArea().overlay(Text("已隐藏任务与截图").foregroundStyle(.white)) } }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.setForeground(phase == .active)
                    statusPiP.setForeground(phase == .active)
                }
        }
    }
}
