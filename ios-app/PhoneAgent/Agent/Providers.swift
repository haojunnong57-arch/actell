import Foundation
import LLMProviderKit
import LLMProviderKitOpenAI

// No cookies, disk cache, raw response logging, HTTP redirects, or retries.
// Only public output, validated tools and explicit readable reasoning pass through.
final class PrivateVisionProvider: LLMProvider, @unchecked Sendable {
    static let name = "private-openai-compatible"
    let configuration: LLMProviderConfiguration
    let urlSession: URLSession
    private let encoder: OpenAIProvider
    private let redirectGuard: NoRedirectDelegate
    private let protocolType: ProviderProtocol
    private let parameterFields: [String: Any]
    init(settings: ProviderSettings, apiKey: String, limits: AgentLimits,
         protocolType: ProviderProtocol = .openAI, parameters: ModelParameters = ModelParameters(), metadata: DiscoveredModel? = nil) throws {
        let endpoint = try protocolType.inferenceBase(settings.baseURL)
        guard !settings.model.isEmpty else { throw AppError.invalid("请先选择模型") }
        guard !apiKey.isEmpty || protocolType == .ollama else { throw AppError.invalid("请先设置模型 API 密钥") }
        self.protocolType = protocolType
        self.parameterFields = try parameters.requestFields(protocolType: protocolType, model: metadata)
        let config = LLMProviderConfiguration(name: Self.name, baseURL: endpoint, apiKey: apiKey, defaultModel: settings.model)
        configuration = config
        encoder = OpenAIProvider(configuration: config)
        let delegate = NoRedirectDelegate(); redirectGuard = delegate
        let session = URLSessionConfiguration.ephemeral
        session.urlCache = nil; session.httpCookieStorage = nil
        urlSession = URLSession(configuration: session, delegate: delegate, delegateQueue: nil)
    }
    func cancel() { urlSession.invalidateAndCancel() }
    func prepareRequest(_ request: LLMRequest, stream: Bool) throws -> URLRequest {
        var trimmed = request
        trimmed.temperature = nil; trimmed.topP = nil; trimmed.maxTokens = nil
        // Explicit user attachments remain throughout this run. Device images
        // keep only the latest observation; old screenshots do not accumulate.
        let last = request.messages.lastIndex(where: { $0.role != .user && !$0.images.isEmpty })
        trimmed.messages = request.messages.enumerated().map { index, original in
            var message = original
            if message.role != .user && index != last { message.images = [] }
            return message
        }
        var result = try encoder.prepareRequest(trimmed, stream: stream)
        // Permit multiple returned calls. Agent dispatch stays strictly sequential.
        if let body = result.httpBody, var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            // This wire option enables a batch; it does not schedule device concurrency.
            if protocolType != .ollama { object["parallel_tool_calls"] = true }
            for (key, value) in parameterFields { object[key] = value }
            result.httpBody = try JSONSerialization.data(withJSONObject: object)
        }
        if configuration.apiKey?.isEmpty == true { result.setValue(nil, forHTTPHeaderField: "Authorization") }
        return result
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let (bytes, response) = try await urlSession.bytes(for: prepareRequest(request, stream: true))
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw AppError.unavailable("模型服务返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)；请检查配置与余额")
                    }
                    var decoder = ModelStreamDecoder()
                    var line = Data(), total = 0
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        total += 1
                        guard total <= 4 * 1_024 * 1_024, line.count <= 256 * 1_024 else { throw AppError.invalid("模型流超过大小限制") }
                        if byte == 10 {
                            guard let value = String(data: line, encoding: .utf8) else { throw AppError.invalid("模型流不是有效 UTF-8") }
                            for chunk in try decoder.consume(line: value, request: request, encoder: encoder) { continuation.yield(chunk) }
                            line.removeAll(keepingCapacity: true)
                            if decoder.sawDone { break }
                        } else { line.append(byte) }
                    }
                    if !line.isEmpty {
                        guard let value = String(data: line, encoding: .utf8) else { throw AppError.invalid("模型流被截断") }
                        for chunk in try decoder.consume(line: value, request: request, encoder: encoder) { continuation.yield(chunk) }
                    }
                    let final = try decoder.finish(previousCallIDs: Set(request.messages.flatMap { $0.toolCalls ?? [] }.map(\.id)))
                    for chunk in final { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError { continuation.finish(throwing: CancellationError()) }
                    else { continuation.finish(throwing: LLMError.invalidRequest((error as? AppError)?.localizedDescription ?? "模型流中断或格式不兼容；没有自动重试")) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        do { return try await completeOnce(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as AppError {
            // SwiftAgentKit retries unknown/invalid-response errors. Map our
            // explicit fail-closed boundary to its permanent-error category.
            throw LLMError.invalidRequest(error.localizedDescription)
        } catch {
            throw LLMError.invalidRequest("模型调用中断；没有自动重试")
        }
    }
    private func completeOnce(_ request: LLMRequest) async throws -> LLMResponse {
        try Task.checkCancellation()
        let urlRequest = try prepareRequest(request, stream: false)
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await urlSession.bytes(for: urlRequest) }
        catch { try Task.checkCancellation(); throw AppError.unavailable("模型网络请求失败或超时；没有自动重试") }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AppError.unavailable("模型服务返回 HTTP \(code)；请检查地址、模型、余额和权限")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4 * 1_024 * 1_024 else { throw AppError.invalid("模型响应超过 4 MiB 限制") }
            data.append(byte)
        }
        return try parseResponse(data, request: request)
    }
    func parseResponse(_ data: Data, request: LLMRequest) throws -> LLMResponse {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var choices = object["choices"] as? [[String: Any]], !choices.isEmpty,
              let message = choices[0]["message"] as? [String: Any] else {
            throw AppError.invalid("模型响应格式与 Chat Completions 协议不兼容")
        }
        choices[0]["message"] = ReadableReasoningDecoder.removingFields(from: message)
        object["choices"] = choices
        let parsed: LLMResponse
        do { parsed = try encoder.parseResponse(JSONSerialization.data(withJSONObject: object), request: request) }
        catch { throw AppError.invalid("模型响应格式与 Chat Completions 协议不兼容") }
        let wireCalls = message["tool_calls"] as? [[String: Any]] ?? []
        guard wireCalls.compactMap({ $0["id"] as? String }) == parsed.toolCalls.map(\.id) else {
            throw AppError.invalid("模型工具调用缺少原始 ID；本批未执行")
        }
        try ModelStreamDecoder.validate(parsed.toolCalls, previousCallIDs: Set(request.messages.flatMap { $0.toolCalls ?? [] }.map(\.id)))
        return LLMResponse(text: parsed.text, reasoning: ReadableReasoningDecoder.text(in: message), finishReason: parsed.finishReason, usage: parsed.usage, toolCalls: parsed.toolCalls, request: request, providerName: Self.name)
    }
}
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
// Deterministic in-process test provider. It does not make HTTP requests and
// only controls DemoBridge's synthetic image. Never presents itself as a model.
struct DemoProvider: LLMProvider {
    static let name = "offline-scripted-demo"
    let configuration = LLMProviderConfiguration(name: Self.name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "demo")
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
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
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        try Task.checkCancellation(); try await Task.sleep(nanoseconds: 350_000_000)
        let calls = request.messages.flatMap { $0.toolCalls ?? [] }
        let stage = calls.count
        if stage >= 3, !request.tools.contains(where: { $0.name == "finish" }) {
            return LLMResponse(text: "合成测试已完成。", finishReason: .stop, request: request, providerName: Self.name)
        }
        let call: LLMToolCall
        switch stage {
        case 0: call = LLMToolCall(name: "screenshot", arguments: "{}")
        case 1:
            let arguments: [String: Any] = ["x": 195, "y": 380, "purpose": "点击合成画面的演示计数器"]
            call = LLMToolCall(name: "tap", arguments: String(data: try JSONSerialization.data(withJSONObject: arguments), encoding: .utf8)!)
        case 2: call = LLMToolCall(name: "screenshot", arguments: "{}")
        default: call = LLMToolCall(name: "finish", arguments: "{\"summary\":\"离线演示完成：已确认一次合成点击并刷新合成截图。没有连接或控制真实设备。\"}")
        }
        let narration = ["这是离线脚本演示。我会先查看合成屏幕。", "接下来演示一次点击，请确认工具卡片中的动作。", "点击已返回。现在获取新的合成截图检查结果。", "演示流程已结束。没有连接模型或控制真实设备。"]
        return LLMResponse(text: narration[min(stage, 3)], finishReason: .toolCalls, toolCalls: [call], request: request, providerName: Self.name)
    }
}

#if DEBUG
/// Public synthetic fixture only; never imitates a remote model's private state.
struct ReasoningFixtureProvider: LLMProvider {
    static let name = "synthetic-readable-reasoning"
    static let first = "合成思考第一段。"
    static let second = "合成思考第二段。"
    let configuration = LLMProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    var outcome = "completed"
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: "合成答复。", reasoning: Self.first + Self.second, finishReason: .stop, request: request, providerName: Self.name)
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.reasoning(Self.first))
                    try await Task.sleep(for: .milliseconds(150))
                    continuation.yield(.reasoning(Self.second))
                    if outcome == "paused" { try await Task.sleep(for: .seconds(60)) }
                    if outcome == "failed" { throw LLMError.invalidRequest("合成服务中断") }
                    continuation.yield(.text("合成答复。"))
                    continuation.yield(.finish(reason: .stop, usage: nil)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
struct SkillFixtureProvider: LLMProvider {
    static let name = "offline-skill-fixture"
    let configuration = LLMProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            do {
                let response = try response(request)
                for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                continuation.yield(.finish(reason: response.finishReason, usage: nil)); continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
    func complete(_ request: LLMRequest) async throws -> LLMResponse { try response(request) }
    private func response(_ request: LLMRequest) throws -> LLMResponse {
        let results = request.messages.filter { $0.role == .tool }
        let call: LLMToolCall
        if results.isEmpty { call = .init(id: "fixture-skill-list", name: "list_skills", arguments: "{}") }
        else if results.count == 1 {
            guard let start = results[0].content.firstIndex(of: "{"),
                  let object = try JSONSerialization.jsonObject(with: Data(results[0].content[start...].utf8)) as? [String: Any],
                  let skill = (object["skills"] as? [[String: String]])?.first,
                  let id = skill["id"], let revision = skill["revision"] else { throw AppError.invalid("合成夹具未找到已启用技能") }
            call = .init(id: "fixture-skill-load", name: "load_skill", arguments: String(decoding: try JSONEncoder().encode(["id": id, "revision": revision]), as: UTF8.self))
        } else {
            guard results.last?.content.contains("SYNTHETIC_SKILL_BODY") == true else { throw AppError.invalid("合成夹具没有收到技能正文") }
            return LLMResponse(text: "合成技能已读取。", finishReason: .stop, request: request, providerName: Self.name)
        }
        return LLMResponse(text: "", finishReason: .toolCalls, toolCalls: [call], request: request, providerName: Self.name)
    }
}
// Deterministic fixture for the real Agent loop, with no network or credentials.
// Its second turn only answers if the failed tool result actually reaches it.
struct ToolErrorFixtureProvider: LLMProvider {
    static let name = "offline-tool-error-fixture"
    static let reply = "当前尚未授权全屏采集。请先授权 App 采集，再试一次；查看屏幕无需连接 ESP32。"
    var initialText = ""
    var finalReply = Self.reply
    let configuration = LLMProviderConfiguration(name: Self.name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
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
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        try Task.checkCancellation()
        if request.messages.contains(where: { $0.role == .tool }) {
            guard request.messages.contains(where: {
                $0.role == .tool && $0.toolCallId == "fixture-screenshot" &&
                $0.content == "[Tool: screenshot] ERROR\n" + UnavailableBridge.screenshotMessage
            }) else { throw AppError.invalid("测试未收到对应工具的完整失败结果") }
            return LLMResponse(text: finalReply, finishReason: .stop, request: request, providerName: Self.name)
        }
        return LLMResponse(text: initialText, finishReason: .toolCalls,
            toolCalls: [LLMToolCall(id: "fixture-screenshot", name: "screenshot", arguments: "{}")], request: request, providerName: Self.name)
    }
}
#endif

#if DEBUG
/// Finite, offline real-run fixture. It never requests device input.
struct TaskPiPProbeProvider: LLMProvider {
    static let name = "task-pip-probe"
    let configuration = DemoProvider().configuration
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        try await Task.sleep(for: .seconds(30))
        return LLMResponse(text: "后台状态验收已结束", finishReason: .stop, request: request, providerName: "task-pip-probe")
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
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
