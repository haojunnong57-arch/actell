import Foundation
import Combine
import SwiftAgentKit

/// App-owned display boundary. Views send scoped intents; they never receive an
/// Agent, a provider, a transport, or an approval continuation.
enum AgentUIIntent {
    case send(sessionID: UUID, text: String, cloudConsent: Bool)
    case approve(step: StepIdentity, approvalID: UUID)
    case deny(step: StepIdentity, approvalID: UUID)
    case stop(run: RunIdentity)
}

struct ToolPresentation {
    let identity: StepIdentity
    let tool: ToolStep
    let approval: Approval?
    let image: FrameImage?
}

@MainActor final class AgentPresentationAdapter: ObservableObject {
    private let model: AgentViewModel
    let sessionID: UUID
    private var subscriptions = Set<AnyCancellable>()

    init(model: AgentViewModel, sessionID: UUID) {
        self.model = model; self.sessionID = sessionID
        model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        model.sessions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    var activityNavigation: ActivityNavigation? { model.activityNavigation.flatMap { $0.route.sessionID == sessionID ? $0 : nil } }
    var session: AgentConversation? { model.sessions.conversation(sessionID) }
    var activeRun: RunIdentity? { model.currentRun.flatMap { $0.conversationID == sessionID ? $0 : nil } }
    var backgroundStatus: String { model.backgroundStatus }
    var running: Bool { activeRun != nil && model.running }
    var stopping: Bool { model.stopping }
    var status: String { running ? model.status : session?.phase.label ?? "" }
    var warning: String? { model.errorMessage ?? model.sessions.warning }
    var modelName: String { model.settings.model.isEmpty ? "真实模型 · 尚未配置" : model.settings.model }
    var approvalID: UUID? { model.approval(in: sessionID)?.id }
    var pendingApproval: ToolPresentation? {
        guard let messages = session?.messages else { return nil }
        return messages.reversed().lazy.compactMap { self.presentation(for: $0) }.first { $0.approval != nil }
    }

    func open() { model.selectConversation(sessionID) }
    func close() { model.leaveConversation(sessionID) }
    var awaitingTaskConfirmation: Bool { session?.entry?.state == .pendingConfirmation }
    func dismissPreparedTask() {
        do { try model.sessions.dismissPreparedTask(in: sessionID) }
        catch { model.errorMessage = error.localizedDescription }
    }
    func saveDraft(_ text: String) { model.sessions.setDraft(text, in: sessionID) }

    func presentation(for message: ChatMessage) -> ToolPresentation? {
        guard let runID = message.runID, let tool = message.tool else { return nil }
        let step = StepIdentity(run: RunIdentity(conversationID: sessionID, runID: runID), stepID: tool.callID)
        let approval = activeRun == step.run && tool.state == .awaitingApproval
            ? model.approval(in: sessionID).flatMap { $0.callID == step.stepID ? $0 : nil } : nil
        let frame = model.latestFrame
        let image: FrameImage?
        if let frame, frame.step == step { image = frame.image }
        else if let frame, frame.step.run == step.run, approval?.imageID == frame.image.id { image = frame.image }
        else { image = nil }
        return ToolPresentation(identity: step, tool: tool, approval: approval, image: image)
    }

    @discardableResult func dispatch(_ intent: AgentUIIntent) -> Bool {
        guard model.selectedConversationID == sessionID else { return false }
        switch intent {
        case .send(let id, let text, let consent):
            guard id == sessionID else { return false }
            return model.send(text, in: id, cloudConsent: consent)
        case .approve(let step, let id), .deny(let step, let id):
            guard step.run == activeRun, let request = model.approval(in: sessionID),
                  request.id == id, request.callID == step.stepID else { return false }
            if case .approve = intent { model.approve(true, approvalID: id, conversationID: sessionID) }
            else { model.approve(false, approvalID: id, conversationID: sessionID) }
            return true
        case .stop(let run):
            guard run == activeRun else { return false }
            model.stop(); return true
        }
    }
}

/// Receives the FIFO stream from the actual SwiftAgentKit run. No Manifold
/// runtime/progress consumer is involved. Approval/transport callbacks carry
/// the same run token and update the same step in ConversationStore.
@MainActor enum AgentEventProjection {
    static func record(_ event: AgentEvent, run: RunIdentity, frame: PresentedFrame?, in store: ConversationStore) {
        guard store.accepts(run) else { return }
        switch event {
        case .llmCallStarted: store.beginAssistantTurn(run)
        case .streamChunk(let text): store.appendText(text, identity: run)
        case .llmCallCompleted(_, let response): store.completeAssistantTurn(response.text, identity: run)
        case .toolCallsReceived(let calls):
            for call in calls {
                store.updateTool(callID: call.id, name: call.name, state: .requested, arguments: arguments(for: call), identity: run)
            }
        case .toolExecutionStarted(let call):
            store.updateTool(callID: call.id, name: call.name, state: .running, arguments: arguments(for: call), identity: run)
        case .toolExecutionFinished(let call, let result):
            let receipt: String
            if result.isError { receipt = String(result.result.prefix(1_000)) }
            else {
                switch call.name {
                case "screenshot":
                    let image = frame.flatMap { $0.step == StepIdentity(run: run, stepID: call.id) ? $0.image : nil }
                    receipt = image.map { "已取得 \($0.width) × \($0.height) 截图；图像仅在内存中保留" } ?? "截图已返回"
                case "tap", "drag": receipt = "已确认送达；可见效果需要下一张截图核对"
                case "wait": receipt = "等待结束，需要重新查看屏幕"
                case "finish": receipt = String(result.result.prefix(1_000))
                default: receipt = "工具已返回"
                }
            }
            store.updateTool(callID: call.id, name: call.name, state: result.isError ? .failed : .succeeded, result: receipt, arguments: arguments(for: call), identity: run)
        default: break // Internal reasoning and unrelated framework events stay out of UI/history.
        }
    }

    static func arguments(for call: AgentToolCall) -> String {
        let allowed: [String]
        switch call.name {
        case "screenshot": allowed = []
        case "tap": allowed = ["x", "y", "purpose"]
        case "drag": allowed = ["from_x", "from_y", "to_x", "to_y", "duration_ms", "purpose"]
        case "wait": allowed = ["duration_ms"]
        case "finish": allowed = ["summary"]
        default: return "未注册工具；不展示原始参数"
        }
        var values: [String: Any] = [:]
        for key in allowed {
            guard let value = call.parameters[key]?.value else { continue }
            if let string = value as? String { values[key] = String(string.prefix(key == "summary" ? 1_000 : 160)) }
            else if let number = value as? NSNumber, number.doubleValue.isFinite { values[key] = number }
            else { values[key] = "不支持的参数类型" }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return "参数无法展示" }
        return text
    }
}
