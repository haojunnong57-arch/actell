import Foundation
import LLMProviderKit
import LLMProviderKitOpenAI

// No cookies, disk cache, raw response logging, HTTP redirects, or retries.
// Only public output/tool calls pass through. Separated reasoning is dropped.
final class PrivateVisionProvider: LLMProvider, @unchecked Sendable {
    static let name = "private-openai-compatible"
    let configuration: LLMProviderConfiguration
    let urlSession: URLSession
    private let encoder: OpenAIProvider
    private let redirectGuard: NoRedirectDelegate
    private let meter = RequestMeter()
    private let limits: AgentLimits
    init(settings: ProviderSettings, apiKey: String, limits: AgentLimits) throws {
        let endpoint = try settings.validatedURL()
        guard !apiKey.isEmpty else { throw AppError.invalid("请先设置模型 API 密钥") }
        let config = LLMProviderConfiguration(name: Self.name, baseURL: endpoint, apiKey: apiKey, defaultModel: settings.model)
        configuration = config
        encoder = OpenAIProvider(configuration: config)
        self.limits = limits
        let delegate = NoRedirectDelegate(); redirectGuard = delegate
        let session = URLSessionConfiguration.ephemeral
        session.urlCache = nil; session.httpCookieStorage = nil
        session.timeoutIntervalForRequest = 45; session.timeoutIntervalForResource = 60
        urlSession = URLSession(configuration: session, delegate: delegate, delegateQueue: nil)
    }
    func cancel() { urlSession.invalidateAndCancel() }
    func prepareRequest(_ request: LLMRequest, stream: Bool) throws -> URLRequest {
        var trimmed = request
        // Keep tool result receipts, but send only the latest image. Old PNG
        // data never accumulates in each outbound vision request.
        let last = request.messages.lastIndex(where: { !$0.images.isEmpty })
        trimmed.messages = request.messages.enumerated().map { index, original in
            var message = original
            if index != last { message.images = [] }
            return message
        }
        var result = try encoder.prepareRequest(trimmed, stream: stream)
        // One model decision per turn; reject accidental batches locally too.
        if let body = result.httpBody, var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            object["parallel_tool_calls"] = false
            result.httpBody = try JSONSerialization.data(withJSONObject: object)
        }
        return result
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    try await meter.reserve(limits: limits)
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
                    let final = try decoder.finish()
                    try await meter.account(decoder.usage?.totalTokens, limits: limits)
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
        try await meter.reserve(limits: limits)
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
        let parsed: LLMResponse
        do { parsed = try encoder.parseResponse(data, request: request) }
        catch { throw AppError.invalid("模型响应格式与 Chat Completions 协议不兼容") }
        try await meter.account(parsed.usage?.totalTokens, limits: limits)
        guard parsed.toolCalls.count <= 1 else { throw AppError.invalid("模型一次请求多个动作，已阻止；请选择遵循单工具调用的模型") }
        return LLMResponse(text: parsed.text, finishReason: parsed.finishReason, usage: parsed.usage, toolCalls: parsed.toolCalls, request: request, providerName: Self.name)
    }
}
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
private actor RequestMeter {
    private var calls = 0, reportedTokens = 0
    func reserve(limits: AgentLimits) throws {
        guard calls < limits.maxTurns, reportedTokens < limits.maxReportedTokens else { throw AppError.unavailable("模型调用次数或已报告 token 用量达到上限") }
        calls += 1
    }
    func account(_ tokens: Int?, limits: AgentLimits) throws {
        if let tokens { reportedTokens += max(0, tokens) }
        guard reportedTokens <= limits.maxReportedTokens else { throw AppError.unavailable("模型已报告 token 用量超过上限，停止后续请求；本次请求费用可能已发生") }
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
        let call: LLMToolCall
        switch stage {
        case 0: call = LLMToolCall(name: "screenshot", arguments: "{}")
        case 1:
            guard let id = latestImageID(request) else { throw AppError.invalid("演示截图缺少 ID") }
            let arguments: [String: Any] = ["x": 195, "y": 380, "based_on_image_id": id, "purpose": "点击合成画面的演示计数器"]
            call = LLMToolCall(name: "tap", arguments: String(data: try JSONSerialization.data(withJSONObject: arguments), encoding: .utf8)!)
        case 2: call = LLMToolCall(name: "screenshot", arguments: "{}")
        default: call = LLMToolCall(name: "finish", arguments: "{\"summary\":\"离线演示完成：已确认一次合成点击并刷新合成截图。没有连接或控制真实设备。\"}")
        }
        let narration = ["这是离线脚本演示。我会先查看合成屏幕。", "接下来演示一次点击，请确认工具卡片中的动作。", "点击已返回。现在获取新的合成截图检查结果。", "演示流程已结束。没有连接模型或控制真实设备。"]
        return LLMResponse(text: narration[min(stage, 3)], finishReason: .toolCalls, toolCalls: [call], request: request, providerName: Self.name)
    }
    private func latestImageID(_ request: LLMRequest) -> String? {
        for message in request.messages.reversed() where message.role == .tool {
            if let start = message.content.firstIndex(of: "{"),
               let data = String(message.content[start...]).data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = object["image_id"] as? String { return id }
        }
        return nil
    }
}

#if DEBUG
// Deterministic fixture for the real Agent loop, with no network or credentials.
// Its second turn only answers if the failed tool result actually reaches it.
struct ToolErrorFixtureProvider: LLMProvider {
    static let name = "offline-tool-error-fixture"
    static let reply = "当前没有连接设备，暂时无法查看屏幕。连接桥接后可以再试；我们也可以继续文字对话。"
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
                $0.content == "[Tool: screenshot] ERROR\n设备未连接。可继续文字对话；设备操作需在设置 → 控制调试中连接桥接。"
            }) else { throw AppError.invalid("测试未收到对应工具的完整失败结果") }
            return LLMResponse(text: finalReply, finishReason: .stop, request: request, providerName: Self.name)
        }
        return LLMResponse(text: initialText, finishReason: .toolCalls,
            toolCalls: [LLMToolCall(id: "fixture-screenshot", name: "screenshot", arguments: "{}")], request: request, providerName: Self.name)
    }
}
#endif
