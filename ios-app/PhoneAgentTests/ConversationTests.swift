import XCTest
@testable import PhoneAgent

@MainActor final class ConversationTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testPersistAndRestoreInterruptsUnfinishedToolsWithoutResuming() throws {
        let directory = try temporaryDirectory()
        let store = ConversationStore(directory: directory)
        let id = store.create(mode: .demo)
        let token = try XCTUnwrap(store.begin(in: id, query: "任务 A"))
        store.beginAssistantTurn(token); store.appendText("部分公开回复", identity: token)
        store.updateTool(callID: "tap-a", name: "tap", state: .awaitingApproval, detail: "确认一次点击", identity: token)
        store.saveNow()
        let restored = ConversationStore(directory: directory)
        let session = try XCTUnwrap(restored.conversation(id))
        XCTAssertNil(restored.activeRun)
        XCTAssertEqual(session.phase, .interrupted)
        XCTAssertEqual(session.messages.first?.text, "任务 A")
        XCTAssertEqual(session.messages.first(where: { $0.role == .assistant })?.state, .interrupted)
        XCTAssertEqual(session.messages.last?.tool?.state, .cancelled)
    }
    func testLateEventsCannotAffectAnotherConversationOrLaterRun() throws {
        let store = ConversationStore(inMemory: true)
        let a = store.create(mode: .demo), b = store.create(mode: .live)
        let old = try XCTUnwrap(store.begin(in: a, query: "A"))
        store.beginAssistantTurn(old); store.finish(old, phase: .stopped, summary: "停止")
        let current = try XCTUnwrap(store.begin(in: b, query: "B"))
        store.beginAssistantTurn(current)
        store.appendText("迟到的 A", identity: old)
        store.updateTool(callID: "old", name: "tap", state: .succeeded, identity: old)
        store.finish(old, phase: .completed, summary: "错误结束")
        store.appendText("B 的回复", identity: current)
        XCTAssertEqual(store.activeRun, current)
        XCTAssertFalse(store.conversations.flatMap(\.messages).contains(where: { $0.text.contains("迟到") || $0.tool?.callID == "old" }))
        XCTAssertEqual(store.conversation(b)?.messages.last?.text, "B 的回复")
    }
    func testDuplicateBeginDoesNotAppendSecondUserMessage() throws {
        let store = ConversationStore(inMemory: true), id = UUID()
        XCTAssertNil(store.begin(in: id, query: "无效会话"))
        let actual = store.create(mode: .demo)
        XCTAssertNotNil(store.begin(in: actual, query: "第一条"))
        XCTAssertNil(store.begin(in: actual, query: "重复"))
        XCTAssertEqual(store.conversation(actual)?.messages.count, 1)
    }
    func testHistoryContainsOnlyCompletedPublicTextFromSelectedConversation() throws {
        let store = ConversationStore(inMemory: true)
        let id = store.create(mode: .demo)
        let token = try XCTUnwrap(store.begin(in: id, query: "问题"))
        store.beginAssistantTurn(token); store.completeAssistantTurn("公开答案", identity: token)
        store.updateTool(callID: "s", name: "screenshot", state: .succeeded, result: "private image metadata", identity: token)
        store.beginAssistantTurn(token); store.appendText("中断片段", identity: token)
        store.finish(token, phase: .interrupted, summary: "中断")
        XCTAssertEqual(store.history(in: id).map(\.text), ["问题", "公开答案"])
        XCTAssertTrue(store.history(in: UUID()).isEmpty)
    }
    func testUnreadableHistoryIsNeverOverwritten() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("conversations-v1.json")
        let original = Data("broken but preserve me".utf8)
        try original.write(to: file)
        let store = ConversationStore(directory: directory)
        XCTAssertNotNil(store.warning)
        store.create(mode: .demo); store.saveNow()
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testLegacyMigrationRunsOnlyOnceAndPreservesDrafts() throws {
        let directory = try temporaryDirectory()
        let legacy = TaskRecord(goal: "旧任务", mode: .demo)
        let store = ConversationStore(directory: directory, legacy: [legacy])
        store.setDraft("下次继续的消息", in: legacy.id); store.saveNow()
        let restored = ConversationStore(directory: directory, legacy: [legacy, legacy])
        XCTAssertEqual(restored.conversations.count, 1)
        XCTAssertEqual(restored.conversation(legacy.id)?.draft, "下次继续的消息")
        XCTAssertEqual(restored.conversation(legacy.id)?.messages.first?.text, "旧任务")
    }
    func testQueuedToolStartCannotUndoApprovalState() throws {
        let store = ConversationStore(inMemory: true), id = store.create(mode: .demo)
        let token = try XCTUnwrap(store.begin(in: id, query: "test"))
        store.updateTool(callID: "one", name: "tap", state: .awaitingApproval, detail: "正确详情", identity: token)
        store.updateTool(callID: "one", name: "tap", state: .running, identity: token)
        XCTAssertEqual(store.conversation(id)?.messages.last?.tool?.state, .awaitingApproval)
        XCTAssertEqual(store.conversation(id)?.messages.last?.tool?.detail, "正确详情")
    }
}

@MainActor final class ConversationRuntimeTests: XCTestCase {
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTFail("Timed out waiting for deterministic offline runtime")
        throw AppError.timeout
    }
    func testDemoUsesRealAgentLoopAndStructuredToolEvents() async throws {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false)
        defer { model.stop() }
        let id = model.createConversation(mode: .demo)
        XCTAssertTrue(model.send("演示", in: id))
        try await waitUntil { model.approval(in: id) != nil }
        let approval = try XCTUnwrap(model.approval(in: id))
        model.approve(true, approvalID: approval.id, conversationID: id)
        try await waitUntil { !model.running }
        let session = try XCTUnwrap(store.conversation(id))
        XCTAssertEqual(session.phase, .completed)
        XCTAssertEqual(session.messages.compactMap(\.tool).map(\.name), ["screenshot", "tap", "screenshot", "finish"])
        XCTAssertTrue(session.messages.compactMap(\.tool).allSatisfy { $0.state == .succeeded })
        XCTAssertTrue(session.messages.contains { $0.role == .assistant && $0.text.contains("离线脚本") })
    }
    func testToolFailureReachesNextModelTurnWithoutDuplicateNotice() async throws {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false,
            runServices: AgentRunServices(provider: ToolErrorFixtureProvider(), bridge: UnavailableBridge()))
        defer { model.stop() }
        let id = model.createConversation(mode: .live)
        XCTAssertTrue(model.send("查看屏幕", in: id, cloudConsent: true))
        try await waitUntil { !model.running }
        let session = try XCTUnwrap(store.conversation(id))
        let tools = session.messages.compactMap(\.tool)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.callID, "fixture-screenshot")
        XCTAssertEqual(tools.first?.state, .failed)
        XCTAssertEqual(tools.first?.result, "设备未连接。可继续文字对话；设备操作需在设置 → 控制调试中连接桥接。")
        // The fixture emits this only after validating the exact ERROR result,
        // role=tool and matching call ID in the real framework's next request.
        XCTAssertEqual(session.messages.last?.role, .assistant)
        XCTAssertEqual(session.messages.last?.text, ToolErrorFixtureProvider.reply)
        XCTAssertFalse(session.messages.contains { $0.role == .notice })
        XCTAssertEqual(session.phase, .completed)
        XCTAssertNil(model.approval)
        XCTAssertNil(store.activeRun)
    }
    func testEmptyReplyAfterToolFailureDoesNotReuseNarrationOrAddNotice() async throws {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false,
            runServices: AgentRunServices(provider: ToolErrorFixtureProvider(initialText: "我会查看屏幕。", finalReply: ""), bridge: UnavailableBridge()))
        defer { model.stop() }
        let id = model.createConversation(mode: .live)
        XCTAssertTrue(model.send("查看屏幕", in: id, cloudConsent: true))
        try await waitUntil { !model.running }
        let session = try XCTUnwrap(store.conversation(id))
        XCTAssertEqual(session.phase, .blocked)
        XCTAssertEqual(session.messages.last?.tool?.state, .failed)
        XCTAssertFalse(session.messages.contains { $0.role == .notice })
        XCTAssertEqual(session.messages.filter { $0.role == .assistant }.map(\.text), ["我会查看屏幕。"])
    }
    func testRapidSwitchAndStaleApprovalCannotExecuteInNewConversation() async throws {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false)
        defer { model.stop() }
        let a = model.createConversation(mode: .demo)
        XCTAssertTrue(model.send("A", in: a))
        XCTAssertFalse(model.send("重复 A", in: a))
        try await waitUntil { model.approval(in: a) != nil }
        let oldApproval = try XCTUnwrap(model.approval(in: a))
        let b = model.createConversation(mode: .demo)
        XCTAssertFalse(model.send("清理期间不能发送", in: b))
        model.approve(true, approvalID: oldApproval.id, conversationID: a)
        try await waitUntil { !model.stopping }
        XCTAssertEqual(store.conversation(a)?.phase, .interrupted)
        XCTAssertTrue(model.send("B", in: b))
        try await waitUntil { model.approval(in: b) != nil }
        let current = try XCTUnwrap(model.approval(in: b))
        model.approve(true, approvalID: oldApproval.id, conversationID: a)
        XCTAssertEqual(model.approval(in: b)?.id, current.id)
        model.approve(false, approvalID: current.id, conversationID: b)
        try await waitUntil { !model.stopping }
        XCTAssertFalse(store.conversations.flatMap(\.messages).contains { $0.tool?.name == "tap" && $0.tool?.state == .succeeded })
        XCTAssertEqual(store.conversation(a)?.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(store.conversation(b)?.messages.first?.text, "B")
    }
    func testBackgroundCancellationFencesLateEvents() async throws {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false)
        let id = model.createConversation(mode: .demo)
        XCTAssertTrue(model.send("停止测试", in: id))
        model.setForeground(false)
        try await waitUntil { !model.stopping }
        XCTAssertEqual(store.conversation(id)?.phase, .interrupted)
        XCTAssertNil(store.activeRun)
        XCTAssertNil(model.approval)
        XCTAssertFalse(model.send("后台不能发送", in: id))
    }
    func testLiveSendRequiresExplicitConsentBeforeReadingKeysOrRunning() {
        let store = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: store, loadPersistentState: false)
        let id = model.createConversation(mode: .live)
        XCTAssertFalse(model.send("测试", in: id))
        XCTAssertFalse(model.running)
        XCTAssertTrue(store.conversation(id)?.messages.isEmpty == true)
    }
}
