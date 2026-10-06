// Adapted from ManifoldKit ToolInvocationView.swift and
// ToolInvocationStyle.swift (PlainToolInvocationBody), revision
// 15c9c2443770c9289c2e93c88a55bdebc4562771.
// Copyright (c) 2026 Rory Ford. MIT; full text: Licenses/ManifoldKit-MIT.txt.
// Original snapshots and hashes: Vendor/ManifoldPresentation/.
// PhoneAgent changes: app-owned data, Chinese labels, explicit denied/cancelled
// states, public parameter preview, screenshot slot, iOS 17 colors. No runtime.

import SwiftUI

struct ToolInvocationConfiguration {
    let tool: ToolStep
    var onApprove: (() -> Void)?
    var onDeny: (() -> Void)?
}

/// Manifold's presentation-only shell, adapted to the existing execution layer.
/// Closures dispatch scoped intents; this view never authorizes a device itself.
struct ToolInvocationView<Preview: View>: View {
    let configuration: ToolInvocationConfiguration
    @ViewBuilder var preview: () -> Preview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch configuration.tool.state {
            case .awaitingApproval: toolHeader
            case .requested, .running, .approved, .executing: runningView
            case .succeeded: completedView
            case .failed, .denied, .cancelled: failedView
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tool-invocation-\(configuration.tool.state.rawValue)-\(configuration.tool.name)")
    }

    private var toolHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: configuration.tool.symbol)
                .font(.body).imageScale(.small).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(configuration.tool.title)
                .font(.body).fontWeight(.regular).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if configuration.tool.state != .succeeded {
                Text(configuration.tool.state.label).font(.caption).lineLimit(1)
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(statusColor.opacity(0.10), in: Capsule())
            }
        }
    }

    private var statusColor: Color {
        switch configuration.tool.state {
        case .failed: return .red
        case .awaitingApproval, .denied: return .orange
        default: return .secondary
        }
    }

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolHeader
            parameterDisclosure
        }
    }

    private var completedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    if let arguments = configuration.tool.arguments {
                        Text("请求参数").font(.caption2).foregroundStyle(.tertiary)
                        Text(arguments).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if !configuration.tool.result.isEmpty {
                        Text("结果").font(.caption2).foregroundStyle(.tertiary)
                        Text(configuration.tool.result).font(.footnote).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            } label: {
                toolHeader
            }.tint(.secondary)
            // Completion must be readable without opening the parameter fold.
            if configuration.tool.name == "finish" {
                Text(configuration.tool.result).font(.callout).textSelection(.enabled)
            }
            preview()
        }
    }

    private var failedView: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let arguments = configuration.tool.arguments {
                    Text("请求参数").font(.caption2).foregroundStyle(.tertiary)
                    Text(arguments).font(.caption.monospaced()).textSelection(.enabled)
                }
                if !configuration.tool.result.isEmpty {
                    Text("结果说明").font(.caption2).foregroundStyle(.tertiary)
                    Text(configuration.tool.result).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
        } label: {
            toolHeader
        }.tint(.secondary)
    }

    @ViewBuilder private var parameterDisclosure: some View {
        if let arguments = configuration.tool.arguments {
            DisclosureGroup {
                Text(arguments).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            } label: {
                Text("请求参数 · \(configuration.tool.name)").accessibilityIdentifier("toolArgumentsLabel")
            }.font(.caption).tint(.secondary)
        }
    }
}

/// The current approval lives above the composer, outside conversation history.
/// Its parent supplies callbacks already scoped to the run, step and approval ID.
struct ToolApprovalCard<Preview: View>: View {
    let configuration: ToolInvocationConfiguration
    @ViewBuilder var preview: () -> Preview
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver").imageScale(.small).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(configuration.tool.title).foregroundStyle(.secondary)
                Spacer()
                Text("需要授权").font(.caption).foregroundStyle(.secondary)
            }.font(.body)
            Text(configuration.tool.detail).font(.subheadline).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: $detailsExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(configuration.tool.detail).font(.subheadline).textSelection(.enabled)
                        if let arguments = configuration.tool.arguments {
                            Text("请求参数").font(.caption).foregroundStyle(.secondary)
                            Text(arguments).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        preview()
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }.frame(height: 180).scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("approvalDetails")
            } label: {
                Text("操作详情").font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("approvalDetailsToggle")
            }.tint(.secondary)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("拒绝", role: .destructive) { configuration.onDeny?() }
                    .buttonStyle(.bordered).disabled(configuration.onDeny == nil)
                    .accessibilityIdentifier("rejectTool")
                Button("批准一次") { configuration.onApprove?() }
                    .buttonStyle(.borderedProminent).disabled(configuration.onApprove == nil)
                    .accessibilityIdentifier("approveTool")
            }.font(.subheadline).controlSize(.regular)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approvalCard")
    }
}
