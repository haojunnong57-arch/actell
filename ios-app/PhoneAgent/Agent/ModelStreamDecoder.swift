import Foundation
import LLMProviderKit
import LLMProviderKitOpenAI

/// Reuses the SDK's OpenAI parser/fragment assembler. Tool calls are released
/// only after the stream ends successfully and the whole batch is validated.
struct ModelStreamDecoder {
    private var assembler = StreamToolCallAssembler()
    private var calls: [LLMToolCall] = []
    private var wireIDs = Set<String>()
    private var reason: LLMFinishReason?
    private var sawTerminal = false
    private(set) var sawDone = false
    private(set) var usage: LLMUsage?

    mutating func consume(line: String, request: LLMRequest, encoder: OpenAIProvider) throws -> [LLMStreamChunk] {
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("data:") else { return [] }
        let payload = clean.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { sawDone = true }
        if let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
           let choice = (object["choices"] as? [[String: Any]])?.first,
           let delta = choice["delta"] as? [String: Any], let fragments = delta["tool_calls"] as? [[String: Any]] {
            for fragment in fragments { if let id = fragment["id"] as? String { wireIDs.insert(id) } }
        }
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
        return output
    }
    mutating func finish(previousCallIDs: Set<String> = []) throws -> [LLMStreamChunk] {
        guard sawTerminal else { throw AppError.invalid("模型流缺少结束标记，已停止；没有重试") }
        for chunk in assembler.flush() { if case .toolCall(let call) = chunk { calls.append(call) } }
        if reason == .toolCalls, calls.isEmpty { throw AppError.invalid("模型声明工具调用但缺少参数，已停止；没有重复请求") }
        guard calls.allSatisfy({ wireIDs.contains($0.id) }) else {
            throw AppError.invalid("模型工具调用缺少原始 ID；本批未执行")
        }
        try Self.validate(calls, previousCallIDs: previousCallIDs)
        return calls.map(LLMStreamChunk.toolCall) + [.finish(reason: calls.isEmpty ? reason : .toolCalls, usage: usage)]
    }
    static func validate(_ calls: [LLMToolCall], previousCallIDs: Set<String> = []) throws {
        var seen = previousCallIDs
        for call in calls {
            guard !call.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, seen.insert(call.id).inserted else {
                throw AppError.invalid("模型工具调用 ID 缺失或重复；本批未执行，不会重放旧动作")
            }
            guard !call.name.isEmpty, let data = call.arguments.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw AppError.invalid("工具参数不完整，已阻止执行")
            }
        }
    }
}
