// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ESP32ControlSettingsView: View {
    @State private var flow = PairingFlow.shared
    @State private var showingTouchTest = false
    var body: some View {
        List {
            if flow.route == .vpnLoopback {
                VPNLoopbackConfigurationSection(flow: flow)
            }
            PairingSection { showingTouchTest = true }
        }
            .navigationTitle(flow.route.controlTitle)
            .fullScreenCover(isPresented: $showingTouchTest) {
                TouchVerificationView(flow: PairingFlow.shared)
            }
            .task { PairingFlow.shared.resume() }
    }
}

private struct VPNLoopbackConfigurationSection: View {
    let flow: PairingFlow
    @State private var localAddress: String
    @State private var peerAddress: String
    @State private var error: String?
    @FocusState private var editing: Bool
    init(flow: PairingFlow) {
        self.flow = flow
        _localAddress = State(initialValue: flow.vpnConfiguration.localAddress)
        _peerAddress = State(initialValue: flow.vpnConfiguration.peerAddress)
    }
    private var changed: Bool {
        localAddress != flow.vpnConfiguration.localAddress || peerAddress != flow.vpnConfiguration.peerAddress
    }
    var body: some View {
        Section {
            LabeledContent("接口地址") {
                TextField(VPNLoopbackConfiguration.defaults.localAddress, text: $localAddress)
                    .accessibilityIdentifier("vpnLoopbackInterfaceAddress").focused($editing)
            }
            LabeledContent("对端地址") {
                TextField(VPNLoopbackConfiguration.defaults.peerAddress, text: $peerAddress)
                    .accessibilityIdentifier("vpnLoopbackPeerAddress").focused($editing)
            }
            if changed {
                Button("保存", action: save).accessibilityIdentifier("saveVPNLoopbackConfiguration")
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .multilineTextAlignment(.trailing)
        .keyboardType(.numbersAndPunctuation)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.done)
        .disabled(!flow.canChangeRoute)
        .onSubmit(save)
    }
    private func save() {
        do {
            try flow.saveVPNConfiguration(localAddress: localAddress, peerAddress: peerAddress)
            localAddress = flow.vpnConfiguration.localAddress
            peerAddress = flow.vpnConfiguration.peerAddress
            error = nil; editing = false
        } catch let failure as NCMControlError {
            if case .unavailable(let message) = failure { error = message }
        } catch {
            self.error = "请输入不同的有效 IPv4 地址"
        }
    }
}
