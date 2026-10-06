import SwiftUI

@main @MainActor struct PhoneAgentApp: App {
    @StateObject private var model = PhoneAgentRuntime.shared.model
    @StateObject private var statusPiP = StatusPiPController()
    @Environment(\.scenePhase) private var scenePhase
    init() { PairingFlow.shared.registerBackgroundTask() }
    var body: some Scene {
        WindowGroup {
            ContentView(model: model, statusPiP: statusPiP, commands: PhoneAgentRuntime.shared.commands)
                .preferredColorScheme(testColorScheme)
                .onChange(of: model.displayStatus, initial: true) { _, snapshot in
                    statusPiP.update(snapshot)
                }
                .onChange(of: model.approval?.id) { _, id in
                    #if DEBUG
                    if id != nil { Task { await PhoneAgentRuntime.shared.invokeSiriFixtureIfNeeded(busy: true) } }
                    #endif
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .background { PairingFlow.shared.background() }
                    else if phase == .active { PairingFlow.shared.resume() }
                    model.setScene(phase == .active ? .active : phase == .background ? .background : .inactive)
                    model.setProtectedDataAvailable(UIApplication.shared.isProtectedDataAvailable)
                    statusPiP.setForeground(phase == .active)
                    #if DEBUG
                    if phase == .active { Task { await PhoneAgentRuntime.shared.invokeSiriFixtureIfNeeded(busy: false) } }
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                    PairingFlow.shared.cancel()
                    model.setProtectedDataAvailable(false)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                    model.setProtectedDataAvailable(true)
                }
        }
    }
    private var testColorScheme: ColorScheme? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), arguments.contains("--ui-test-dark") { return .dark }
        if arguments.contains("--ui-testing"), arguments.contains("--ui-test-light") { return .light }
        #endif
        return nil
    }
}
