import XCTest
import SwiftAgentKit
@testable import PhoneAgent

@MainActor final class AgentPresentationTests: XCTestCase {
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTFail("Offline runtime did not reach expected state")
        throw AppError.timeout
    }
    private func pendingDemo() async throws -> (AgentViewModel, AgentPresentationAdapter, ToolPresentation) {
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false)
        let id = model.createConversation(mode: .demo)
        let ui = AgentPresentationAdapter(model: model, sessionID: id)
        XCTAssertTrue(ui.dispatch(.send(sessionID: id, text: "演示", cloudConsent: false)))
        try await waitUntil { ui.approvalID != nil }
        let message = try XCTUnwrap(ui.session?.messages.last { $0.tool?.name == "tap" })
        return (model, ui, try XCTUnwrap(ui.presentation(for: message)))
    }
    func testApprovalUsesSessionRunStepAndRequestIdentityAndConsumesOnce() async throws {
        let (model, ui, item) = try await pendingDemo()
        defer { model.stop() }
        let approval = try XCTUnwrap(item.approval)
        XCTAssertEqual(ui.pendingApproval?.identity, item.identity)
        XCTAssertEqual(ui.pendingApproval?.approval?.id, approval.id)
        XCTAssertEqual(ui.pendingApproval?.image?.id, approval.imageID)
        XCTAssertFalse(ui.dispatch(.approve(step: StepIdentity(run: RunIdentity(conversationID: UUID(), runID: item.identity.run.runID), stepID: item.identity.stepID), approvalID: approval.id)))
        XCTAssertFalse(ui.dispatch(.approve(step: StepIdentity(run: RunIdentity(conversationID: ui.sessionID, runID: UUID()), stepID: item.identity.stepID), approvalID: approval.id)))
        XCTAssertFalse(ui.dispatch(.approve(step: StepIdentity(run: item.identity.run, stepID: "other-step"), approvalID: approval.id)))
        XCTAssertFalse(ui.dispatch(.approve(step: item.identity, approvalID: UUID())))
        XCTAssertTrue(ui.dispatch(.approve(step: item.identity, approvalID: approval.id)))
        XCTAssertNil(ui.pendingApproval)
        XCTAssertFalse(ui.dispatch(.approve(step: item.identity, approvalID: approval.id)))
        try await waitUntil { !model.running }
        XCTAssertEqual(ui.session?.messages.compactMap(\.tool).filter { $0.name == "tap" && $0.state == .succeeded }.count, 1)
    }
    func testDenyIsDistinctFromStopAndReleasesPendingApproval() async throws {
        let (model, ui, item) = try await pendingDemo()
        let approval = try XCTUnwrap(item.approval)
        XCTAssertTrue(ui.dispatch(.deny(step: item.identity, approvalID: approval.id)))
        XCTAssertFalse(ui.dispatch(.approve(step: item.identity, approvalID: approval.id)))
        try await waitUntil { !model.stopping }
        XCTAssertNil(model.approval); XCTAssertNil(ui.activeRun)
        XCTAssertNil(ui.pendingApproval)
        XCTAssertEqual(ui.session?.phase, .blocked)
        XCTAssertEqual(ui.session?.messages.compactMap(\.tool).last?.state, .denied)
        XCTAssertFalse(ui.session?.messages.compactMap(\.tool).contains { $0.name == "tap" && $0.state == .succeeded } ?? true)
        // A new, explicit send is possible after cleanup; nothing resumes itself.
        XCTAssertTrue(ui.dispatch(.send(sessionID: ui.sessionID, text: "新一轮", cloudConsent: false)))
        model.stop()
        try await waitUntil { !model.stopping }
    }
    func testStopReleasesApprovalAndStaleStopCannotCancelNextRun() async throws {
        let (model, ui, item) = try await pendingDemo()
        XCTAssertTrue(ui.dispatch(.stop(run: item.identity.run)))
        XCTAssertFalse(ui.dispatch(.stop(run: item.identity.run)))
        try await waitUntil { !model.stopping }
        XCTAssertEqual(ui.session?.phase, .stopped)
        XCTAssertEqual(ui.session?.messages.compactMap(\.tool).last?.state, .cancelled)
        XCTAssertNil(model.approval)
        XCTAssertNil(ui.pendingApproval)
        XCTAssertTrue(ui.dispatch(.send(sessionID: ui.sessionID, text: "下一轮", cloudConsent: false)))
        XCTAssertFalse(ui.dispatch(.stop(run: item.identity.run)))
        XCTAssertTrue(model.running)
        model.stop(); try await waitUntil { !model.stopping }
    }
    func testScreenshotAndApprovalCannotAttachToHistoryOrOtherSession() async throws {
        let (model, ui, item) = try await pendingDemo()
        XCTAssertEqual(item.image?.id, item.approval?.imageID)
        let realMessage = try XCTUnwrap(ui.session?.messages.last { $0.tool?.name == "tap" })
        var historical = realMessage; historical.runID = UUID()
        XCTAssertNil(ui.presentation(for: historical)?.image)
        XCTAssertNil(ui.presentation(for: historical)?.approval)
        let otherID = model.createConversation(mode: .demo)
        let other = AgentPresentationAdapter(model: model, sessionID: otherID)
        XCTAssertNil(other.presentation(for: realMessage)?.image)
        XCTAssertNil(other.presentation(for: realMessage)?.approval)
        XCTAssertNil(other.pendingApproval)
        XCTAssertNil(ui.pendingApproval)
        XCTAssertFalse(ui.dispatch(.send(sessionID: ui.sessionID, text: "过期窗口", cloudConsent: false)))
        try await waitUntil { !model.stopping }
    }
    func testRealEventsProjectStreamingParametersAndDoNotLeakReasoning() throws {
        let store = ConversationStore(inMemory: true), id = store.create(mode: .demo)
        let run = try XCTUnwrap(store.begin(in: id, query: "test"))
        AgentEventProjection.record(.llmCallStarted(turn: 1), run: run, frame: nil, in: store)
        AgentEventProjection.record(.streamChunk("公开"), run: run, frame: nil, in: store)
        AgentEventProjection.record(.reasoningChunk("私有推理"), run: run, frame: nil, in: store)
        AgentEventProjection.record(.streamChunk("回复"), run: run, frame: nil, in: store)
        XCTAssertEqual(store.conversation(id)?.messages.last?.text, "公开回复")
        let call = AgentToolCall(id: "t", name: "tap", parameters: ["x": AnyCodable(100), "y": AnyCodable(200), "purpose": AnyCodable("点击演示"), "api_key": AnyCodable("never-display")])
        AgentEventProjection.record(.toolCallsReceived([call]), run: run, frame: nil, in: store)
        let tool = try XCTUnwrap(store.conversation(id)?.messages.last?.tool)
        XCTAssertEqual(tool.state, .requested)
        let data = try XCTUnwrap(tool.arguments?.data(using: .utf8))
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(args["x"] as? Int, 100); XCTAssertNil(args["api_key"])
        store.finish(run, phase: .interrupted, summary: "")
        let before = store.conversation(id)?.messages
        AgentEventProjection.record(.streamChunk("late"), run: run, frame: nil, in: store)
        AgentEventProjection.record(.toolExecutionStarted(call: call), run: run, frame: nil, in: store)
        XCTAssertEqual(store.conversation(id)?.messages, before)
    }
    func testDeniedStepCannotBeRevivedByQueuedEvents() throws {
        let store = ConversationStore(inMemory: true), id = store.create(mode: .demo)
        let run = try XCTUnwrap(store.begin(in: id, query: "test"))
        store.updateTool(callID: "t", name: "tap", state: .denied, result: "拒绝", identity: run)
        store.updateTool(callID: "t", name: "tap", state: .succeeded, result: "错误成功", identity: run)
        XCTAssertEqual(store.conversation(id)?.messages.last?.tool?.state, .denied)
        XCTAssertEqual(store.conversation(id)?.messages.last?.tool?.result, "拒绝")
    }
    func testSavingSettingsIsBlockedDuringRunAndCleanup() async throws {
        let (model, ui, item) = try await pendingDemo()
        // This deliberately invalid configuration would fail before any secret
        // access even if the guard regressed. No real credential is read/written.
        model.settings = ProviderSettings(baseURL: "invalid", model: "")
        model.saveSettings(key: "", psk: "")
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(ui.dispatch(.stop(run: item.identity.run)))
        model.saveSettings(key: "", psk: "")
        XCTAssertNil(model.errorMessage)
        try await waitUntil { !model.stopping }
    }
}
