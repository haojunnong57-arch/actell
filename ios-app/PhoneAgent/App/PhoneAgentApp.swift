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
                // A covered backing layer supplies AVKit without occupying the UI.
                .background(alignment: .bottom) {
                    StatusSampleBufferView(displayLayer: statusPiP.displayLayer)
                        .frame(width: 320, height: 180)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .task {
                    statusPiP.observeTasks(in: model)
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--task-pip-probe") {
                        model.start()
                        for step in 0..<5 {
                            try? await Task.sleep(for: .seconds(10))
                            statusPiP.recordTaskProbe(step: step, running: model.hasBusySessions,
                                liveActivities: model.liveActivities.activeCountForProbe)
                            if step == 0 { UIApplication.shared.perform(NSSelectorFromString("suspend")) }
                        }
                    } else { await PairingFlow.shared.runBackgroundProbeIfRequested() }
                    #endif
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
                    // Inactive is a transition, not a request to show PiP.
                    if phase == .active { statusPiP.setForeground(true) }
                    else if phase == .background { statusPiP.setForeground(false) }
                    #if DEBUG
                    if phase == .active { Task { await PhoneAgentRuntime.shared.invokeSiriFixtureIfNeeded(busy: false) } }
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                    PairingFlow.shared.cancel()
                    statusPiP.setTaskRunning(false)
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
