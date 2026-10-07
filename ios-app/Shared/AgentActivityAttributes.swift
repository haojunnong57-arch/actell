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
        // Optional preserves decoding of activities created before operation icons.
        var operation: Operation? = nil
        var symbol: String { phase.isTerminal ? phase.symbol : (operation?.symbol ?? phase.symbol) }
        var title: String {
            [.working, .executing].contains(phase) ? (operation?.title ?? phase.title) : phase.title
        }
        var compactTitle: String {
            switch phase {
            case .thinking: return "思考"
            case .working, .executing: return operation?.compactTitle ?? "处理"
            case .awaitingApproval: return "确认"
            case .approved: return "批准"
            case .completed: return "完成"
            case .stopped: return "停止"
            case .interrupted: return "中断"
            case .blocked: return "查看"
            }
        }
    }

    enum Operation: String, Codable, Hashable {
        case screenshot, apps, tap, drag, home, launch, text, skill, processing
        static func tool(_ name: String) -> Self {
            switch name {
            case "screenshot": return .screenshot
            case "list_apps": return .apps
            case "tap": return .tap
            case "drag": return .drag
            case "home": return .home
            case "launch_app": return .launch
            case "type_text": return .text
            case "load_skill": return .skill
            default: return .processing
            }
        }
        var symbol: String {
            switch self {
            case .screenshot, .apps: return "inset.filled.rectangle.and.person"
            case .tap, .drag, .home, .launch, .text: return "pointer.arrow.ipad"
            case .skill: return "book.closed"
            case .processing: return "gearshape"
            }
        }
        var compactTitle: String {
            switch self {
            case .screenshot: return "查看"
            case .apps: return "查询"
            case .tap: return "点击"
            case .drag: return "滑动"
            case .home: return "主页"
            case .launch: return "启动"
            case .text: return "输入"
            case .skill: return "技能"
            case .processing: return "处理"
            }
        }
        var title: String {
            switch self {
            case .screenshot: return "正在查看屏幕"
            case .apps: return "正在查询 App"
            case .tap: return "正在点击"
            case .drag: return "正在滑动"
            case .home: return "正在返回主屏幕"
            case .launch: return "正在启动 App"
            case .text: return "正在输入文本"
            case .skill: return "正在读取技能"
            case .processing: return "正在处理"
            }
        }
    }

    enum Phase: String, Codable, Hashable {
        case thinking, working, awaitingApproval, approved, executing
        case completed, stopped, interrupted, blocked

        var isTerminal: Bool { [.completed, .stopped, .interrupted, .blocked].contains(self) }
        var title: String {
            switch self {
            case .thinking: return "正在思考"
            case .working: return "正在处理"
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
            case .thinking: return "brain"
            case .working, .executing: return "gearshape"
            }
        }
        var detail: String {
            switch self {
            case .awaitingApproval: return "回到 App 查看详情并确认本次动作"
            case .approved: return "批准不等于已执行；请核对后续状态"
            case .executing: return "发送不代表成功，请核对设备结果"
            case .interrupted: return "返回 App 查看记录；不会自动重试"
            case .stopped: return "如动作已发出，请核对设备"
            case .completed: return "请回到 App 核对结果"
            case .blocked: return "回到 App 查看原因"
            default: return "任务执行中；采集或连接失效时停止"
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
