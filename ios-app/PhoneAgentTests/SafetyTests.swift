import XCTest
import SwiftAgentKit
import LLMProviderKit
@testable import PhoneAgent

private actor SpyBridge: DeviceBridge {
    private(set) var taps = 0
    private(set) var drags = 0
    private(set) var stopped = false
    let tapError: AppError?
    let capturedAt: Date
    init(tapError: AppError? = nil, capturedAt: Date = Date()) { self.tapError = tapError; self.capturedAt = capturedAt }
    func screenshot() async throws -> FrameImage { FrameImage(id: "fresh", png: Data(), width: 390, height: 844, capturedAt: capturedAt, isDemo: true) }
    func tap(x: Int, y: Int, imageID: String) async throws { taps += 1; if let tapError { throw tapError } }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { drags += 1 }
    func stop() async { stopped = true }
}
final class SafetyTests: XCTestCase {
    func testInputSchemasOnlyRequireCoordinatesDurationAndPurpose() {
        let coordinator = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        for (name, keys) in [("tap", ["x", "y", "purpose"]),
                             ("drag", ["from_x", "from_y", "to_x", "to_y", "duration_ms", "purpose"])] {
            let schema = DeviceTool(name: name, coordinator: coordinator).parameters
            XCTAssertEqual(Set(schema.properties.keys), Set(keys))
            XCTAssertEqual(Set(schema.required), Set(keys))
        }
    }
    func testOldScreenshotSupportsTapDragAndFinishWithoutModelImageIdentifier() async throws {
        let bridge = SpyBridge(capturedAt: Date().addingTimeInterval(-3_600))
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { request in
            XCTAssertGreaterThan(request.expiresAt.timeIntervalSinceNow, 40, "Request timeout must not be based on capture time")
            return true
        }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "s1")
        _ = try await coordinator.execute(name: "tap", parameters: ["x": 100, "y": 100, "purpose": "fixture tap"], callID: "t")
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "s2")
        _ = try await coordinator.execute(name: "drag", parameters: ["from_x": 100, "from_y": 100, "to_x": 120, "to_y": 120, "duration_ms": 200, "purpose": "fixture drag"], callID: "d")
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "s3")
        _ = try await coordinator.execute(name: "finish", parameters: ["summary": "fixture finished"], callID: "f")
        let taps = await bridge.taps, drags = await bridge.drags
        XCTAssertEqual(taps, 1); XCTAssertEqual(drags, 1)
    }
    func testToolValidationErrorReturnsNormallyAndAllowsCorrectedCall() async throws {
        let c = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        let actions = ToolActions()
        let tool = DeviceTool(name: "wait", coordinator: c)
        let failed = try await tool.execute(context: ToolContext(callId: "bad", toolName: "wait", parameters: ["duration_ms": 0], state: AgentState(), actions: actions))
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.result, "等待必须为 1–3000 毫秒")
        XCTAssertEqual(failed.toolCallId, "bad")
        XCTAssertFalse(actions.shouldStop)
        let corrected = try await tool.execute(context: ToolContext(callId: "corrected", toolName: "wait", parameters: ["duration_ms": 1], state: AgentState(), actions: actions))
        XCTAssertFalse(corrected.isError)
        XCTAssertFalse(actions.shouldStop)
    }
    func testUncertainInputReturnsErrorAndFencesBothInputToolsAfterNewScreenshot() async throws {
        let bridge = SpyBridge(tapError: .unknownOutcome)
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        let actions = ToolActions()
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        let failed = try await DeviceTool(name: "tap", coordinator: c).execute(context:
            ToolContext(callId: "t", toolName: "tap", parameters: ["x": 100, "y": 100, "purpose": "test"], state: AgentState(), actions: actions))
        XCTAssertTrue(failed.isError)
        XCTAssertTrue(failed.result.contains("动作结果未知"))
        XCTAssertFalse(actions.shouldStop)
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s2")
        for name in ["tap", "drag"] {
            let result = try await DeviceTool(name: name, coordinator: c).execute(context:
                ToolContext(callId: name + "-blocked", toolName: name, parameters: ["x": 100, "y": 100, "from_x": 100, "from_y": 100, "to_x": 120, "to_y": 120, "duration_ms": 200, "purpose": "must not send"], state: AgentState(), actions: actions))
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.result.contains("本轮后续点击和拖动已禁用"))
            XCTAssertFalse(actions.shouldStop)
        }
        let taps = await bridge.taps, drags = await bridge.drags
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(drags, 0)
    }
    func testExplicitStopStillEndsToolExecution() async throws {
        let c = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        await c.stop()
        let actions = ToolActions()
        do {
            _ = try await DeviceTool(name: "screenshot", coordinator: c).execute(context: ToolContext(callId: "s", toolName: "screenshot", parameters: [:], state: AgentState(), actions: actions))
            XCTFail("An explicit stop must not become a recoverable tool result")
        } catch { XCTAssertEqual(error as? AppError, .stopped) }
        XCTAssertTrue(actions.shouldStop)
    }
    func testApprovalDeniedNeverSendsInput() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in false }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        do {
            _ = try await c.execute(name: "tap", parameters: ["x": 100, "y": 100, "purpose": "test"], callID: "t")
            XCTFail("Denied input must not run")
        } catch {}
        let count = await bridge.taps; XCTAssertEqual(count, 0)
    }
    func testTaskAuthorizationCannotGrantAnUnsupportedBridgeInputPermission() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true },
                                  onImage: { _, _ in }, onReceipt: { _ in }, authorizationMode: .task)
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        do {
            _ = try await c.execute(name: "tap", parameters: ["x": 100, "y": 100, "purpose": "fixture"], callID: "t")
            XCTFail("Task authorization must be explicitly supported by the input bridge")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不支持任务内自动授权")) }
        let count = await bridge.taps; XCTAssertEqual(count, 0)
    }
    func testFreshImageRequiredAfterEveryInput() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        let p: [String: Any] = ["x": 100, "y": 100, "purpose": "test"]
        _ = try await c.execute(name: "tap", parameters: p, callID: "t1")
        do { _ = try await c.execute(name: "tap", parameters: p, callID: "t2"); XCTFail("Old image must fail") } catch {}
        let count = await bridge.taps; XCTAssertEqual(count, 1)
    }
    func testStopFencesLaterTools() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        await c.stop()
        do { _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s"); XCTFail("Stopped session must fail") } catch {}
        let value = await bridge.stopped; XCTAssertTrue(value)
    }
    func testFinishRequiresFreshObservation() async throws {
        let c = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        do { _ = try await c.execute(name: "finish", parameters: ["summary": "done"], callID: "f"); XCTFail("No image means no finish") } catch {}
    }
    func testBooleansCannotBecomePixelCoordinates() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        do { _ = try await c.execute(name: "tap", parameters: ["x": true, "y": 0, "purpose": "bad"], callID: "t"); XCTFail("Boolean must fail") } catch {}
        let count = await bridge.taps; XCTAssertEqual(count, 0)
    }
    func testOpenAIToolImagesUseAdjacentUserMessage() throws {
        let settings = ProviderSettings(baseURL: "https://example.com/v1", model: "vision")
        let provider = try PrivateVisionProvider(settings: settings, apiKey: "test-only-not-a-real-key", limits: AgentLimits())
        defer { provider.cancel() }
        let image = LLMImage(data: Data([1,2,3]))
        let request = LLMRequest(model: "vision", messages: [
            .assistant(content: "", toolCalls: [LLMToolCall(id: "call", name: "screenshot", arguments: "{}")]),
            LLMMessage(role: .tool, content: "screen", images: [image], toolCallId: "call")
        ])
        let body = try XCTUnwrap(try provider.prepareRequest(request, stream: false).httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["assistant", "tool", "user"])
        XCTAssertTrue(messages[1]["content"] is String)
        XCTAssertTrue(messages[2]["content"] is [[String: Any]])
        XCTAssertEqual(object["parallel_tool_calls"] as? Bool, false)
    }
}
