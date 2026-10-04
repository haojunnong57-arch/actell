import ActivityKit
import Foundation

/// This is the complete system-visible payload. Never add user text, tool
/// arguments, image identifiers, screenshots, endpoints or receipts here.
struct AgentActivityAttributes: ActivityAttributes {
    let sessionID: UUID
    let runID: UUID
    let isDemo: Bool

    struct ContentState: Codable, Hashable {
        var phase: Phase
        var completedTools: Int
        var approvalID: UUID?
        var updatedAt: Date
    }

    enum Phase: String, Codable, Hashable {
        case thinking, working, awaitingApproval, approved, executing
        case completed, stopped, interrupted, blocked

        var isTerminal: Bool { [.completed, .stopped, .interrupted, .blocked].contains(self) }
        var title: String {
            switch self {
            case .thinking: return "正在请求模型"
            case .working: return "正在处理工具"
            case .awaitingApproval: return "等待确认"
            case .approved: return "已收到批准"
            case .executing: return "正在发送动作"
            case .completed: return "本轮已结束"
            case .stopped: return "已停止"
            case .interrupted: return "已中断"
            case .blocked: return "需要查看"
            }
        }
        var symbol: String {
            switch self {
            case .awaitingApproval: return "hand.raised.fill"
            case .approved: return "checkmark.shield"
            case .completed: return "checkmark.circle"
            case .stopped: return "stop.circle"
            case .interrupted, .blocked: return "exclamationmark.circle"
            default: return "sparkles"
            }
        }
        var detail: String {
            switch self {
            case .awaitingApproval: return "回到 App 查看详情并确认本次动作"
            case .approved: return "批准已接收，尚未发送动作"
            case .executing: return "发送不代表成功，请核对设备结果"
            case .interrupted: return "返回 App 查看记录；不会自动重试"
            case .stopped: return "如动作已发出，请核对设备"
            case .completed: return "请回到 App 核对结果"
            case .blocked: return "回到 App 查看原因"
            default: return "仅在 App 前台执行"
            }
        }
    }
}

/// A navigation address, never an authorization token. Approval UUID identifies
/// the exact pending action; only the app's authoritative record can resolve it.
struct AgentActivityRoute: Equatable {
    let sessionID: UUID
    let runID: UUID
    let approvalID: UUID?

    var url: URL {
        var components = URLComponents()
        components.scheme = "phoneagent"; components.host = "activity"
        components.path = "/session/\(sessionID.uuidString)/run/\(runID.uuidString)"
        if let approvalID { components.queryItems = [URLQueryItem(name: "approval", value: approvalID.uuidString)] }
        return components.url!
    }
    init(sessionID: UUID, runID: UUID, approvalID: UUID? = nil) {
        self.sessionID = sessionID; self.runID = runID; self.approvalID = approvalID
    }
    init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "phoneagent", c.host == "activity", c.user == nil,
              c.password == nil, c.port == nil, c.fragment == nil else { return nil }
        let parts = c.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "session", parts[3] == "run",
              let session = UUID(uuidString: String(parts[2])), let run = UUID(uuidString: String(parts[4])) else { return nil }
        let items = c.queryItems ?? []
        guard items.count <= 1, items.allSatisfy({ $0.name == "approval" && UUID(uuidString: $0.value ?? "") != nil }) else { return nil }
        self.init(sessionID: session, runID: run, approvalID: items.first.flatMap { UUID(uuidString: $0.value ?? "") })
    }
}
