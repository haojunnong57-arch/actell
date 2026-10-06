import Foundation

/// Deliberately excludes goal text, model output, screenshots, endpoints and secrets.
/// A system-visible card may expose only these application-owned labels.
struct AgentStatusSnapshot: Equatable, Sendable {
    enum Phase: String, Sendable {
        case idle = "尚未开始"
        case running = "正在运行"
        case confirmation = "等待确认"
        case stopped = "已停止"
        case interrupted = "前台任务已中断"
        case completed = "运行结束，请核对"
        case blocked = "需要回到 App 检查"
    }
    let isDemo: Bool
    let phase: Phase
    var title: String { isDemo ? "演示计数器任务" : "当前授权任务" }
    var detail: String {
        switch phase {
        case .confirmation: return "请回到 App 查看截图并确认"
        case .interrupted: return "返回后需手动重新开始"
        case .running: return "后台运行由系统分配执行时间"
        default: return "此卡片只展示状态，不执行操作"
        }
    }
    var interrupted: Self { Self(isDemo: isDemo, phase: .interrupted) }

    static func make(mode: RunMode, phase: RunPhase?, running: Bool, awaitingApproval: Bool) -> Self {
        let display: Phase
        if awaitingApproval { display = .confirmation }
        else if running { display = .running }
        else {
            switch phase {
            case .stopped: display = .stopped
            case .interrupted: display = .interrupted
            case .completed: display = .completed
            case .blocked: display = .blocked
            default: display = .idle
            }
        }
        return Self(isDemo: mode == .demo, phase: display)
    }
}
