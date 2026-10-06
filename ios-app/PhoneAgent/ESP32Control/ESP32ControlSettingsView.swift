// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ESP32ControlSettingsView: View {
    @State private var showingTouchTest = false
    var body: some View {
        List { PairingSection { showingTouchTest = true } }
            .navigationTitle("ESP32 控制")
            .fullScreenCover(isPresented: $showingTouchTest) {
                TouchVerificationView(flow: PairingFlow.shared)
            }
            .task { PairingFlow.shared.resume() }
    }
}
