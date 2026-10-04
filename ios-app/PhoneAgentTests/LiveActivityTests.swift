import XCTest
import Combine
@testable import PhoneAgent

@MainActor final class ApprovalRecordTests: XCTestCase {
    private let run = RunIdentity(conversationID: UUID(), runID: UUID())
    private func request() throws -> Approval {
        Approval(tool: "tap", detail: "Sensitive purpose", imageID: "private-screen", callID: "call-1",
                 parametersDigest: try ApprovalRecordStore.digest(tool: "tap", parameters: ["x": 3, "y": 7, "purpose": "Sensitive purpose"]))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testApprovalIsAtomicSingleUseAndAcceptanceIsNotExecution() throws {
        let store = ApprovalRecordStore(inMemory: true), request = try request()
        try store.register(request, run: run)
        XCTAssertThrowsError(try store.claimExecution(callID: "call-1", run: run))
        try store.resolve(request, run: run, approved: true)
        XCTAssertEqual(store.record(id: request.id)?.state, .accepted)
        XCTAssertThrowsError(try store.resolve(request, run: run, approved: true))
        XCTAssertThrowsError(try store.resolve(request, run: run, approved: false))
        try store.claimExecution(callID: "call-1", run: run)
        XCTAssertEqual(store.record(id: request.id)?.state, .executing)
        XCTAssertThrowsError(try store.claimExecution(callID: "call-1", run: run))
        try store.finish(callID: "call-1", run: run)
        XCTAssertEqual(store.record(id: request.id)?.state, .finished)
    }
    func testTaskGrantIsRecordedAndCannotBeReusedAfterCancellationOrRestart() throws {
        let dir = try directory(), store = ApprovalRecordStore(directory: dir), request = try request()
        try store.register(request, run: run, authorizationMode: .task)
        try store.resolve(request, run: run, approved: true)
        XCTAssertEqual(store.record(id: request.id)?.authorizationMode, .task)
        try store.claimExecution(callID: "call-1", run: run)
        XCTAssertThrowsError(try store.claimExecution(callID: "call-1", run: run))
        let restored = ApprovalRecordStore(directory: dir)
        XCTAssertEqual(restored.record(id: request.id)?.authorizationMode, .task)
        XCTAssertEqual(restored.record(id: request.id)?.state, .interrupted)
        XCTAssertThrowsError(try restored.claimExecution(callID: "call-1", run: run))
        try store.invalidate(run: run)
        XCTAssertThrowsError(try store.claimExecution(callID: "call-1", run: run))
    }
    func testWrongRunParametersVersionAndExpiryCannotAuthorize() throws {
        let store = ApprovalRecordStore(inMemory: true), request = try request()
        try store.register(request, run: run)
        XCTAssertThrowsError(try store.resolve(request, run: RunIdentity(conversationID: run.conversationID, runID: UUID()), approved: true))
        XCTAssertThrowsError(try store.resolve(request, run: RunIdentity(conversationID: UUID(), runID: run.runID), approved: true))
        var changed = request; changed.parametersDigest = "different"
        XCTAssertThrowsError(try store.resolve(changed, run: run, approved: true))
        changed = request; changed.version = 2
        XCTAssertThrowsError(try store.resolve(changed, run: run, approved: true))
        changed = request; changed.expiresAt = request.expiresAt.addingTimeInterval(1)
        XCTAssertThrowsError(try store.resolve(changed, run: run, approved: true))
        XCTAssertTrue(store.isPending(request, run: run))
        XCTAssertThrowsError(try store.resolve(request, run: run, approved: true, now: request.expiresAt))
        XCTAssertEqual(store.record(id: request.id)?.state, .expired)
        XCTAssertThrowsError(try store.claimExecution(callID: "call-1", run: run))
    }
    func testDeniedCancelledAndRelaunchedRecordsCannotResume() throws {
        for approved in [false, true] {
            let dir = try directory(), store = ApprovalRecordStore(directory: dir), request = try request()
            try store.register(request, run: run)
            try store.resolve(request, run: run, approved: approved)
            if !approved { XCTAssertEqual(store.record(id: request.id)?.state, .denied) }
            let restored = ApprovalRecordStore(directory: dir)
            XCTAssertEqual(restored.record(id: request.id)?.state, approved ? .interrupted : .denied)
            XCTAssertThrowsError(try restored.resolve(request, run: run, approved: true))
            XCTAssertThrowsError(try restored.claimExecution(callID: "call-1", run: run))
        }
        let store = ApprovalRecordStore(inMemory: true), request = try request()
        try store.register(request, run: run); try store.invalidate(run: run)
        XCTAssertEqual(store.record(id: request.id)?.state, .cancelled)
        XCTAssertThrowsError(try store.resolve(request, run: run, approved: true))
    }
    func testPendingAndExecutingRecordsAreInvalidatedOnProcessRestart() throws {
        for execute in [false, true] {
            let dir = try directory(), store = ApprovalRecordStore(directory: dir), request = try request()
            try store.register(request, run: run)
            if execute { try store.resolve(request, run: run, approved: true); try store.claimExecution(callID: "call-1", run: run) }
            let restored = ApprovalRecordStore(directory: dir)
            XCTAssertEqual(restored.record(id: request.id)?.state, .interrupted)
            XCTAssertFalse(restored.isPending(request, run: run))
            XCTAssertThrowsError(try restored.claimExecution(callID: "call-1", run: run))
            let text = try String(contentsOf: dir.appendingPathComponent("approvals-v1.json"))
            XCTAssertFalse(text.contains("Sensitive purpose")); XCTAssertFalse(text.contains("private-screen"))
        }
    }
    func testCorruptAuthorityFailsClosedAndPreservesFile() throws {
        let dir = try directory(), file = dir.appendingPathComponent("approvals-v1.json"), data = Data("preserve corruption".utf8)
        try data.write(to: file)
        let store = ApprovalRecordStore(directory: dir)
        XCTAssertThrowsError(try store.register(request(), run: run))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testPersistenceFailureNeverReleasesApproval() throws {
        let dir = try directory(), store = ApprovalRecordStore(directory: dir), request = try request()
        try store.register(request, run: run)
        // Replace the directory with a regular file, making the atomic write fail.
        try FileManager.default.removeItem(at: dir); try Data().write(to: dir)
        XCTAssertThrowsError(try store.resolve(request, run: run, approved: true))
        XCTAssertEqual(store.record(id: request.id)?.state, .pending)
        XCTAssertFalse(store.isPending(request, run: run))
        XCTAssertThrowsError(try store.claimExecution(callID: "call-1", run: run))
    }
    func testParameterDigestIsStableAndBindsActualParameters() throws {
        let a = try ApprovalRecordStore.digest(tool: "tap", parameters: ["x": 1, "y": 2])
        XCTAssertEqual(a, try ApprovalRecordStore.digest(tool: "tap", parameters: ["y": 2, "x": 1]))
        XCTAssertNotEqual(a, try ApprovalRecordStore.digest(tool: "tap", parameters: ["x": 2, "y": 2]))
        XCTAssertNotEqual(a, try ApprovalRecordStore.digest(tool: "drag", parameters: ["x": 1, "y": 2]))
    }
}

@MainActor final class LiveActivityTests: XCTestCase {
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Offline runtime timed out"); throw AppError.timeout
    }
    private func pendingDemo() async throws -> AgentViewModel {
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false)
        let id = model.createConversation(mode: .demo)
        XCTAssertTrue(model.send("Secret goal 123", in: id))
        try await waitUntil { model.approval != nil }
        return model
    }
    func testStrictRouteRoundTripRejectsActionAndMalformedParameters() throws {
        let route = AgentActivityRoute(sessionID: UUID(), runID: UUID(), approvalID: UUID())
        XCTAssertEqual(AgentActivityRoute(url: route.url), route)
        for suffix in ["&approve=true", "&approval=" + UUID().uuidString, "#fragment"] {
            XCTAssertNil(AgentActivityRoute(url: try XCTUnwrap(URL(string: route.url.absoluteString + suffix))))
        }
        XCTAssertNil(AgentActivityRoute(url: URL(string: "phoneagent://activity/session/nope/run/nope")!))
        XCTAssertNil(AgentActivityRoute(url: URL(string: route.url.absoluteString.replacingOccurrences(of: "phoneagent:", with: "https:"))!))
    }
    func testRealEventsProjectSafeStatusApprovalAcceptanceExecutionAndCompletion() async throws {
        let model = try await pendingDemo(); defer { model.stop() }
        let waiting = try XCTUnwrap(model.activitySnapshot), request = try XCTUnwrap(model.approval)
        XCTAssertEqual(waiting.state.phase, .awaitingApproval)
        XCTAssertEqual(waiting.state.approvalID, request.id)
        XCTAssertEqual(waiting.attributes.runID, model.currentRun?.runID)
        let encoded = String(data: try JSONEncoder().encode(waiting.state), encoding: .utf8)!
        for privateValue in ["Secret goal", request.detail, request.imageID, request.parametersDigest, request.callID!] { XCTAssertFalse(encoded.contains(privateValue)) }
        var phases: [AgentActivityAttributes.Phase] = []
        let subscription = model.$activitySnapshot.compactMap { $0?.state.phase }.sink { phases.append($0) }
        model.approve(true)
        XCTAssertEqual(model.activitySnapshot?.state.phase, .approved)
        XCTAssertNil(model.activitySnapshot?.state.approvalID)
        try await waitUntil { !model.running }
        XCTAssertEqual(model.activitySnapshot?.state.phase, .completed)
        XCTAssertEqual(model.activitySnapshot?.state.completedTools, 4)
        XCTAssertTrue(phases.contains(.executing))
        XCTAssertLessThan(try XCTUnwrap(phases.firstIndex(of: .approved)), try XCTUnwrap(phases.firstIndex(of: .executing)))
        subscription.cancel()
    }
    func testDeepLinkOnlyNavigatesAndCannotCrossNewRunOrSession() async throws {
        let model = try await pendingDemo(); defer { model.stop() }
        let run = try XCTUnwrap(model.currentRun), request = try XCTUnwrap(model.approval)
        let route = AgentActivityRoute(sessionID: run.conversationID, runID: run.runID, approvalID: request.id)
        XCTAssertTrue(model.openActivityURL(route.url))
        XCTAssertEqual(model.approval?.id, request.id)
        XCTAssertEqual(model.activityNavigation?.messageID, model.sessions.conversation(run.conversationID)?.messages.first { $0.tool?.callID == request.callID }?.id)
        XCTAssertEqual(model.approvalRecords.record(id: request.id)?.state, .pending)
        XCTAssertFalse(model.openActivityURL(AgentActivityRoute(sessionID: run.conversationID, runID: run.runID, approvalID: UUID()).url))
        model.stop(); try await waitUntil { !model.stopping }
        XCTAssertTrue(model.openActivityURL(route.url))
        XCTAssertTrue(model.activityNavigation?.notice.contains("失效") == true)
        XCTAssertNil(model.approval)
        XCTAssertTrue(model.send("new run", in: run.conversationID))
        try await waitUntil { model.approval != nil }
        let next = model.approval?.id
        XCTAssertFalse(model.openActivityURL(route.url))
        XCTAssertEqual(model.approval?.id, next)
        XCTAssertTrue(model.running)
        model.stop(); try await waitUntil { !model.stopping }
        let other = model.createConversation(mode: .demo)
        XCTAssertTrue(model.send("other session", in: other))
        XCTAssertFalse(model.openActivityURL(route.url))
        XCTAssertEqual(model.selectedConversationID, other)
    }
    func testBackgroundStopsAndClearsAllActionAuthority() async throws {
        let model = try await pendingDemo()
        let request = try XCTUnwrap(model.approval)
        model.setForeground(false)
        XCTAssertEqual(model.activitySnapshot?.state.phase, .interrupted)
        XCTAssertNil(model.activitySnapshot?.state.approvalID)
        XCTAssertEqual(model.approvalRecords.record(id: request.id)?.state, .cancelled)
        model.approve(true)
        try await waitUntil { !model.stopping }
        XCTAssertNil(model.currentRun); XCTAssertNil(model.approval)
        XCTAssertFalse(model.sessions.conversations.flatMap(\.messages).contains { $0.tool?.name == "tap" && $0.tool?.state == .succeeded })
    }
    func testOldActionLinkCannotExposeDifferentApprovalWithinSameRun() async throws {
        let model = try await pendingDemo(); defer { model.stop() }
        let run = try XCTUnwrap(model.currentRun), old = try XCTUnwrap(model.approval)
        let route = AgentActivityRoute(sessionID: run.conversationID, runID: run.runID, approvalID: old.id)
        model.approval = Approval(tool: "drag", detail: "different action", imageID: "different", callID: "next-action")
        XCTAssertFalse(model.openActivityURL(route.url))
        XCTAssertNil(model.activityNavigation)
        XCTAssertEqual(model.approval?.callID, "next-action")
        XCTAssertEqual(model.approvalRecords.record(id: old.id)?.state, .pending)
    }
    func testOldScreenshotDoesNotExpireApprovalAndCanCompleteAfterConfirmation() async throws {
        let bridge = OldScreenshotBridge()
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                                  runServices: AgentRunServices(provider: DemoProvider(), bridge: bridge))
        defer { model.stop() }
        let id = model.createConversation(mode: .demo)
        XCTAssertTrue(model.send("old screenshot", in: id))
        try await waitUntil { model.approval != nil }
        XCTAssertGreaterThan(try XCTUnwrap(model.approval).expiresAt.timeIntervalSinceNow, 40)
        model.approve(true)
        try await waitUntil { !model.running && !model.stopping }
        XCTAssertNil(model.approval)
        XCTAssertEqual(model.activitySnapshot?.state.phase, .completed)
        let taps = await bridge.taps
        XCTAssertEqual(taps, 1)
    }
    func testDenyAndStopRemainDistinctTerminalStates() async throws {
        let denied = try await pendingDemo(), stopped = try await pendingDemo()
        denied.approve(false); stopped.stop()
        XCTAssertEqual(denied.activitySnapshot?.state.phase, .blocked)
        XCTAssertEqual(stopped.activitySnapshot?.state.phase, .stopped)
        try await waitUntil { !denied.stopping && !stopped.stopping }
    }
}

private actor OldScreenshotBridge: DeviceBridge {
    private let demo = DemoBridge()
    private(set) var taps = 0
    func screenshot() async throws -> FrameImage {
        let frame = try await demo.screenshot()
        return FrameImage(id: frame.id, png: frame.png, width: frame.width, height: frame.height,
                          capturedAt: Date().addingTimeInterval(-3_600), isDemo: true)
    }
    func tap(x: Int, y: Int, imageID: String) async throws { taps += 1 }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { XCTFail("Unexpected drag") }
    func stop() async { await demo.stop() }
}
