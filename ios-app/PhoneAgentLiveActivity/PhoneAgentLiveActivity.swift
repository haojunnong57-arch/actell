import ActivityKit
import SwiftUI
import WidgetKit
import OSLog

private let activityLogger = Logger(subsystem: "com.ja1chen.PhoneAgent", category: "ActivityLifecycle")

/// This observes configuration evaluation, not whether the user saw the view.
private func traceActivityContext(_ context: ActivityViewContext<AgentActivityAttributes>, destination: String) {
    activityLogger.info("activity.widgetEvaluated destination=\(destination, privacy: .public) id=\(context.activityID, privacy: .public) run=\(context.attributes.runID.uuidString, privacy: .public) phase=\(context.state.phase.rawValue, privacy: .public) operation=\(context.state.operation?.rawValue ?? "none", privacy: .public) tools=\(context.state.completedTools) stale=\(context.isStale) contentTime=\(context.state.updatedAt.timeIntervalSince1970)")
}

@main struct PhoneAgentLiveActivityBundle: WidgetBundle {
    var body: some Widget { PhoneAgentLiveActivity() }
}

struct PhoneAgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            let _ = traceActivityContext(context, destination: "card")
            ActivityCard(context: context)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(route(context).url)
        } dynamicIsland: { context in
            let _ = traceActivityContext(context, destination: "island")
            let stale = context.isStale && !context.state.phase.isTerminal
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.isDemo ? "\(AppIdentity.displayName) · 离线演示" : AppIdentity.displayName, systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Label(stale ? "查看" : context.state.compactTitle,
                          systemImage: stale ? "exclamationmark.circle" : context.state.symbol)
                        .font(.headline).foregroundStyle(activityTint(context))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if stale || !context.state.phase.detail.isEmpty {
                            Text(stale ? "状态已过期；执行情况需在 App 核对" : context.state.phase.detail)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Link(destination: route(context).url) {
                            Label(!stale && context.state.phase == .awaitingApproval ? "查看并确认" : "查看会话", systemImage: "arrow.up.forward.app")
                                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                                .padding(.vertical, 8).background(.white.opacity(0.12), in: Capsule())
                        }.tint(.white)
                    }
                }
            } compactLeading: {
                Image(systemName: "sparkles").foregroundStyle(.cyan)
            } compactTrailing: {
                HStack(spacing: 3) {
                    Image(systemName: stale ? "exclamationmark.circle" : context.state.symbol)
                    Text(stale ? "查看" : context.state.compactTitle).lineLimit(1)
                }.font(.caption2).foregroundStyle(activityTint(context))
            } minimal: {
                Image(systemName: stale ? "exclamationmark.circle" : context.state.symbol).foregroundStyle(activityTint(context))
            }
            .widgetURL(route(context).url)
            .keylineTint(activityTint(context))
        }
    }
}

private func route(_ context: ActivityViewContext<AgentActivityAttributes>) -> AgentActivityRoute {
    AgentActivityRoute(sessionID: context.attributes.sessionID, runID: context.attributes.runID, approvalID: context.state.approvalID)
}
private func activityTint(_ context: ActivityViewContext<AgentActivityAttributes>) -> Color {
    context.isStale || context.state.phase == .awaitingApproval ? .orange : .cyan
}
private struct ActivityCard: View {
    let context: ActivityViewContext<AgentActivityAttributes>
    private var stale: Bool { context.isStale && !context.state.phase.isTerminal }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(context.attributes.isDemo ? "\(AppIdentity.displayName) · 离线演示" : AppIdentity.displayName, systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
            Label(stale ? "请回到 App" : context.state.title,
                  systemImage: stale ? "exclamationmark.circle" : context.state.symbol)
                .font(.headline).foregroundStyle(activityTint(context))
            if stale || !context.state.phase.detail.isEmpty {
                Text(stale ? "状态已过期；执行情况需在 App 核对" : context.state.phase.detail)
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Link(destination: route(context).url) {
                Label(!stale && context.state.phase == .awaitingApproval ? "查看并确认" : "查看会话", systemImage: "arrow.up.forward.app")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                    .padding(.vertical, 8).background(.white.opacity(0.12), in: Capsule())
            }.tint(.white)
        }.foregroundStyle(.white).padding(16)
    }
}
