import Foundation

struct RunIdentity: Hashable, Sendable {
    let conversationID: UUID
    let runID: UUID
}

struct StepIdentity: Hashable, Sendable {
    let run: RunIdentity
    let stepID: String
}

struct PresentedFrame: Sendable {
    let step: StepIdentity
    let image: FrameImage
}

enum ChatRole: String, Codable, Sendable { case user, assistant, tool, notice }
enum MessageState: String, Codable, Sendable { case complete, streaming, interrupted, failed }
enum ToolStepState: String, Codable, Sendable {
    case requested, running, awaitingApproval, approved, executing, succeeded, failed, denied, cancelled
    var isTerminal: Bool { [.succeeded, .failed, .denied, .cancelled].contains(self) }
    var label: String {
        switch self {
        case .requested: return "已请求"
        case .running, .executing: return "执行中"
        case .awaitingApproval: return "等待确认"
        case .approved: return "已批准"
        case .succeeded: return "已返回"
        case .failed: return "失败"
        case .denied: return "已拒绝"
        case .cancelled: return "已取消"
        }
    }
}
struct ToolStep: Codable, Sendable, Equatable {
    var callID: String
    var name: String
    var state: ToolStepState
    var detail: String
    var result: String = ""
    // Optional keeps version-1 archives without parameter previews readable.
    // Only bounded public fields from our five registered tools are stored.
    var arguments: String?
    var skillName: String?
    var symbol: String {
        switch name {
        case "list_skills": return "books.vertical"
        case "search_skills": return "text.book.closed"
        case "load_skill": return "book.closed"
        default: return "wrench.and.screwdriver"
        }
    }
    var title: String {
        switch name {
        case "screenshot": return "查看屏幕"
        case "tap": return "点击"
        case "drag": return "拖动"
        case "wait": return "等待画面更新"
        case "finish": return "结束本轮"
        case "list_skills": return "查看可用技能"
        case "search_skills": return "搜索技能"
        case "load_skill": return "加载技能" + (skillName.map { " · " + $0 } ?? "")
        default: return name
        }
    }
}
struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var runID: UUID?
    var role: ChatRole
    var text: String
    var date = Date()
    var state: MessageState = .complete
    var tool: ToolStep?
    var attachments: [StoredAttachment]?
}
struct AgentConversation: Identifiable, Codable, Sendable {
    var id = UUID()
    var title = "新会话"
    var mode: RunMode
    var createdAt = Date()
    var updatedAt = Date()
    var entry: SessionEntry?
    var draft = ""
    var draftAttachments: [StoredAttachment]?
    var providerID: UUID?
    var modelID: String?
    var recoveryNotices: [String: String]?
    var phase: RunPhase = .idle
    var messages: [ChatMessage] = []
    var preview: String {
        if entry?.state == .pendingConfirmation { return "Siri · 待确认：" + draft }
        return messages.last(where: { $0.role == .user || $0.role == .assistant })?.text ?? "开始一个新的任务或问题"
    }
}
extension RunPhase {
    var label: String {
        switch self {
        case .idle: return "准备就绪"
        case .running: return "正在执行"
        case .awaitingApproval: return "等待确认"
        case .stopped: return "已停止"
        case .interrupted: return "已中断"
        case .completed: return "已结束"
        case .blocked: return "需要处理"
        }
    }
}
