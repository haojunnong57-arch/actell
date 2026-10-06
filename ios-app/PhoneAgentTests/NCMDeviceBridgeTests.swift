import XCTest
import UIKit
import LLMProviderKit
@testable import PhoneAgent

@MainActor private final class NCMConnectionSpy: NCMControlConnection {
    var ready = true
    var running = false
    var agentReserved = false
    var controlSessionID = UUID()
    var taps = 0
    var drags: [UInt16] = []
    var releases = 0
    var reservations = 0
    var captures = 0
    var png: Data = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 20), format: {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
    }()).pngData { context in UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 20)) }
    func registerAgent(owner: UUID, session: UUID) { reservations += 1 }
    func agentCapture(owner: UUID, session: UUID) async throws -> Data { captures += 1; return png }
    func agentTap(owner: UUID, session: UUID, x: UInt16, y: UInt16, validate: () throws -> Void) async throws { try validate(); taps += 1 }
    func agentDrag(owner: UUID, session: UUID, fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16, validate: () throws -> Void) async throws { try validate(); drags = [fromX, fromY, toX, toY, durationMS] }
    func releaseAgent(owner: UUID, session: UUID) { releases += 1 }
}

@MainActor private final class NCMTestLease: RunBackgroundLease {
    var expirationHandler: (() -> Void)?
    func report(completed: Int, subtitle: String) {}
    func complete(success: Bool) {}
}
@MainActor private final class NCMTestScheduler: RunBackgroundScheduler {
    let lease = NCMTestLease()
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws { launched(lease) }
    func cancel(identifier: String) {}
}

@MainActor final class NCMDeviceBridgeTests: XCTestCase {
    func testUsesRemotePixelsAndRequiresApprovalBeforeInput() async throws {
        let connection = NCMConnectionSpy(), bridge = try NCMDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        XCTAssertEqual(frame.width, 10); XCTAssertEqual(frame.height, 20); XCTAssertFalse(frame.isDemo)
        do { try await bridge.tap(x: 100, y: 200, imageID: frame.id); XCTFail("unapproved input") } catch {}
        XCTAssertEqual(connection.taps, 0)
        try await bridge.acceptApproval(imageID: frame.id)
        try await bridge.tap(x: 100, y: 200, imageID: frame.id)
        do { try await bridge.tap(x: 100, y: 200, imageID: frame.id); XCTFail("replayed input") } catch {}
        XCTAssertEqual(connection.taps, 1)
    }
    func testReconnectInvalidatesOldRunEvenWhenReadyAgain() async throws {
        let connection = NCMConnectionSpy(), bridge = try NCMDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        try await bridge.authorizeTaskInput(imageID: frame.id)
        connection.controlSessionID = UUID()
        do { try await bridge.tap(x: 0, y: 0, imageID: frame.id); XCTFail("new generation accepted") } catch {}
        do { _ = try await bridge.screenshot(); XCTFail("old run reconnect") } catch {}
        XCTAssertEqual(connection.taps, 0)
    }
    func testDragForwardsNormalizedCoordinatesAndInvalidatesImage() async throws {
        let connection = NCMConnectionSpy(), bridge = try NCMDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        try await bridge.authorizeTaskInput(imageID: frame.id)
        try await bridge.drag(fromX: 0, fromY: 65535, toX: 65535, toY: 0, durationMS: 1000, imageID: frame.id)
        XCTAssertEqual(connection.drags, [0, 65535, 65535, 0, 1000])
        do { try await bridge.tap(x: 0, y: 0, imageID: frame.id); XCTFail("stale image accepted") } catch {}
    }
    func testCancellationFencesBeforeAsynchronousRelease() async throws {
        let connection = NCMConnectionSpy(), bridge = try NCMDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        try await bridge.acceptApproval(imageID: frame.id)
        bridge.cancelTransport()
        do { try await bridge.tap(x: 0, y: 0, imageID: frame.id); XCTFail("cancelled input") } catch {}
        XCTAssertEqual(connection.taps, 0)
        await bridge.stop()
        XCTAssertTrue(connection.ready)
    }
    func testInvalidScreenshotRevokesPreviousImageApproval() async throws {
        let connection = NCMConnectionSpy(), bridge = try NCMDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        try await bridge.acceptApproval(imageID: frame.id)
        connection.png = Data()
        do { _ = try await bridge.screenshot(); XCTFail("invalid PNG accepted") } catch {}
        do { try await bridge.tap(x: 0, y: 0, imageID: frame.id); XCTFail("prior frame reused") } catch {}
        XCTAssertEqual(connection.taps, 0)
    }
    func testDisconnectedBridgeReportsErrorOnlyWhenToolIsCalledAndCanBindLater() async throws {
        let connection = NCMConnectionSpy(); connection.ready = false
        let bridge = try NCMDeviceBridge(flow: connection)
        XCTAssertEqual(connection.reservations, 0)
        do { _ = try await bridge.screenshot(); XCTFail("disconnected capture") } catch {}
        XCTAssertEqual(connection.captures, 0)
        connection.controlSessionID = UUID(); connection.ready = true
        _ = try await bridge.screenshot()
        XCTAssertEqual(connection.reservations, 1)
        XCTAssertEqual(connection.captures, 1)
    }
    func testBackgroundCapabilityDoesNotTurnConnectionFailureIntoLifecyclePause() async throws {
        let connection = NCMConnectionSpy(), bridge = try NCMDeviceBridge(flow: connection)
        _ = try await bridge.screenshot()
        connection.controlSessionID = UUID()
        let capable = await bridge.supportsBackgroundExecution(tool: "screenshot")
        XCTAssertTrue(capable)
        do { _ = try await bridge.screenshot(); XCTFail("old generation accepted") } catch {}
        XCTAssertEqual(connection.captures, 1)
    }
    func testDisconnectedOrdinaryChatAndFailedToolBothAllowModelReply() async throws {
        for requestsScreenshot in [false, true] {
            let connection = NCMConnectionSpy(); connection.ready = false
            let bridge = try NCMDeviceBridge(flow: connection)
            let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                runServices: AgentRunServices(provider: DisconnectedChatProvider(requestsScreenshot: requestsScreenshot), bridge: bridge))
            let id = model.createConversation(mode: .live)
            XCTAssertTrue(model.send("你好", in: id, cloudConsent: true))
            for _ in 0..<200 {
                if !model.running && !model.stopping { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(model.running)
            XCTAssertEqual(model.sessions.conversation(id)?.phase, .completed)
            XCTAssertTrue(model.sessions.conversation(id)?.messages.contains { $0.role == .assistant && $0.text == "正常回复" } ?? false)
            let tools = model.sessions.conversation(id)?.messages.compactMap(\.tool) ?? []
            XCTAssertEqual(tools.count, requestsScreenshot ? 1 : 0)
            if requestsScreenshot { XCTAssertEqual(tools.first?.state, .failed) }
            XCTAssertEqual(connection.reservations, 0)
            XCTAssertEqual(connection.captures, 0)
        }
    }
    func testOrdinaryRunPreservesBackgroundConnectionWithoutReservingDevice() async throws {
        let flow = PairingFlow(); flow.ready = true
        let bridge = try NCMDeviceBridge(flow: flow)
        XCTAssertFalse(flow.agentReserved)
        flow.background()
        XCTAssertTrue(flow.ready)
        await bridge.stop()
        XCTAssertFalse(flow.ready)
    }
    func testDeviceRunsQueueAndWaitingCancellationPreservesOwner() async throws {
        let flow = PairingFlow(); flow.ready = true
        let session = flow.controlSessionID, a = UUID(), b = UUID(), c = UUID()
        flow.registerAgent(owner: a, session: session)
        flow.registerAgent(owner: b, session: session)
        flow.registerAgent(owner: c, session: session)
        _ = try await flow.agentOperation(owner: a, session: session) { _ in 1 }
        flow.background()
        XCTAssertTrue(flow.ready)
        var secondEntered = false, thirdEntered = false
        let second = Task { try await flow.agentOperation(owner: b, session: session) { _ in secondEntered = true } }
        let third = Task { try await flow.agentOperation(owner: c, session: session) { _ in thirdEntered = true } }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(secondEntered); XCTAssertFalse(thirdEntered)
        second.cancel(); flow.releaseAgent(owner: b, session: session)
        do { try await second.value; XCTFail("cancelled waiter ran") } catch {}
        XCTAssertTrue(flow.ready)
        _ = try await flow.agentOperation(owner: a, session: session) { _ in 2 }
        flow.releaseAgent(owner: a, session: session)
        try await third.value
        XCTAssertTrue(thirdEntered); XCTAssertFalse(secondEntered)
        XCTAssertTrue(flow.ready)
        flow.releaseAgent(owner: c, session: session)
        XCTAssertFalse(flow.ready)
    }

    func testNCMRunCanCaptureAndTapInBackgroundWithoutScreenCapture() async throws {
        let connection = NCMConnectionSpy(), bridge = try NCMDeviceBridge(flow: connection)
        let synthetic = try await DemoBridge().screenshot()
        connection.png = synthetic.png
        let scheduler = NCMTestScheduler()
        let lifecycle = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
            runServices: AgentRunServices(provider: DemoProvider(), bridge: bridge), lifecycle: lifecycle)
        let id = model.createConversation(mode: .live)
        XCTAssertTrue(model.send("test", in: id, cloudConsent: true))
        XCTAssertTrue(lifecycle.hasLease)
        XCTAssertFalse(model.capture.active)
        model.setForeground(false)
        for _ in 0..<200 {
            if !model.running && !model.stopping { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(model.running)
        XCTAssertEqual(connection.taps, 1)
        XCTAssertTrue(model.sessions.conversation(id)?.messages.compactMap(\.tool).contains { $0.name == "screenshot" && $0.state == .succeeded } ?? false)
    }

    func testConnectionFailureClearsAllOwnersAndNeverReplaysQueuedInput() async throws {
        let flow = PairingFlow(); flow.ready = true
        let old = flow.controlSessionID, a = UUID(), b = UUID()
        flow.registerAgent(owner: a, session: old); flow.registerAgent(owner: b, session: old)
        _ = try await flow.agentOperation(owner: a, session: old) { _ in 1 }
        var entered = false
        let waiter = Task { try await flow.agentOperation(owner: b, session: old) { _ in entered = true } }
        try await Task.sleep(for: .milliseconds(50))
        do {
            _ = try await flow.agentOperation(owner: a, session: old) { _ in throw NativeBackendError.malformedEvent }
            XCTFail("failure ignored")
        } catch {}
        XCTAssertFalse(flow.agentReserved)
        XCTAssertNotEqual(flow.controlSessionID, old)
        flow.ready = true // Reconnection must not revive an old queued run.
        do { try await waiter.value; XCTFail("queued run survived reconnect") } catch {}
        XCTAssertFalse(entered)
        flow.cancel()
    }

}

private struct DisconnectedChatProvider: LLMProvider {
    static let name = "disconnected-chat-fixture"
    let configuration = LLMProviderConfiguration(name: Self.name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    let requestsScreenshot: Bool
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let result = request.messages.first { $0.role == .tool }
        if requestsScreenshot && result == nil {
            return LLMResponse(text: "", finishReason: .toolCalls,
                toolCalls: [LLMToolCall(id: "screen", name: "screenshot", arguments: "{}")], request: request, providerName: Self.name)
        }
        if requestsScreenshot && result?.content.contains("手机操控未连接") != true {
            throw AppError.invalid("模型未收到设备工具的连接错误")
        }
        return LLMResponse(text: "正常回复", finishReason: .stop, request: request, providerName: Self.name)
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                    for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.yield(.finish(reason: response.finishReason, usage: nil)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
