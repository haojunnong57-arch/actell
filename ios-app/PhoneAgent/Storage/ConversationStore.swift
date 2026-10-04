import Foundation
import Combine

/// UI history contains public text and bounded tool receipts, never screenshots,
/// raw tool arguments, model reasoning, credentials, or resumable tool queues.
@MainActor final class ConversationStore: ObservableObject {
    @Published private(set) var conversations: [AgentConversation] = []
    @Published private(set) var activeRun: RunIdentity?
    @Published private(set) var warning: String?
    private let file: URL?
    private var canWrite = true
    private var saveTask: Task<Void, Never>?
    private struct Archive: Codable { var version = 1; var conversations: [AgentConversation] }

    init(directory: URL? = nil, inMemory: Bool = false, legacy: [TaskRecord] = []) {
        if inMemory { file = nil; return }
        do {
            let folder = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PhoneAgent", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var folderURL = folder
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try folderURL.setResourceValues(values)
            file = folder.appendingPathComponent("conversations-v1.json")
        } catch { file = nil; canWrite = false; warning = "会话暂时只能保存在内存中"; return }
        do {
            if let file, FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard data.count <= 64 * 1_024 * 1_024 else { throw AppError.invalid("会话文件过大") }
                let archive = try JSONDecoder().decode(Archive.self, from: data)
                guard archive.version == 1 else { throw AppError.invalid("会话文件版本不兼容") }
                conversations = archive.conversations
                for index in conversations.indices {
                    if [.running, .awaitingApproval].contains(conversations[index].phase) {
                        conversations[index].phase = .interrupted
                    }
                    closePendingMessages(at: index)
                }
            } else {
                conversations = legacy.map { record in
                    var conversation = AgentConversation(mode: record.mode)
                    conversation.id = record.id; conversation.title = String(record.goal.prefix(48))
                    conversation.updatedAt = record.updatedAt
                    conversation.phase = [.running, .awaitingApproval].contains(record.phase) ? .interrupted : record.phase
                    conversation.messages = [ChatMessage(role: .user, text: record.goal)]
                    conversation.messages += record.receipts.map { ChatMessage(role: .notice, text: $0.message, date: $0.date) }
                    if !record.result.isEmpty { conversation.messages.append(ChatMessage(role: .notice, text: "历史运行结果：\n" + record.result)) }
                    return conversation
                }
            }
            saveNow()
        } catch {
            canWrite = false // Preserve an unreadable original; never replace it with [].
            warning = "历史会话未能读取；已保留原文件，本次会话暂不写入磁盘"
        }
    }

    func conversation(_ id: UUID) -> AgentConversation? { conversations.first { $0.id == id } }
    @discardableResult func create(mode: RunMode) -> UUID {
        let conversation = AgentConversation(mode: mode)
        conversations.insert(conversation, at: 0); saveNow()
        return conversation.id
    }
    /// Prepare and route are one durable record. Commit first so Siri never
    /// reports a saved task when the archive is locked, corrupt, or full.
    func prepare(_ command: SessionCommand, task: String) throws -> UUID {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2_000 else { throw SessionCommandError.invalidTask }
        if let previous = conversations.first(where: { $0.entry?.commandID == command.commandID }) {
            guard previous.entry?.source == command.source else { throw SessionCommandError.conflictingCommand }
            return previous.id
        }
        var conversation = AgentConversation(mode: .live)
        conversation.createdAt = command.createdAt; conversation.updatedAt = command.createdAt
        conversation.title = String(text.prefix(48)); conversation.draft = text
        conversation.entry = SessionEntry(commandID: command.commandID, sessionID: conversation.id,
            source: command.source, createdAt: command.createdAt, updatedAt: command.createdAt)
        try commit([conversation] + conversations)
        return conversation.id
    }
    func dismissPreparedTask(in id: UUID) throws {
        guard let index = index(id), conversations[index].entry?.state == .pendingConfirmation else { return }
        var next = conversations
        next[index].entry?.state = .dismissed; next[index].entry?.routePending = false
        next[index].entry?.updatedAt = Date(); next[index].draft = ""
        try commit(next)
    }
    private func commit(_ next: [AgentConversation]) throws {
        guard canWrite else { throw SessionCommandError.unavailableStorage }
        do {
            if let file {
                let data = try JSONEncoder().encode(Archive(conversations: next))
                guard data.count <= 64 * 1_024 * 1_024 else { throw SessionCommandError.unavailableStorage }
                try data.write(to: file, options: [.atomic, .completeFileProtection])
            }
            conversations = next
        } catch { throw SessionCommandError.unavailableStorage }
    }
    func setDraft(_ text: String, in id: UUID) {
        guard let index = index(id) else { return }
        conversations[index].draft = String(text.prefix(2_000)); scheduleSave()
    }
    func delete(_ id: UUID) {
        guard activeRun?.conversationID != id else { return }
        conversations.removeAll { $0.id == id }; saveNow()
    }
    func clear() {
        guard activeRun == nil else { return }
        conversations = []; saveNow()
    }
    func begin(in id: UUID, query: String) -> RunIdentity? {
        guard activeRun == nil, let index = index(id) else { return nil }
        let identity = RunIdentity(conversationID: id, runID: UUID())
        activeRun = identity
        if conversations[index].messages.isEmpty { conversations[index].title = String(query.prefix(48)) }
        conversations[index].phase = .running; conversations[index].draft = ""
        if conversations[index].entry?.state == .pendingConfirmation {
            conversations[index].entry?.state = .submitted
            conversations[index].entry?.routePending = false
            conversations[index].entry?.runID = identity.runID
            conversations[index].entry?.updatedAt = Date()
        }
        conversations[index].messages.append(ChatMessage(runID: identity.runID, role: .user, text: query))
        touch(index); saveNow()
        return identity
    }
    func accepts(_ identity: RunIdentity) -> Bool { activeRun == identity }
    func beginAssistantTurn(_ identity: RunIdentity) {
        guard accepts(identity), let index = index(identity.conversationID) else { return }
        conversations[index].messages.append(ChatMessage(runID: identity.runID, role: .assistant, text: "", state: .streaming))
        touch(index); scheduleSave()
    }
    func appendText(_ text: String, identity: RunIdentity) {
        guard accepts(identity), let index = index(identity.conversationID),
              let message = conversations[index].messages.lastIndex(where: { $0.runID == identity.runID && $0.role == .assistant && $0.state == .streaming }) else { return }
        conversations[index].messages[message].text = String((conversations[index].messages[message].text + text).prefix(16_000))
        touch(index); scheduleSave()
    }
    func completeAssistantTurn(_ text: String, identity: RunIdentity) {
        guard accepts(identity), let index = index(identity.conversationID),
              let message = conversations[index].messages.lastIndex(where: { $0.runID == identity.runID && $0.role == .assistant && $0.state == .streaming }) else { return }
        if text.isEmpty { conversations[index].messages.remove(at: message) }
        else {
            conversations[index].messages[message].text = String(text.prefix(16_000))
            conversations[index].messages[message].state = .complete
        }
        touch(index); saveNow()
    }
    func updateTool(callID: String, name: String, state: ToolStepState, detail: String = "", result: String = "", arguments: String? = nil, identity: RunIdentity) {
        guard accepts(identity), let index = index(identity.conversationID) else { return }
        if let message = conversations[index].messages.firstIndex(where: { $0.runID == identity.runID && $0.tool?.callID == callID }) {
            let previous = conversations[index].messages[message].tool?.state
            guard previous?.isTerminal != true else { return }
            // Approval callbacks can arrive before queued observer events. Keep
            // their state, and never revive a terminal (especially denied) step.
            let regresses = state == .requested || (state == .running && [.awaitingApproval, .approved, .executing].contains(previous))
            if previous?.isTerminal != true && !regresses {
                conversations[index].messages[message].tool?.state = state
            }
            if !detail.isEmpty { conversations[index].messages[message].tool?.detail = String(detail.prefix(500)) }
            if !result.isEmpty { conversations[index].messages[message].tool?.result = String(result.prefix(1_000)) }
            if let arguments { conversations[index].messages[message].tool?.arguments = String(arguments.prefix(4_000)) }
        } else {
            let tool = ToolStep(callID: callID, name: name, state: state, detail: String(detail.prefix(500)), result: String(result.prefix(1_000)), arguments: arguments.map { String($0.prefix(4_000)) })
            conversations[index].messages.append(ChatMessage(runID: identity.runID, role: .tool, text: "", tool: tool))
        }
        if state == .awaitingApproval { conversations[index].phase = .awaitingApproval }
        else if [.approved, .executing, .succeeded, .failed].contains(state) { conversations[index].phase = .running }
        touch(index); saveNow()
    }
    func addNotice(_ text: String, in id: UUID) {
        guard let index = index(id) else { return }
        conversations[index].messages.append(ChatMessage(role: .notice, text: String(text.prefix(1_000))))
        touch(index); saveNow()
    }
    func finish(_ identity: RunIdentity, phase: RunPhase, summary: String) {
        guard accepts(identity), let index = index(identity.conversationID) else { return }
        conversations[index].phase = phase
        closePendingMessages(at: index)
        if !summary.isEmpty {
            conversations[index].messages.append(ChatMessage(runID: identity.runID, role: .notice, text: String(summary.prefix(1_000)), state: phase == .blocked ? .failed : .complete))
        }
        activeRun = nil; touch(index); saveNow()
    }
    /// Only public text from this conversation is used as context. Historical
    /// tools/images are never re-enqueued or used to authorize new input.
    func history(in id: UUID) -> [ChatMessage] {
        Array((conversation(id)?.messages ?? []).filter { ($0.role == .user || $0.role == .assistant) && $0.state == .complete }.suffix(16))
    }
    private func index(_ id: UUID) -> Int? { conversations.firstIndex { $0.id == id } }
    private func touch(_ index: Int) {
        conversations[index].updatedAt = Date()
        if conversations[index].messages.count > 200 { conversations[index].messages.removeFirst(conversations[index].messages.count - 200) }
    }
    private func closePendingMessages(at index: Int) {
        for message in conversations[index].messages.indices {
            if conversations[index].messages[message].state == .streaming { conversations[index].messages[message].state = .interrupted }
            if let state = conversations[index].messages[message].tool?.state, !state.isTerminal {
                conversations[index].messages[message].tool?.state = .cancelled
            }
        }
    }
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            self?.saveNow()
        }
    }
    func saveNow() {
        saveTask?.cancel(); saveTask = nil
        guard let file, canWrite else { return }
        do {
            let data = try JSONEncoder().encode(Archive(conversations: conversations))
            guard data.count <= 64 * 1_024 * 1_024 else { throw AppError.invalid("会话存储已满，请删除旧会话") }
            try data.write(to: file, options: [.atomic, .completeFileProtection])
        } catch { warning = "会话未能保存；请检查存储空间，当前内容仍在内存中" }
    }
}
