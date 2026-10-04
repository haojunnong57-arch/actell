import Foundation
import LLMProviderKit
import LLMProviderKitOpenAI

/// Reuses the SDK's OpenAI parser/fragment assembler. Tool calls are released
/// only after the stream ends successfully and the single-call policy is checked.
struct ModelStreamDecoder {
    private var assembler = StreamToolCallAssembler()
    private var calls: [LLMToolCall] = []
    private var reason: LLMFinishReason?
    private var sawTerminal = false
    private(set) var sawDone = false
    private(set) var usage: LLMUsage?

    mutating func consume(line: String, request: LLMRequest, encoder: OpenAIProvider) throws -> [LLMStreamChunk] {
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("data:") else { return [] }
        let payload = clean.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { sawDone = true }
        var output: [LLMStreamChunk] = []
        let parsed: [LLMStreamChunk]
        do { parsed = try encoder.parseStreamLine("data: " + payload, request: request) }
        catch { throw AppError.invalid("模型流格式与 Chat Completions 不兼容") }
        for chunk in parsed {
            for complete in assembler.consume(chunk) {
                switch complete {
                case .text: output.append(complete)
                case .reasoning: break // Never store or display private reasoning.
                case .toolCall(let call): calls.append(call)
                case .finish(let finish, let tokens):
                    if let finish, !sawDone { reason = finish; sawTerminal = true }
                    if let tokens { usage = tokens }
                case .error: throw AppError.invalid("模型流返回错误")
                }
            }
        }
        guard calls.count <= 1 else { throw AppError.invalid("模型一次请求多个工具，已阻止执行") }
        return output
    }
    mutating func finish() throws -> [LLMStreamChunk] {
        guard sawTerminal else { throw AppError.invalid("模型流缺少结束标记，已停止；没有重试") }
        for chunk in assembler.flush() { if case .toolCall(let call) = chunk { calls.append(call) } }
        guard calls.count <= 1 else { throw AppError.invalid("模型一次请求多个工具，已阻止执行") }
        if reason == .toolCalls, calls.isEmpty { throw AppError.invalid("模型声明工具调用但缺少参数，已停止；没有重复请求") }
        for call in calls {
            guard !call.name.isEmpty, let data = call.arguments.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw AppError.invalid("工具参数不完整，已阻止执行")
            }
        }
        return calls.map(LLMStreamChunk.toolCall) + [.finish(reason: calls.isEmpty ? reason : .toolCalls, usage: usage)]
    }
}
