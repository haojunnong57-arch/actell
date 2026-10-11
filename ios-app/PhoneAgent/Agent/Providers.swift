import Foundation
import ProviderCore
import OpenAIAdapter

/// Runtime owns continuation state; the SDK adapter only encodes/decodes each call.
final class PrivateVisionProvider: ModelProvider, @unchecked Sendable {
    static let name = "private-openai-compatible"
    let configuration: ProviderConfiguration
    private let codec: OpenAIWireCodec
    private let transport: ResponsesTransport
    private let context: ContextCoordinator?
    private let providerKind: ProviderKind
    private let parameterFields: [String: Any]
    init(settings: ProviderSettings, apiKey: String, limits: AgentLimits,
         providerKind: ProviderKind = .openAI, parameters: ModelParameters = ModelParameters(), metadata: DiscoveredModel? = nil,
         inferenceAPI: InferenceAPI = .chatCompletions, contextPolicy: ProviderContextPolicy = .stateless, accountReference: String = "",
         runID: UUID = UUID(), branchID: UUID = UUID(), checkpointFile: URL? = nil, transport: ResponsesTransport? = nil) throws {
        let endpoint = try providerKind.inferenceBase(settings.baseURL)
        guard !settings.model.isEmpty else { throw AppError.invalid("请先选择模型") }
        guard !apiKey.isEmpty || providerKind == .ollama else { throw AppError.invalid("请先设置模型 API 密钥") }
        guard inferenceAPI == .chatCompletions || providerKind.supportsResponses else { throw AppError.invalid("此供应商协议尚未验证 Responses 推理") }
        guard inferenceAPI == .responses || contextPolicy == .stateless else { throw AppError.invalid("历史续接仅支持 Responses") }
        guard contextPolicy == .stateless || providerKind.supportsResponseChain else { throw AppError.invalid("此供应商 Responses 仅支持无状态请求") }
        self.providerKind = providerKind
        var fields = try parameters.requestFields(providerKind: providerKind, model: metadata)
        if inferenceAPI == .responses {
            guard fields["seed"] == nil else { throw AppError.invalid("Responses 尚未支持 seed 参数，请清空后保存") }
            if let n = fields.removeValue(forKey: "max_tokens") ?? fields.removeValue(forKey: "max_completion_tokens") { fields["max_output_tokens"] = n }
        }
        parameterFields = fields
        configuration = ProviderConfiguration(name: Self.name, baseURL: endpoint, apiKey: apiKey, defaultModel: settings.model)
        let scope = ProviderScope(provider: providerKind.rawValue + ":" + Self.name, endpoint: endpoint.absoluteString, account: accountReference, model: settings.model, run: runID, branch: branchID)
        codec = OpenAIWireCodec(configuration: configuration, wire: inferenceAPI == .responses ? .responses : .chatCompletions, scope: scope, capabilities: .init(responseChain: providerKind.supportsResponseChain))
        self.transport = transport ?? ResponsesTransport()
        context = inferenceAPI == .responses ? try ContextCoordinator(scope: scope, storage: contextPolicy == .responseChain ? .responseChain : .none, checkpointFile: checkpointFile) : nil
    }
    func capabilities(for model: String) async throws -> ProviderCapabilities {
        guard model == configuration.defaultModel else { throw ModelError.unsupportedCapability("模型能力尚未核对") }
        return .init(responseChain: codec.wire == .responses && providerKind.supportsResponseChain)
    }
    func cancel() {
        // A persistence failure still cancels transport; the App's durable action
        // journal independently fences dispatch and forbids restart replay.
        try? context?.cancel()
        transport.cancel()
    }
    func prepareRequest(_ request: ModelRequest, stream: Bool) throws -> URLRequest {
        let actual = try context?.prepare(request).request ?? request
        return try wireRequest(actual, stream: stream)
    }
    private func wireRequest(_ request: ModelRequest, stream: Bool) throws -> URLRequest {
        var explicit = request
        explicit.temperature = nil; explicit.topP = nil; explicit.maxTokens = nil
        var value = try codec.prepareRequest(explicit, stream: stream)
        if let data = value.httpBody, var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if providerKind == .ollama { object.removeValue(forKey: "parallel_tool_calls") }
            for (key, field) in parameterFields { object[key] = field }
            value.httpBody = try JSONSerialization.data(withJSONObject: object)
            guard (value.httpBody?.count ?? 0) <= 24 * 1024 * 1024 else { throw AppError.invalid("模型请求超过 24 MiB 限制") }
        }
        return value
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let prepared = try context?.prepare(request)
                    let actual = prepared?.request ?? request
                    let outgoing = try wireRequest(actual, stream: true)
                    if codec.wire == .responses {
                        var reducer = ResponsesReducer(codec: codec, request: actual)
                        for try await payload in transport.payloads(outgoing) {
                            try Task.checkCancellation()
                            let events: [ModelEvent]
                            do { events = try reducer.consume(payload: payload); try context?.recordStream(reducer.checkpoint) }
                            catch { try? context?.recordStream(reducer.checkpoint, force: true); throw error }
                            for event in events {
                                if case .terminal(let response) = event {
                                    try ResponsesReducer.requireExecutable(response)
                                    try Task.checkCancellation()
                                    if let prepared { try context?.commit(response, prepared: prepared) }
                                }
                                if case .dropped = continuation.yield(event) { throw ModelError.protocolViolation("模型输出缓冲超过限制") }
                            }
                            if reducer.response != nil { break }
                        }
                        try context?.recordStream(reducer.checkpoint, force: true)
                        _ = try reducer.finish()
                    } else {
                        var decoder = ModelStreamDecoder()
                        for try await payload in transport.payloads(outgoing) {
                            try Task.checkCancellation()
                            for event in try decoder.consume(line: "data: " + payload, request: request) { continuation.yield(event) }
                            if decoder.sawDone { break }
                        }
                        let terminal = try decoder.finalResponse(request: request, providerName: Self.name, scope: codec.scope)
                        if case .dropped = continuation.yield(.terminal(terminal)) { throw ModelError.protocolViolation("模型输出缓冲超过限制") }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: Self.safeFailure(error)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        do {
            try Task.checkCancellation()
            let prepared = try context?.prepare(request)
            let actual = prepared?.request ?? request
            let data = try await transport.complete(wireRequest(actual, stream: false))
            let result = try parseResponse(data, request: actual)
            if let prepared {
                try ResponsesReducer.requireExecutable(result); try Task.checkCancellation()
                try context?.commit(result, prepared: prepared)
            }
            return result
        } catch { throw Self.safeFailure(error) }
    }
    private static func safeFailure(_ error: Error) -> Error {
        if Task.isCancelled || error is CancellationError { return CancellationError() }
        // Permanent at the runtime boundary: never regenerate an accepted/unknown
        // request automatically. Raw SDK errors may include payloads, so redact them.
        if let e = error as? ModelError { return e }
        if let e = error as? AppError { return ModelError.invalidRequest(e.localizedDescription) }
        return ModelError.interrupted
    }
    func parseResponse(_ data: Data, request: ModelRequest) throws -> ModelResponse {
        guard codec.wire == .chatCompletions else { return try codec.parseResponse(data, request: request) }
        guard var o = try JSONSerialization.jsonObject(with: data) as? [String: Any], var choices = o["choices"] as? [[String: Any]], !choices.isEmpty, let m = choices[0]["message"] as? [String: Any] else { throw AppError.invalid("Chat Completions 响应格式不兼容") }
        choices[0]["message"] = ReadableReasoningDecoder.removingFields(from: m); o["choices"] = choices
        let parsed = try codec.parseResponse(JSONSerialization.data(withJSONObject: o), request: request)
        let details = try (m["reasoning_details"] as? [[String: Any]])?.map { try ProviderCore.JSONValue(any: $0) }
        return ModelResponse(text: parsed.text, reasoning: ReadableReasoningDecoder.text(in: m), finishReason: parsed.finishReason, usage: parsed.usage, toolCalls: parsed.toolCalls, request: request, providerName: Self.name, replayState: details.map { .init(scope: codec.scope, reasoningDetails: $0) })
    }
}
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
// Deterministic in-process test provider. It does not make HTTP requests and
// only controls DemoBridge's synthetic image. Never presents itself as a model.
struct DemoProvider: ModelProvider {
    static let name = "offline-scripted-demo"
    let configuration = ProviderConfiguration(name: Self.name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "demo")
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    // One honest scripted message, not a simulated token stream.
                    if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                    for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.yield(.finish(reason: response.finishReason, usage: nil))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        try Task.checkCancellation(); try await Task.sleep(nanoseconds: 350_000_000)
        let calls = request.messages.flatMap { $0.toolCalls ?? [] }
        let stage = calls.count
        if stage >= 3, !request.tools.contains(where: { $0.name == "finish" }) {
            return ModelResponse(text: "合成测试已完成。", finishReason: .stop, request: request, providerName: Self.name)
        }
        let call: ModelToolCall
        switch stage {
        case 0: call = ModelToolCall(name: "screenshot", arguments: "{}")
        case 1:
            let arguments: [String: Any] = ["x": 195, "y": 380, "purpose": "点击合成画面的演示计数器"]
            call = ModelToolCall(name: "tap", arguments: String(data: try JSONSerialization.data(withJSONObject: arguments), encoding: .utf8)!)
        case 2: call = ModelToolCall(name: "screenshot", arguments: "{}")
        default: call = ModelToolCall(name: "finish", arguments: "{\"summary\":\"离线演示完成：已确认一次合成点击并刷新合成截图。没有连接或控制真实设备。\"}")
        }
        let narration = ["这是离线脚本演示。我会先查看合成屏幕。", "接下来演示一次点击，请确认工具卡片中的动作。", "点击已返回。现在获取新的合成截图检查结果。", "演示流程已结束。没有连接模型或控制真实设备。"]
        return ModelResponse(text: narration[min(stage, 3)], finishReason: .toolCalls, toolCalls: [call], request: request, providerName: Self.name)
    }
}

#if DEBUG
/// Public synthetic fixture only; never imitates a remote model's private state.
struct ReasoningFixtureProvider: ModelProvider {
    static let name = "synthetic-readable-reasoning"
    static let first = "合成思考第一段。"
    static let second = "合成思考第二段。"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    var outcome = "completed"
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        ModelResponse(text: "合成答复。", reasoning: Self.first + Self.second, finishReason: .stop, request: request, providerName: Self.name)
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.reasoning(Self.first))
                    try await Task.sleep(for: .milliseconds(150))
                    continuation.yield(.reasoning(Self.second))
                    if outcome == "paused" { try await Task.sleep(for: .seconds(60)) }
                    if outcome == "failed" { throw ModelError.invalidRequest("合成服务中断") }
                    continuation.yield(.text("合成答复。"))
                    continuation.yield(.finish(reason: .stop, usage: nil)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
struct SkillFixtureProvider: ModelProvider {
    static let name = "offline-skill-fixture"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                let response = try response(request)
                for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                continuation.yield(.finish(reason: response.finishReason, usage: nil)); continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse { try response(request) }
    private func response(_ request: ModelRequest) throws -> ModelResponse {
        let results = request.messages.filter { $0.role == .tool }
        let call: ModelToolCall
        if results.isEmpty {
            let system = request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
            guard let metadata = system.components(separatedBy: "\n").first(where: { $0.hasPrefix("[{") }),
                  let skills = try JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [[String: String]],
                  let skill = skills.first(where: { $0["name"] == "Synthetic Guide" }) ?? skills.first,
                  let id = skill["id"], let revision = skill["revision"] else { throw AppError.invalid("合成夹具未找到已启用技能") }
            call = .init(id: "fixture-skill-load", name: "load_skill", arguments: String(decoding: try JSONEncoder().encode(["id": id, "revision": revision]), as: UTF8.self))
        } else {
            guard results.last?.content.contains("SYNTHETIC_SKILL_BODY") == true else { throw AppError.invalid("合成夹具没有收到技能正文") }
            return ModelResponse(text: "合成技能已读取。", finishReason: .stop, request: request, providerName: Self.name)
        }
        return ModelResponse(text: "", finishReason: .toolCalls, toolCalls: [call], request: request, providerName: Self.name)
    }
}
// Deterministic fixture for the real Agent loop, with no network or credentials.
// Its second turn only answers if the failed tool result actually reaches it.
struct ToolErrorFixtureProvider: ModelProvider {
    static let name = "offline-tool-error-fixture"
    static let reply = "当前尚未授权全屏采集。请先授权 App 采集，再试一次；查看屏幕无需连接 ESP32。"
    var initialText = ""
    var finalReply = Self.reply
    let configuration = ProviderConfiguration(name: Self.name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                    for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.yield(.finish(reason: response.finishReason, usage: nil))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        try Task.checkCancellation()
        if request.messages.contains(where: { $0.role == .tool }) {
            guard request.messages.contains(where: {
                $0.role == .tool && $0.toolCallId == "fixture-screenshot" &&
                $0.content == "[Tool: screenshot] ERROR\n" + UnavailableBridge.screenshotMessage
            }) else { throw AppError.invalid("测试未收到对应工具的完整失败结果") }
            return ModelResponse(text: finalReply, finishReason: .stop, request: request, providerName: Self.name)
        }
        return ModelResponse(text: initialText, finishReason: .toolCalls,
            toolCalls: [ModelToolCall(id: "fixture-screenshot", name: "screenshot", arguments: "{}")], request: request, providerName: Self.name)
    }
}
#endif

#if DEBUG
/// Finite, offline real-run fixture. It never requests device input.
struct TaskPiPProbeProvider: ModelProvider {
    static let name = "task-pip-probe"
    let configuration = DemoProvider().configuration
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        try await Task.sleep(for: .seconds(30))
        return ModelResponse(text: "后台状态验收已结束", finishReason: .stop, request: request, providerName: "task-pip-probe")
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if ProcessInfo.processInfo.arguments.contains("--background-stream-probe") {
                        for _ in 0..<4_500 {
                            try await Task.sleep(for: .milliseconds(20))
                            continuation.yield(.reasoning("离线流式验证。"))
                        }
                        continuation.yield(.text("离线后台流式验证已结束"))
                        continuation.yield(.finish(reason: .stop, usage: nil)); continuation.finish()
                        return
                    }
                    let response = try await complete(request)
                    continuation.yield(.text(response.text))
                    continuation.yield(.finish(reason: .stop, usage: nil)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
