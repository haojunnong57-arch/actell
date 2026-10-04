import SwiftUI

@main @MainActor struct PhoneAgentApp: App {
    @StateObject private var model = PhoneAgentRuntime.shared.model
    @StateObject private var statusPiP = StatusPiPController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView(model: model, statusPiP: statusPiP, commands: PhoneAgentRuntime.shared.commands)
                .onChange(of: AgentStatusSnapshot.make(mode: model.mode, phase: model.activeRecord?.phase, running: model.running, awaitingApproval: model.approval != nil), initial: true) { _, snapshot in
                    statusPiP.update(snapshot)
                }
                .onChange(of: model.approval?.id) { _, id in
                    #if DEBUG
                    if id != nil { Task { await PhoneAgentRuntime.shared.invokeSiriFixtureIfNeeded(busy: true) } }
                    #endif
                }
                .overlay { if scenePhase != .active { Color.black.ignoresSafeArea().overlay(Text("已隐藏任务与截图").foregroundStyle(.white)) } }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.setForeground(phase == .active)
                    statusPiP.setForeground(phase == .active)
                    #if DEBUG
                    if phase == .active { Task { await PhoneAgentRuntime.shared.invokeSiriFixtureIfNeeded(busy: false) } }
                    #endif
                }
        }
    }
}
