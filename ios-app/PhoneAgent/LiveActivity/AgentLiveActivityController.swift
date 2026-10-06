// ActivityKit's reference type predates Sendable. All mutations below are
// serialized by tail; no Activity reference is exposed to another owner.
@preconcurrency import ActivityKit
import Foundation

struct AgentActivitySnapshot: Equatable {
    let attributes: AgentActivityAttributes
    let state: AgentActivityAttributes.ContentState
    let staleDate: Date
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.attributes.sessionID == rhs.attributes.sessionID && lhs.attributes.runID == rhs.attributes.runID &&
        lhs.attributes.isDemo == rhs.attributes.isDemo && lhs.state == rhs.state && lhs.staleDate == rhs.staleDate
    }
}

/// Single FIFO owns ActivityKit writes, including launch reconciliation. Neither
/// suspension nor a Live Activity grants the executor background time.
@MainActor final class AgentLiveActivityController: ObservableObject {
    @Published private(set) var notice: String?
    private var foreground = true
    private let enabled: Bool
    private var activities: [UUID: Activity<AgentActivityAttributes>] = [:]
    private var tail: Task<Void, Never>?
    private var latest: [UUID: AgentActivitySnapshot] = [:]

    init(enabled: Bool = true) {
        self.enabled = enabled
        guard enabled else { return }
        // A new process has no resumable continuation. Never adopt an old run.
        let orphans = Activity<AgentActivityAttributes>.activities
        tail = Task {
            for orphan in orphans {
                var state = orphan.content.state
                state.phase = .interrupted; state.approvalID = nil; state.updatedAt = Date()
                await orphan.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(300)))
            }
        }
    }

    func setForeground(_ active: Bool) {
        foreground = active
        // Leave a truthful interrupted card on the island while away. On
        // return, end it; the executor is already cancelled in either case.
        if active { for snapshot in latest.values where snapshot.state.phase.isTerminal { submit(snapshot) } }
    }

    func submit(_ snapshot: AgentActivitySnapshot) {
        latest[snapshot.attributes.runID] = snapshot
        guard enabled else { return }
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.apply(snapshot)
        }
    }

    private func apply(_ snapshot: AgentActivitySnapshot) async {
        let run = snapshot.attributes.runID
        if snapshot.state.phase.isTerminal {
            if let current = activities[run] {
                if !foreground, snapshot.state.phase == .interrupted {
                    // One final update, no heartbeat or background task. Ending
                    // here would immediately remove the useful return-to-app
                    // island. The user/system can dismiss it; foreground or the
                    // next process launch ends it without resuming execution.
                    await current.update(ActivityContent(state: snapshot.state, staleDate: nil))
                } else {
                    await current.end(ActivityContent(state: snapshot.state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(300)))
                    activities.removeValue(forKey: run)
                    latest.removeValue(forKey: run)
                }
            } else { latest.removeValue(forKey: run) }
            return
        }
        // Suppress queued obsolete updates and never start after cancellation.
        guard latest[run] == snapshot else { return }
        let content = ActivityContent(state: snapshot.state, staleDate: snapshot.staleDate)
        if let activity = activities[run] {
            guard activity.activityState == .active || activity.activityState == .stale else { return }
            await activity.update(content)
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                notice = "实时活动未开启；仍可在 App 内查看与确认"; return
            }
            do {
                activities[run] = try Activity.request(attributes: snapshot.attributes, content: content, pushType: nil)
                notice = nil
            } catch { notice = "实时活动暂不可用；仍可在 App 内查看与确认" }
        }
    }
}
