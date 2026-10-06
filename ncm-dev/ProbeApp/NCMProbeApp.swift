// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main struct NCMProbeApp: App {
    init() { PairingFlow.shared.registerBackgroundTask() }
    var body: some Scene { WindowGroup { NCMProbeView() } }
}
struct NCMProbeView: View {
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack { ESP32ControlSettingsView() }
        .task { PairingFlow.shared.resume() }
        .onChange(of: phase) { _, value in
            if value == .background { PairingFlow.shared.background() }
            else if value == .active { PairingFlow.shared.resume() }
        }
    }
}
#Preview { NCMProbeView() }
