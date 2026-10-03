import XCTest
import SwiftAgentKit
import LLMProviderKit
@testable import PhoneAgent

private actor SpyBridge: DeviceBridge {
    private(set) var taps = 0
    private(set) var stopped = false
    func screenshot() async throws -> FrameImage { FrameImage(id: "fresh", png: Data(), width: 390, height: 844, capturedAt: Date(), isDemo: true) }
    func tap(x: Int, y: Int, imageID: String) async throws { taps += 1 }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws {}
    func stop() async { stopped = true }
}
final class SafetyTests: XCTestCase {
    func testApprovalDeniedNeverSendsInput() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in false }, onImage: { _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        do {
            _ = try await c.execute(name: "tap", parameters: ["x": 100, "y": 100, "based_on_image_id": "fresh", "purpose": "test"], callID: "t")
            XCTFail("Denied input must not run")
        } catch {}
        let count = await bridge.taps; XCTAssertEqual(count, 0)
    }
    func testFreshImageRequiredAfterEveryInput() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        let p: [String: Any] = ["x": 100, "y": 100, "based_on_image_id": "fresh", "purpose": "test"]
        _ = try await c.execute(name: "tap", parameters: p, callID: "t1")
        do { _ = try await c.execute(name: "tap", parameters: p, callID: "t2"); XCTFail("Old image must fail") } catch {}
        let count = await bridge.taps; XCTAssertEqual(count, 1)
    }
    func testStopFencesLaterTools() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _ in }, onReceipt: { _ in })
        await c.stop()
        do { _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s"); XCTFail("Stopped session must fail") } catch {}
        let value = await bridge.stopped; XCTAssertTrue(value)
    }
    func testFinishRequiresFreshObservation() async throws {
        let c = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _ in }, onReceipt: { _ in })
        do { _ = try await c.execute(name: "finish", parameters: ["summary": "done"], callID: "f"); XCTFail("No image means no finish") } catch {}
    }
    func testBooleansCannotBecomePixelCoordinates() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        do { _ = try await c.execute(name: "tap", parameters: ["x": true, "y": 0, "based_on_image_id": "fresh", "purpose": "bad"], callID: "t"); XCTFail("Boolean must fail") } catch {}
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
