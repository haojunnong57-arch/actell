import ActivityKit
import SwiftUI
import WidgetKit

@main struct PhoneAgentLiveActivityBundle: WidgetBundle {
    var body: some Widget { PhoneAgentLiveActivity() }
}

struct PhoneAgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            ActivityCard(context: context)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(route(context).url)
        } dynamicIsland: { context in
            let stale = context.isStale && !context.state.phase.isTerminal
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.isDemo ? "离线演示" : "Phone Agent", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("已返回 \(context.state.completedTools) 步").font(.caption).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) {
                    Label(stale ? "查看" : context.state.compactTitle,
                          systemImage: stale ? "exclamationmark.circle" : context.state.symbol)
                        .font(.headline).foregroundStyle(activityTint(context))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(stale ? "状态已过期；执行情况需在 App 核对" : context.state.phase.detail)
                            .font(.caption).foregroundStyle(.secondary)
                        Link(destination: route(context).url) {
                            Label(!stale && context.state.phase == .awaitingApproval ? "查看并确认" : "查看记录", systemImage: "arrow.up.forward.app")
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
                Label(context.attributes.isDemo ? "Phone Agent · 离线演示" : "Phone Agent", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("已返回 \(context.state.completedTools) 步").font(.caption).monospacedDigit()
            }
            Label(stale ? "请回到 App" : context.state.title,
                  systemImage: stale ? "exclamationmark.circle" : context.state.symbol)
                .font(.headline).foregroundStyle(activityTint(context))
            Text(stale ? "状态已过期；执行情况需在 App 核对" : context.state.phase.detail)
                .font(.caption).foregroundStyle(.white.opacity(0.7))
            Link(destination: route(context).url) {
                Label(!stale && context.state.phase == .awaitingApproval ? "查看并确认" : "查看记录", systemImage: "arrow.up.forward.app")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                    .padding(.vertical, 8).background(.white.opacity(0.12), in: Capsule())
            }.tint(.white)
        }.foregroundStyle(.white).padding(16)
    }
}
