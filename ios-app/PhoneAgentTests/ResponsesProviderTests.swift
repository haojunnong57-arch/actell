import XCTest
import ProviderCore
import OpenAIAdapter
import SwiftAgentKit
@testable import PhoneAgent

final class ResponsesProviderTests: XCTestCase {
    private let configuration = ProviderConfiguration(name: "fixture", baseURL: URL(string: "https://invalid.invalid/proxy/v1")!, apiKey: "synthetic", defaultModel: "fixture")
    private let scope = ProviderScope(provider: "fixture", endpoint: "https://invalid.invalid/proxy/v1", account: "fixture-account", model: "fixture")
    private var request: ModelRequest { .init(model: "fixture", messages: [.system("safety instructions"), .user("task")]) }
    private func json(_ o: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }
    private func message(_ text: String = "final answer", id: String = "msg") -> [String: Any] {
        ["type": "message", "id": id, "status": "completed", "role": "assistant", "content": [["type": "output_text", "text": text, "annotations": []]]]
    }
    private func call(_ id: String = "call1", item: String = "fc1", name: String = "tap", args: String = "{\"x\":1}") -> [String: Any] {
        ["type": "function_call", "id": item, "status": "completed", "call_id": id, "name": name, "arguments": args]
    }
    private var reasoning: [String: Any] { ["type": "reasoning", "id": "reason", "summary": [["type": "summary_text", "text": "public summary"]], "encrypted_content": "OPAQUE_DO_NOT_DISPLAY"] }
    private func envelope(_ output: [[String: Any]], status: String = "completed", id: String = "resp1") -> [String: Any] {
        ["id": id, "model": "fixture", "status": status, "output": output, "usage": ["input_tokens": 12, "output_tokens": 5, "total_tokens": 17, "input_tokens_details": ["cached_tokens": 3], "output_tokens_details": ["reasoning_tokens": 2]]]
    }
    private func event(_ type: String, seq: Int, fields: [String: Any] = [:]) throws -> String {
        var o = fields; o["type"] = type; o["sequence_number"] = seq; return String(decoding: try json(o), as: UTF8.self)
    }
    private func reducer(_ output: [[String: Any]]) throws -> ResponsesReducer {
        let codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: scope)
        var r = ResponsesReducer(codec: codec, request: request)
        _ = try r.consume(payload: event("response.created", seq: 0, fields: ["response": ["id": "resp1", "status": "in_progress"]]))
        for (i, item) in output.enumerated() {
            _ = try r.consume(payload: event("response.output_item.added", seq: i * 2 + 1, fields: ["output_index": i, "item": item]))
            _ = try r.consume(payload: event("response.output_item.done", seq: i * 2 + 2, fields: ["output_index": i, "item": item]))
        }
        return r
    }
    func testNativeMixedOrderedOutputAndExplicitReplayPreserveOpaqueRefusalAnnotations() throws {
        let codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: scope)
        var m = message(); m["phase"] = "final_answer"; m["vendor_note"] = "preserved"
        m["content"] = [["type": "output_text", "text": "answer", "annotations": [["type": "url_citation", "url": "https://example.invalid", "title": "fixture", "start_index": 0, "end_index": 6]]], ["type": "refusal", "refusal": "refusal"]]
        let response = try codec.parseResponse(json(envelope([reasoning, m, call(), call("call2", item: "fc2")])), request: request)
        XCTAssertEqual(response.output.count, 4); XCTAssertEqual(response.reasoning, "public summary"); XCTAssertFalse(response.text.contains("OPAQUE"))
        XCTAssertEqual(response.toolCalls.map(\.id), ["call1", "call2"]); XCTAssertEqual(response.toolCalls.map(\.itemID), ["fc1", "fc2"])
        XCTAssertEqual(response.usage?.reasoningTokens, 2); XCTAssertEqual(response.usage?.cachedTokens, 3)
        var next = request; next.input = try response.output.map { try $0.asReplayInput(scope: scope) }; next.instructions = "new safety"
        let body = try XCTUnwrap(codec.prepareRequest(next, stream: true).httpBody)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(o["store"] as? Bool, false); XCTAssertEqual(o["instructions"] as? String, "new safety")
        let input = try XCTUnwrap(o["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String }, ["reasoning", "message", "function_call", "function_call"])
        XCTAssertEqual(input[0]["encrypted_content"] as? String, "OPAQUE_DO_NOT_DISPLAY")
        XCTAssertEqual(input[1]["vendor_note"] as? String, "preserved")
        XCTAssertEqual((input[1]["content"] as? [[String: Any]])?.first?["type"] as? String, "output_text")
    }
    func testCompletedEnvelopeWithFailureDetailsCannotDispatch() throws {
        let codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: scope)
        for field in ["error", "incomplete_details"] {
            var object = envelope([call()]); object[field] = ["code": "failure", "reason": "max_output_tokens"]
            let response = try codec.parseResponse(json(object), request: request)
            XCTAssertThrowsError(try ResponsesReducer.requireExecutable(response))
        }
    }
    func testImagesAndToolResultsUseNativeInputTypesAndCallIdentity() throws {
        let codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: scope)
        var r = request
        r.input = [.message(role: .user, content: [.text("look"), .image(.init(data: Data([1, 2]), mimeType: "image/jpeg"))]), .functionResult(callID: "call1", output: "executed")]
        let outgoing = try codec.prepareRequest(r, stream: false)
        XCTAssertEqual(outgoing.url?.absoluteString, "https://invalid.invalid/proxy/v1/responses")
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(outgoing.httpBody)) as? [String: Any]); let input = try XCTUnwrap(o["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["input_text", "input_image"])
        XCTAssertEqual(input[1]["call_id"] as? String, "call1"); XCTAssertNil(input[1]["item_id"])
    }
    func testBothContextModesResendInstructionsAndChainSendsOnlyNewResults() throws {
        for policy in [StoragePolicy.none, .responseChain] {
            let s = scope, c = try ContextCoordinator(scope: s, storage: policy)
            let codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: s)
            let first = try c.prepare(request), response = try codec.parseResponse(json(envelope([reasoning, call()])), request: first.request)
            try c.commit(response, prepared: first)
            var next = request; next.messages += [.assistant(content: "", toolCalls: response.toolCalls), .tool("receipt", toolCallId: "call1")]
            let prepared = try c.prepare(next)
            let o = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(codec.prepareRequest(prepared.request, stream: true).httpBody)) as? [String: Any])
            XCTAssertEqual(o["instructions"] as? String, "safety instructions"); XCTAssertEqual(o["store"] as? Bool, policy == .responseChain)
            let input = try XCTUnwrap(o["input"] as? [[String: Any]])
            if policy == .responseChain { XCTAssertEqual(o["previous_response_id"] as? String, "resp1"); XCTAssertEqual(input.count, 1); XCTAssertEqual(input.first?["type"] as? String, "function_call_output") }
            else { XCTAssertNil(o["previous_response_id"]); XCTAssertEqual(input.map { $0["type"] as? String }, ["message", "reasoning", "function_call", "function_call_output"]) }
        }
    }
    func testContinuationRejectsDifferentAccountEndpointModelAndStorage() throws {
        let s = scope, codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: s)
        for wrong in [ProviderScope(provider: s.provider, endpoint: s.endpoint, account: "other", model: s.model, run: s.run, branch: s.branch), ProviderScope(provider: s.provider, endpoint: "https://else.invalid/v1", account: s.account, model: s.model, run: s.run, branch: s.branch), ProviderScope(provider: s.provider, endpoint: s.endpoint, account: s.account, model: "different", run: s.run, branch: s.branch)] {
            var r = request; r.storage = .responseChain; r.context = .previousResponse(.init("resp1", scope: wrong)); XCTAssertThrowsError(try codec.prepareRequest(r, stream: false))
        }
        var r = request; r.context = .previousResponse(.init("resp1", scope: s)); XCTAssertThrowsError(try codec.prepareRequest(r, stream: false))
        r.context = .conversation("conv"); XCTAssertThrowsError(try codec.prepareRequest(r, stream: false))
        r.context = .stateless; r.execution = .background; XCTAssertThrowsError(try codec.prepareRequest(r, stream: false))
        let response = try codec.parseResponse(json(envelope([reasoning, message(), call()])), request: request)
        let wrong = ProviderScope(provider: s.provider, endpoint: s.endpoint, account: "different", model: s.model, run: s.run, branch: s.branch)
        for item in response.output { XCTAssertThrowsError(try item.asReplayInput(scope: wrong)) }
    }
    func testInterleavedToolArgumentsRemainBufferedAndDoneCorrectsPreview() throws {
        let output = [call(), call("call2", item: "fc2")]
        let codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: scope)
        var r = ResponsesReducer(codec: codec, request: request)
        _ = try r.consume(payload: event("response.created", seq: 0, fields: ["response": ["id": "resp1"]]))
        for i in 0..<2 { _ = try r.consume(payload: event("response.output_item.added", seq: 1 + i, fields: ["output_index": i, "item": output[i]])) }
        for i in [1, 0] {
            let address: [String: Any] = ["output_index": i, "item_id": "fc\(i+1)", "delta": "{\"x\":999"]
            XCTAssertFalse(try r.consume(payload: event("response.function_call_arguments.delta", seq: 3 + (1-i), fields: address)).contains { if case .toolCall = $0 { return true }; return false })
        }
        for i in 0..<2 {
            _ = try r.consume(payload: event("response.function_call_arguments.done", seq: 5 + 2*i, fields: ["output_index": i, "item_id": "fc\(i+1)", "arguments": "{\"x\":1}"]))
            _ = try r.consume(payload: event("response.output_item.done", seq: 6 + 2*i, fields: ["output_index": i, "item": output[i]]))
        }
        let events = try r.consume(payload: event("response.completed", seq: 9, fields: ["response": envelope(output)]))
        XCTAssertEqual(events.count, 1); XCTAssertEqual(try r.finish().toolCalls.map(\.arguments), ["{\"x\":1}", "{\"x\":1}"])
    }
    func testDoneCorrectsTextAndStreamMatchesCompleteSnapshotWithoutUsageDuplication() throws {
        let output = [message("corrected")], codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: scope)
        var r = ResponsesReducer(codec: codec, request: request)
        _ = try r.consume(payload: event("response.created", seq: 0, fields: ["response": ["id": "resp1"]]))
        _ = try r.consume(payload: event("response.output_item.added", seq: 1, fields: ["output_index": 0, "item": output[0]]))
        let delta = try event("response.output_text.delta", seq: 2, fields: ["output_index": 0, "item_id": "msg", "content_index": 0, "delta": "preview"])
        XCTAssertEqual(try r.consume(payload: delta).count, 2); XCTAssertTrue(try r.consume(payload: delta).isEmpty)
        _ = try r.consume(payload: event("response.output_text.done", seq: 3, fields: ["output_index": 0, "item_id": "msg", "content_index": 0, "text": "corrected"]))
        _ = try r.consume(payload: event("response.output_item.done", seq: 4, fields: ["output_index": 0, "item": output[0]]))
        let terminal = try event("response.completed", seq: 5, fields: ["response": envelope(output)])
        _ = try r.consume(payload: terminal); XCTAssertTrue(try r.consume(payload: terminal).isEmpty)
        let complete = try codec.parseResponse(json(envelope(output)), request: request), streamed = try r.finish()
        XCTAssertEqual(streamed.output, complete.output); XCTAssertEqual(streamed.text, "corrected"); XCTAssertEqual(streamed.usage, complete.usage)
        XCTAssertThrowsError(try r.consume(payload: event("response.completed", seq: 5, fields: ["response": envelope([message("changed")])])) )
    }
    func testEOFItemDoneHTTP200AndAllNonSuccessTerminalsNeverAuthorizeTools() throws {
        var r = try reducer([call()]); XCTAssertThrowsError(try r.finish())
        let _ = r.checkpoint
        for status in ["incomplete", "failed", "cancelled"] {
            r = try reducer([call()])
            _ = try r.consume(payload: event("response." + status, seq: 3, fields: ["response": envelope([call()], status: status)]))
            let response = try r.finish(); XCTAssertEqual(response.status.rawValue, status); XCTAssertThrowsError(try ResponsesReducer.requireExecutable(response))
        }
        let codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: scope)
        let unknown = try codec.parseResponse(json(envelope([], status: "future_status")), request: request)
        XCTAssertEqual(unknown.status, .unknown); XCTAssertThrowsError(try ResponsesReducer.requireExecutable(unknown))
    }
    func testUnknownCriticalEventsScopeConflictsAndMalformedOrDuplicateCallsFailClosed() throws {
        var r = try reducer([])
        XCTAssertTrue(try r.consume(payload: "{\"type\":\"vendor.metrics.latency\"}").isEmpty)
        XCTAssertThrowsError(try r.consume(payload: event("response.computer_call.executing", seq: 1)))
        r = try reducer([]); XCTAssertThrowsError(try r.consume(payload: event("response.completed", seq: 1, fields: ["response": envelope([], id: "different")])) )
        let codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: scope)
        for outputs in [[call(), call(item: "fc2")], [call(args: "{")], [call("", item: "fc")]] { XCTAssertThrowsError(try codec.parseResponse(json(envelope(outputs)), request: request)) }
        let response = try codec.parseResponse(json(envelope([["type": "future_call", "id": "unknown", "secret": "opaque"]])), request: request)
        XCTAssertThrowsError(try ResponsesReducer.requireExecutable(response)); XCTAssertThrowsError(try response.output[0].asReplayInput(scope: scope))
    }
    func testSSEMultilineCRLFSplitUTF8AndTruncationLimits() throws {
        var decoder = SSEFrameDecoder(), frames: [String] = []
        let value = ": heartbeat\r\nevent: fixture\r\ndata: {\"text\":\r\ndata: \"你好\"}\r\n\r\n"
        for byte in value.utf8 { if let frame = try decoder.consume(byte) { frames.append(frame) } }
        try decoder.finish(); XCTAssertEqual(frames, ["{\"text\":\n\"你好\"}"])
        _ = try decoder.consume(0xE4); XCTAssertThrowsError(try decoder.finish())
        var limited = SSEFrameDecoder(); XCTAssertThrowsError(try (0...256*1024).forEach { _ in _ = try limited.consume(65) })
    }
    func testDurableCommitCASCancelFenceAndFailedGenerationKeepOldHead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), file = root.appendingPathComponent("context.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let s = scope, c = try ContextCoordinator(scope: s, storage: .responseChain, checkpointFile: file)
        let codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: s), prepared = try c.prepare(request)
        let response = try codec.parseResponse(json(envelope([call()])), request: prepared.request)
        try c.commit(response, prepared: prepared); XCTAssertThrowsError(try c.commit(response, prepared: prepared))
        XCTAssertEqual(c.snapshot().revision, 1)
        let restored = try ContextCoordinator(scope: s, storage: .responseChain, checkpointFile: file)
        XCTAssertEqual(restored.snapshot().head?.value, "resp1")
        try c.cancel(); XCTAssertThrowsError(try c.commit(response, prepared: prepared)); XCTAssertThrowsError(try c.prepare(request))
        XCTAssertThrowsError(try ContextCoordinator(scope: s, storage: .responseChain, checkpointFile: file))
        XCTAssertEqual(c.snapshot().pendingCalls.map(\.id), ["call1"])
    }
    func testNativeResponseNeverInfersToolsFromAnswerText() throws {
        let codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: scope)
        let response = try codec.parseResponse(json(envelope([message("TOOL_CALL: tap {\"x\":1}")])), request: request)
        XCTAssertFalse(AgentLLMResponse.from(response).hasToolCalls)
    }
    func testScreenshotPruningKeepsToolResultPairsAndUserAttachment() throws {
        let c = try ContextCoordinator(scope: scope)
        var r = request; r.messages += [.user("attachment", images: [.init(data: Data([1]))]), .assistant(content: "", toolCalls: [.init(id: "old", name: "screenshot", arguments: "{}")]), .init(role: .tool, content: "old receipt", images: [.init(data: Data([2]))], toolCallId: "old"), .assistant(content: "", toolCalls: [.init(id: "new", name: "screenshot", arguments: "{}")]), .init(role: .tool, content: "new receipt", images: [.init(data: Data([3]))], toolCallId: "new")]
        let prepared = try c.prepare(r), codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: c.scope)
        let body = String(decoding: try XCTUnwrap(codec.prepareRequest(prepared.request, stream: false).httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("AQ==")); XCTAssertFalse(body.contains("Ag==")); XCTAssertTrue(body.contains("Aw==")); XCTAssertTrue(body.contains("old receipt")); XCTAssertTrue(body.contains("new receipt"))
    }
    func testHundredScreenshotRoundsKeepOnlyLatestDeviceImageAndAllReceipts() throws {
        let c = try ContextCoordinator(scope: scope), codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: scope)
        var r = request
        r.messages.append(.user("user attachment", images: [.init(data: Data(repeating: 1, count: 1024))]))
        for i in 0..<100 {
            // Match App.afterTool: observation pruning must not invalidate the
            // committed message-prefix identity or erase any call/result pair.
            if i > 0 { let newest = r.messages.lastIndex { $0.role == .tool }; for j in r.messages.indices where r.messages[j].role == .tool && j != newest { r.messages[j].images = [] } }
            let prepared = try c.prepare(r), id = "call-\(i)"
            let response = try codec.parseResponse(json(envelope([call(id, item: "item-\(i)", name: "screenshot", args: "{}")], id: "r-\(i)")), request: prepared.request)
            try c.commit(response, prepared: prepared)
            r.messages.append(.assistant(content: "", toolCalls: response.toolCalls))
            r.messages.append(.init(role: .tool, content: "receipt-\(i)", images: [.init(data: Data(repeating: 2, count: 4096))], toolCallId: id))
        }
        let prepared = try c.prepare(r), items = try XCTUnwrap(prepared.request.input)
        let bytes = items.reduce(0) { count, item in
            if case .message(_, let content) = item { return count + content.reduce(0) { n, value in if case .image(let image) = value { return n + image.data.count }; return n } }; return count
        }
        XCTAssertEqual(bytes, 5120)
        XCTAssertEqual(items.filter { if case .functionResult = $0 { return true }; return false }.count, 100)
    }
    func testStreamCheckpointIsSeparateAndScopedWhileFailedTerminalLeavesHeadUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), file = root.appendingPathComponent("run.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try ContextCoordinator(scope: scope, storage: .responseChain, checkpointFile: file)
        var r = try reducer([reasoning, call()])
        try c.recordStream(r.checkpoint, force: true)
        let saved = try JSONDecoder().decode(StreamCheckpoint.self, from: Data(contentsOf: root.appendingPathComponent("run.stream.json")))
        XCTAssertEqual(saved.completedItems.count, 2); XCTAssertEqual(saved.scope, scope); XCTAssertNil(c.snapshot().head)
        _ = try r.consume(payload: event("response.failed", seq: 5, fields: ["response": envelope([reasoning, call()], status: "failed")]))
        let prepared = try c.prepare(request)
        XCTAssertThrowsError(try c.commit(r.finish(), prepared: prepared)); XCTAssertNil(c.snapshot().head)
    }
    @MainActor func testOpenRouterLegacyProfileKeepsChatAndExplicitResponsesIsStatelessOnly() async throws {
        var original = ProviderProfile(name: "router", settings: .init(baseURL: "https://fixture.invalid/proxy/api/v1", model: "vendor/model-id"), keyAccount: "existing-reference")
        original.protocolKind = .openRouter
        let restored = try JSONDecoder().decode(ProviderProfile.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.providerKind, .openRouter); XCTAssertEqual(restored.inferenceAPI, .chatCompletions)
        XCTAssertEqual(restored.keyAccount, "existing-reference"); XCTAssertEqual(restored.settings, original.settings)
        let chat = try PrivateVisionProvider(settings: restored.settings, apiKey: "synthetic", limits: .init(), providerKind: .openRouter)
        let chatRequest = try chat.prepareRequest(.init(model: original.settings.model, messages: [.user("hello")]), stream: false)
        XCTAssertEqual(chatRequest.url?.path, "/proxy/api/v1/chat/completions"); XCTAssertEqual(chatRequest.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
        var native = restored; native.inferenceKind = .responses
        XCTAssertNoThrow(try native.requireInference(model: original.settings.model))
        let router = try PrivateVisionProvider(settings: original.settings, apiKey: "synthetic", limits: .init(), providerKind: .openRouter, inferenceAPI: .responses)
        let outgoing = try router.prepareRequest(.init(model: original.settings.model, messages: [.user("hello")]), stream: false)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(outgoing.httpBody)) as? [String: Any])
        XCTAssertEqual(outgoing.url?.path, "/proxy/api/v1/responses"); XCTAssertEqual(body["store"] as? Bool, false); XCTAssertNil(body["previous_response_id"])
        let capabilities = try await router.capabilities(for: original.settings.model); XCTAssertFalse(capabilities.responseChain)
        native.contextKind = .responseChain
        XCTAssertThrowsError(try native.requireInference(model: original.settings.model)); XCTAssertThrowsError(try ProviderStore(defaults: nil).prepared(native))
        XCTAssertThrowsError(try PrivateVisionProvider(settings: original.settings, apiKey: "synthetic", limits: .init(), providerKind: .openRouter, inferenceAPI: .responses, contextPolicy: .responseChain))
        let codec = OpenAIWireCodec(configuration: configuration, wire: .responses, scope: scope, capabilities: .init(responseChain: false))
        var prohibited = request; prohibited.storage = .responseChain; XCTAssertThrowsError(try codec.prepareRequest(prohibited, stream: false))
        prohibited.storage = .none; prohibited.context = .previousResponse(.init("old", scope: scope)); XCTAssertThrowsError(try codec.prepareRequest(prohibited, stream: false))
        native.contextKind = .stateless; native.catalog = .init(endpoint: try native.catalogEndpoint(), fetchedAt: Date(), models: [.init(id: original.settings.model, name: "unsupported", vision: .unsupported)])
        XCTAssertThrowsError(try native.requireInference(model: original.settings.model))
    }
    func testOpenRouterChatOpaqueReasoningRoundTripNeverProjectsSignaturesToUI() throws {
        let provider = try PrivateVisionProvider(settings: .init(baseURL: "https://fixture.invalid/api/v1", model: "fixture"), apiKey: "synthetic", limits: .init(), providerKind: .openRouter)
        let blocks: [[String: Any]] = [["type": "reasoning.text", "text": "visible", "signature": "OPAQUE_SIGNATURE", "index": 0], ["type": "reasoning.encrypted", "data": "OPAQUE_ENCRYPTED", "index": 1, "vendor_extra": "retain"]]
        let data = try json(["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": "answer", "reasoning_details": blocks, "tool_calls": [["id": "call1", "type": "function", "function": ["name": "tap", "arguments": "{}"]]]]]]])
        let response = try provider.parseResponse(data, request: request), agent = AgentLLMResponse.from(response)
        XCTAssertFalse((agent.reasoning ?? "").contains("OPAQUE")); XCTAssertFalse(agent.text.contains("OPAQUE"))
        let message = AgentMessage.assistant(content: agent.text, toolCalls: try XCTUnwrap(agent.toolCalls), replayState: agent.replayState)
        var next = request; next.messages += message.toModelMessages() + [.tool("executed", toolCallId: "call1")]
        let body = try XCTUnwrap(provider.prepareRequest(next, stream: false).httpBody)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any]); let messages = try XCTUnwrap(envelope["messages"] as? [[String: Any]])
        let replay = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" }?["reasoning_details"])
        XCTAssertEqual(try ProviderCore.JSONValue(any: replay), try ProviderCore.JSONValue(any: blocks))
        let other = try PrivateVisionProvider(settings: .init(baseURL: "https://fixture.invalid/api/v1", model: "fixture"), apiKey: "synthetic", limits: .init(), providerKind: .openRouter)
        XCTAssertThrowsError(try other.prepareRequest(next, stream: false))
    }
    func testOpenRouterStreamOrderedReasoningAndRepeatedUsageFinishProduceOneBatch() throws {
        var decoder = ModelStreamDecoder()
        let blocks: [[String: Any]] = [["type": "reasoning.text", "text": "visible", "signature": NSNull(), "index": 0], ["type": "reasoning.text", "text": " continuation", "signature": "OPAQUE_SIGNATURE", "index": 0], ["type": "reasoning.encrypted", "data": "OPAQUE_ENCRYPTED", "index": 1]]
        for block in blocks {
            let data = try json(["choices": [["delta": ["reasoning_details": [block]]]]])
            _ = try decoder.consume(line: "data: " + String(decoding: data, as: UTF8.self), request: request)
        }
        let call = try json(["choices": [["delta": ["content": "answer", "tool_calls": [["index": 0, "id": "call1", "function": ["name": "tap", "arguments": "{}"]]]], "finish_reason": "tool_calls"]]])
        _ = try decoder.consume(line: "data: " + String(decoding: call, as: UTF8.self), request: request)
        let usage = try json(["choices": [["delta": ["content": "", "role": "assistant"], "finish_reason": "tool_calls", "native_finish_reason": "tool_calls"]], "usage": ["prompt_tokens": 12, "completion_tokens": 5, "total_tokens": 17]])
        for _ in 0..<2 { XCTAssertTrue(try decoder.consume(line: "data: " + String(decoding: usage, as: UTF8.self), request: request).isEmpty) }
        let response = try decoder.finalResponse(request: request, providerName: "fixture", scope: scope)
        XCTAssertEqual(response.toolCalls.map(\.id), ["call1"]); XCTAssertEqual(response.usage?.totalTokens, 17)
        XCTAssertEqual(try response.replayState?.reasoningDetailsForReplay(scope: scope), try blocks.map { try ProviderCore.JSONValue(any: $0) })
        XCTAssertFalse((response.reasoning ?? "").contains("OPAQUE"))
    }
    @MainActor func testExistingSettingsMigrationPreservesEndpointAccountAndDefaults() throws {
        let original = ProviderProfile(name: "legacy", settings: .init(baseURL: "https://example.invalid/prefix/v1", model: "fixture"), keyAccount: "old-reference")
        var o = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]); o.removeValue(forKey: "inferenceKind"); o.removeValue(forKey: "contextKind")
        let legacy = try JSONDecoder().decode(ProviderProfile.self, from: json(o))
        XCTAssertEqual(legacy.inferenceAPI, .chatCompletions); XCTAssertEqual(legacy.contextPolicy, .stateless); XCTAssertEqual(legacy.keyAccount, "old-reference"); XCTAssertEqual(legacy.settings, original.settings)
    }
}
