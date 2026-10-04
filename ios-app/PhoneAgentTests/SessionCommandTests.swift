import XCTest
import AppIntents
@testable import PhoneAgent

@MainActor private final class CommandMockRunner: SessionCommandRunning {
    var currentRun: RunIdentity?
    var commandBusy = false
    var commandStatus: SessionPublicStatus = .idle
    var cancellations: [RunIdentity] = []
    func cancelCommandRun(_ identity: RunIdentity) -> Bool {
        guard currentRun == identity else { return false }
        cancellations.append(identity); currentRun = nil; commandStatus = .stopping
        return true
    }
}

@MainActor final class SessionCommandTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testPrepareValidatesBeforeSavingAndDoesNotRun() throws {
        let store = ConversationStore(inMemory: true), runner = CommandMockRunner()
        let service = SessionCommandService(sessions: store, runner: runner)
        for text in ["", " \n ", String(repeating: "字", count: 2_001)] {
            XCTAssertThrowsError(try service.perform(SessionCommand(.prepare(text))))
        }
        XCTAssertTrue(store.conversations.isEmpty)
        guard case .prepared(let id) = try service.perform(SessionCommand(.prepare("  打开计数器  "))) else { return XCTFail() }
        XCTAssertEqual(store.conversation(id)?.draft, "打开计数器")
        XCTAssertEqual(store.conversation(id)?.entry?.state, .pendingConfirmation)
        XCTAssertEqual(store.conversation(id)?.mode, .live)
        XCTAssertEqual(store.conversation(id)?.messages.count, 0)
        XCTAssertNil(runner.currentRun)
        XCTAssertTrue(runner.cancellations.isEmpty)
    }
    func testColdLaunchAndRetryRetainIdentityButIdenticalNewRequestIsDistinct() throws {
        let folder = try directory(), command = SessionCommand(.prepare("同一任务"))
        let original = ConversationStore(directory: folder)
        let first = try original.prepare(command, task: "同一任务")
        let restored = ConversationStore(directory: folder)
        let service = SessionCommandService(sessions: restored, runner: CommandMockRunner())
        XCTAssertEqual(service.pendingRoute, first)
        XCTAssertEqual(try service.perform(command), .prepared(first))
        XCTAssertEqual(restored.conversations.count, 1)
        _ = try service.perform(SessionCommand(.prepare("同一任务")))
        XCTAssertEqual(restored.conversations.count, 2)
        XCTAssertEqual(Set(restored.conversations.compactMap { $0.entry?.commandID }).count, 2)
        XCTAssertNil(restored.activeRun)
    }
    func testBusyOpenDefersWithoutCancellingOrSelectingAnotherRun() throws {
        let store = ConversationStore(inMemory: true), runner = CommandMockRunner()
        runner.currentRun = RunIdentity(conversationID: UUID(), runID: UUID())
        runner.commandBusy = true; runner.commandStatus = .running
        let service = SessionCommandService(sessions: store, runner: runner)
        let id = try store.prepare(SessionCommand(.prepare("稍后任务")), task: "稍后任务")
        XCTAssertEqual(try service.perform(SessionCommand(.open, sessionID: id)), .deferred)
        XCTAssertNotNil(runner.currentRun)
        XCTAssertTrue(runner.cancellations.isEmpty)
        XCTAssertEqual(service.pendingRoute, id)
        runner.commandBusy = false
        XCTAssertEqual(try service.perform(SessionCommand(.open, sessionID: id)), .open(id))
    }
    func testCapturedCancelCannotStopLaterRunInSameSessionOrAnotherSession() throws {
        let runner = CommandMockRunner(), store = ConversationStore(inMemory: true)
        let service = SessionCommandService(sessions: store, runner: runner)
        let sessionID = UUID()
        runner.currentRun = RunIdentity(conversationID: sessionID, runID: UUID())
        let stale = service.cancelCurrentCommand()
        runner.currentRun = RunIdentity(conversationID: sessionID, runID: UUID())
        XCTAssertEqual(try service.perform(stale), .noMatchingRun)
        runner.currentRun = RunIdentity(conversationID: UUID(), runID: UUID())
        XCTAssertEqual(try service.perform(stale), .noMatchingRun)
        let valid = service.cancelCurrentCommand()
        XCTAssertEqual(try service.perform(valid), .cancelled)
        XCTAssertEqual(try service.perform(valid), .noMatchingRun)
        XCTAssertEqual(runner.cancellations.count, 1)
    }
    func testCancelCapturedWhenIdleNeverStopsFutureRun() throws {
        let runner = CommandMockRunner()
        let service = SessionCommandService(sessions: ConversationStore(inMemory: true), runner: runner)
        let idle = service.cancelCurrentCommand()
        runner.currentRun = RunIdentity(conversationID: UUID(), runID: UUID())
        XCTAssertEqual(try service.perform(idle), .noMatchingRun)
        XCTAssertTrue(runner.cancellations.isEmpty)
    }
    func testDismissedDraftDoesNotRouteAfterRestartOrRetry() throws {
        let folder = try directory(), command = SessionCommand(.prepare("取消草稿"))
        let store = ConversationStore(directory: folder)
        let id = try store.prepare(command, task: "取消草稿")
        try store.dismissPreparedTask(in: id)
        let restored = ConversationStore(directory: folder)
        let service = SessionCommandService(sessions: restored, runner: CommandMockRunner())
        XCTAssertNil(service.pendingRoute)
        XCTAssertEqual(restored.conversation(id)?.entry?.state, .dismissed)
        XCTAssertEqual(restored.conversation(id)?.draft, "")
        XCTAssertEqual(try service.perform(command), .prepared(id))
        XCTAssertNil(service.pendingRoute)
        XCTAssertThrowsError(try service.perform(SessionCommand(.open, sessionID: id)))
    }
    func testSubmittedDraftRecordsRunAndNeverResumesOnColdLaunch() throws {
        let folder = try directory(), store = ConversationStore(directory: folder)
        let id = try store.prepare(SessionCommand(.prepare("已确认")), task: "已确认")
        let identity = try XCTUnwrap(store.begin(in: id, query: "已确认"))
        let restored = ConversationStore(directory: folder)
        XCTAssertEqual(restored.conversation(id)?.entry?.runID, identity.runID)
        XCTAssertEqual(restored.conversation(id)?.entry?.state, .submitted)
        XCTAssertEqual(restored.conversation(id)?.phase, .interrupted)
        XCTAssertNil(restored.activeRun)
        XCTAssertNil(SessionCommandService(sessions: restored, runner: CommandMockRunner()).pendingRoute)
    }
    func testCorruptArchiveAndFailedWriteNeverClaimDraftSaved() throws {
        let folder = try directory(), file = folder.appendingPathComponent("conversations-v1.json")
        let broken = Data("preserve".utf8); try broken.write(to: file)
        let store = ConversationStore(directory: folder)
        XCTAssertThrowsError(try store.prepare(SessionCommand(.prepare("任务")), task: "任务"))
        XCTAssertEqual(try Data(contentsOf: file), broken)
        let another = try directory(), unavailable = ConversationStore(directory: another)
        try FileManager.default.removeItem(at: another)
        XCTAssertThrowsError(try unavailable.prepare(SessionCommand(.prepare("任务")), task: "任务"))
        XCTAssertTrue(unavailable.conversations.isEmpty)
    }
    func testStatusNeverIncludesTaskTextAndTracksRunner() throws {
        let runner = CommandMockRunner(), store = ConversationStore(inMemory: true)
        let service = SessionCommandService(sessions: store, runner: runner)
        XCTAssertEqual(try service.perform(SessionCommand(.status)), .status(.idle))
        _ = try service.perform(SessionCommand(.prepare("private task secret")))
        XCTAssertEqual(try service.perform(SessionCommand(.status)), .status(.pendingConfirmation))
        for state: SessionPublicStatus in [.running, .awaitingApproval, .stopping] {
            runner.commandStatus = state
            XCTAssertEqual(try service.perform(SessionCommand(.status)), .status(state))
            XCTAssertFalse(state.message.contains("private task secret"))
        }
    }
    func testAuthenticationAndForegroundPolicy() {
        XCTAssertEqual(PrepareAgentTaskIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
        XCTAssertEqual(AgentTaskStatusIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
        XCTAssertEqual(StopAgentTaskIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
        if #available(iOS 26.0, *) {
            XCTAssertEqual(PrepareAgentTaskIntent.supportedModes, .foreground(.immediate))
            XCTAssertEqual(AgentTaskStatusIntent.supportedModes, .background)
            XCTAssertEqual(StopAgentTaskIntent.supportedModes, .background)
        }
    }
    func testCancelledIntentDoesNotCreateDraft() async {
        let before = PhoneAgentRuntime.shared.model.sessions.conversations.count
        let operation = Task { @MainActor in
            await Task.yield()
            let intent = PrepareAgentTaskIntent(); intent.task = "cancelled utterance"
            _ = try await intent.perform()
        }
        operation.cancel()
        do { try await operation.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(PhoneAgentRuntime.shared.model.sessions.conversations.count, before)
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        throw AppError.timeout
    }
    func testConfirmedSiriDraftUsesExistingApprovalAndScopedStop() async throws {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false,
                                  runServices: AgentRunServices(provider: DemoProvider(), bridge: DemoBridge()))
        let service = SessionCommandService(sessions: store, runner: model)
        let id = try store.prepare(SessionCommand(.prepare("演示")), task: "演示")
        model.selectConversation(id)
        XCTAssertFalse(model.running)
        XCTAssertFalse(model.send("演示", in: id)) // Authentication/dictation isn't cloud consent.
        XCTAssertTrue(model.send("演示", in: id, cloudConsent: true))
        try await waitUntil { model.approval != nil }
        XCTAssertEqual(try service.perform(SessionCommand(.status)), .status(.awaitingApproval))
        XCTAssertEqual(store.conversation(id)?.entry?.runID, model.currentRun?.runID)
        let command = service.cancelCurrentCommand()
        XCTAssertEqual(try service.perform(command), .cancelled)
        try await waitUntil { !model.stopping }
        XCTAssertNil(model.approval)
        XCTAssertNil(model.currentRun)
        XCTAssertEqual(store.conversation(id)?.phase, .stopped)
        XCTAssertFalse(store.conversation(id)!.messages.contains { $0.tool?.name == "tap" && $0.tool?.state == .succeeded })
    }
}
