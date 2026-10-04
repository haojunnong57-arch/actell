import Foundation

/// Application-owned boundary. A retry reuses commandID; a new utterance gets a
/// new ID even when its text is identical. No command can approve a tool.
struct SessionCommand: Sendable {
    enum Action: Sendable { case prepare(String), open, status, cancel }
    enum Source: String, Codable, Sendable { case siri, app }
    let commandID: UUID
    let sessionID: UUID?
    let runID: UUID?
    let source: Source
    let createdAt: Date
    let action: Action

    init(_ action: Action, commandID: UUID = UUID(), sessionID: UUID? = nil,
         runID: UUID? = nil, source: Source = .siri, createdAt: Date = Date()) {
        self.action = action; self.commandID = commandID; self.sessionID = sessionID
        self.runID = runID; self.source = source; self.createdAt = createdAt
    }
}

/// Persisted in the same atomic archive as the conversation and draft.
struct SessionEntry: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case pendingConfirmation, submitted, dismissed }
    let commandID: UUID
    let sessionID: UUID
    let source: SessionCommand.Source
    let createdAt: Date
    var updatedAt: Date
    var state: State = .pendingConfirmation
    var routePending = true
    var runID: UUID?
}

enum SessionCommandError: LocalizedError {
    case invalidTask, unavailableStorage, missingSession, conflictingCommand
    var errorDescription: String? {
        switch self {
        case .invalidTask: return String(localized: "Enter a task of 1–2,000 characters.")
        case .unavailableStorage: return String(localized: "The draft could not be saved. Open PhoneAgent and check storage.")
        case .missingSession: return String(localized: "This draft is no longer available.")
        case .conflictingCommand: return String(localized: "This request identifier has already been used.")
        }
    }
}

enum SessionPublicStatus: String, Sendable {
    case idle, pendingConfirmation, running, awaitingApproval, stopping
    var message: String {
        switch self {
        case .idle: return String(localized: "No task is currently running.")
        case .pendingConfirmation: return String(localized: "A task draft is waiting for your confirmation in PhoneAgent. It has not started.")
        case .running: return String(localized: "A task is running in the foreground.")
        case .awaitingApproval: return String(localized: "A task is waiting for your approval in PhoneAgent.")
        case .stopping: return String(localized: "The current task is stopping.")
        }
    }
}

@MainActor protocol SessionCommandRunning: AnyObject {
    var currentRun: RunIdentity? { get }
    var commandBusy: Bool { get }
    var commandStatus: SessionPublicStatus { get }
    func cancelCommandRun(_ identity: RunIdentity) -> Bool
}

@MainActor final class SessionCommandService {
    enum Result: Equatable {
        case prepared(UUID), open(UUID), deferred, status(SessionPublicStatus), cancelled, noMatchingRun
    }
    let sessions: ConversationStore
    private let runner: any SessionCommandRunning

    init(sessions: ConversationStore, runner: any SessionCommandRunning) {
        self.sessions = sessions; self.runner = runner
    }
    var pendingRoute: UUID? {
        sessions.conversations.filter { $0.entry?.state == .pendingConfirmation && $0.entry?.routePending == true }
            .max { $0.createdAt < $1.createdAt }?.id
    }
    /// Capture before any suspension. A later run must never inherit this stop.
    func cancelCurrentCommand() -> SessionCommand {
        SessionCommand(.cancel, sessionID: runner.currentRun?.conversationID, runID: runner.currentRun?.runID)
    }
    func perform(_ command: SessionCommand) throws -> Result {
        switch command.action {
        case .prepare(let task):
            return .prepared(try sessions.prepare(command, task: task))
        case .open:
            guard let id = command.sessionID, let session = sessions.conversation(id),
                  session.entry?.state == .pendingConfirmation else { throw SessionCommandError.missingSession }
            guard !runner.commandBusy else { return .deferred }
            return .open(id)
        case .status:
            let status = runner.commandStatus
            return .status(status == .idle && sessions.conversations.contains { $0.entry?.state == .pendingConfirmation } ? .pendingConfirmation : status)
        case .cancel:
            guard let sessionID = command.sessionID, let runID = command.runID else { return .noMatchingRun }
            return runner.cancelCommandRun(RunIdentity(conversationID: sessionID, runID: runID)) ? .cancelled : .noMatchingRun
        }
    }
}

extension AgentViewModel: SessionCommandRunning {
    var commandBusy: Bool { running || stopping || isListening }
    var commandStatus: SessionPublicStatus {
        if stopping { return .stopping }
        if running { return approval == nil ? .running : .awaitingApproval }
        return .idle
    }
    func cancelCommandRun(_ identity: RunIdentity) -> Bool {
        guard currentRun == identity, running, !stopping else { return false }
        stop(); return true // Existing runner/coordinator drain, never just UI state.
    }
}
