import XCTest
import LLMProviderKit
import LLMProviderKitOpenAI
@testable import PhoneAgent

final class ModelStreamTests: XCTestCase {
    let request = LLMRequest(model: "fixture", messages: [.user("synthetic")])
    let encoder = OpenAIProvider(configuration: LLMProviderConfiguration(name: "test", baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture"))
    private func line(_ delta: [String: Any], finish: String? = nil) throws -> String {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finish { choice["finish_reason"] = finish }
        let json = try JSONSerialization.data(withJSONObject: ["id": "test", "choices": [choice]])
        return "data: " + String(decoding: json, as: UTF8.self)
    }
    func testRealTextDeltasAndFragmentedToolAssembly() throws {
        var decoder = ModelStreamDecoder()
        let chunks = try decoder.consume(line: line(["content": "你好", "reasoning_content": "private reasoning"]), request: request, encoder: encoder)
        XCTAssertEqual(chunks.count, 1)
        if case .text(let text) = chunks.first { XCTAssertEqual(text, "你好") } else { XCTFail("Expected public text") }
        let first: [String: Any] = ["tool_calls": [["index": 0, "id": "call-1", "type": "function", "function": ["name": "tap", "arguments": "{\"x\":"]]]]
        let next: [String: Any] = ["tool_calls": [["index": 0, "function": ["arguments": "12}"]]]]
        XCTAssertTrue(try decoder.consume(line: line(first), request: request, encoder: encoder).isEmpty)
        XCTAssertTrue(try decoder.consume(line: line(next, finish: "tool_calls"), request: request, encoder: encoder).isEmpty)
        _ = try decoder.consume(line: "data: [DONE]", request: request, encoder: encoder)
        let final = try decoder.finish()
        XCTAssertEqual(final.count, 2)
        if case .toolCall(let call) = final[0] { XCTAssertEqual(call.name, "tap"); XCTAssertEqual(call.arguments, "{\"x\":12}"); XCTAssertEqual(call.id, "call-1") }
        else { XCTFail("Expected exactly one assembled tool call") }
    }
    func testTruncatedOrMissingToolArgumentsNeverReleaseCalls() throws {
        var decoder = ModelStreamDecoder()
        _ = try decoder.consume(line: line(["tool_calls": [["index": 0, "function": ["name": "tap", "arguments": "{"]]]]), request: request, encoder: encoder)
        XCTAssertThrowsError(try decoder.finish())
        _ = try decoder.consume(line: line([:], finish: "tool_calls"), request: request, encoder: encoder)
        XCTAssertThrowsError(try decoder.finish())
        var missing = ModelStreamDecoder()
        _ = try missing.consume(line: line([:], finish: "tool_calls"), request: request, encoder: encoder)
        XCTAssertThrowsError(try missing.finish())
    }
    func testMultipleToolCallsAreRejectedBeforeExecution() throws {
        var decoder = ModelStreamDecoder()
        let calls = (0...1).map { index in ["index": index, "id": "call-\(index)", "function": ["name": "tap", "arguments": "{}"]] as [String: Any] }
        _ = try decoder.consume(line: line(["tool_calls": calls]), request: request, encoder: encoder)
        XCTAssertThrowsError(try decoder.consume(line: line([:], finish: "tool_calls"), request: request, encoder: encoder))
    }
    func testStreamingRequestUsesActualStreamFlag() throws {
        let provider = try PrivateVisionProvider(settings: ProviderSettings(baseURL: "https://invalid.invalid/v1", model: "fixture"), apiKey: "synthetic-test-only", limits: AgentLimits())
        defer { provider.cancel() }
        let body = try XCTUnwrap(provider.prepareRequest(request, stream: true).httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["parallel_tool_calls"] as? Bool, false)
    }
}
