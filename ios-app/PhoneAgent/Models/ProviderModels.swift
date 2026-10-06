import Foundation

enum ProviderProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, anthropic, gemini, ollama, openRouter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: return "OpenAI-compatible"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        case .ollama: return "Ollama"
        case .openRouter: return "OpenRouter"
        }
    }
    var supportsInference: Bool { self != .anthropic && self != .gemini }
    var inferenceNotice: String {
        supportsInference ? "推理使用 Chat Completions；模型仍须支持图片和工具。" : "目前仅支持模型发现；尚未接入此协议的原生推理，不能开始任务。"
    }
    var defaultBase: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .ollama: return "https://ollama.example"
        case .openRouter: return "https://openrouter.ai/api/v1"
        }
    }
    var baseHint: String {
        switch self {
        case .openAI: return "填写 API 基础地址，通常以 /v1 结尾；保留代理前缀，不填 /chat/completions。不会自动猜测或补 /v1。"
        case .anthropic: return "填写 HTTPS 地址及代理前缀，可包含 /v1；模型接口追加 /models。"
        case .gemini: return "填写 HTTPS 地址及代理前缀，可包含 /v1beta；模型接口追加 /models。"
        case .ollama: return "填写 Ollama 的 HTTPS 服务根地址（可用反向代理），保留代理前缀；发现用 /api，推理用 /v1。不支持明文 HTTP。"
        case .openRouter: return "填写完整 API 基础地址，通常为 https://openrouter.ai/api/v1；保留代理前缀。"
        }
    }
    func baseURL(_ text: String) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text), parts.scheme == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw AppError.invalid("请填写不含凭据、查询参数或片段的 HTTPS 基础地址")
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        let lower = parts.path.lowercased()
        guard !["/chat/completions", "/messages", "/models", "/api/tags", "/api/show"].contains(where: lower.hasSuffix),
              !lower.contains(":generatecontent"), !lower.contains(":streamgeneratecontent") else {
            throw AppError.invalid("此处需要基础地址，请移除具体接口路径（例如 /chat/completions 或 /models）")
        }
        guard !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw AppError.invalid("基础地址不能包含相对路径片段")
        }
        if self == .anthropic, !parts.path.hasSuffix("/v1") { parts.path += "/v1" }
        if self == .gemini, !parts.path.hasSuffix("/v1beta") { parts.path += "/v1beta" }
        if self == .ollama {
            guard !parts.path.hasSuffix("/v1") else { throw AppError.invalid("Ollama 请填写服务根地址，移除末尾 /v1") }
            if parts.path.hasSuffix("/api") { parts.path.removeLast(4) }
        }
        guard let url = parts.url else { throw AppError.invalid("基础地址格式无效") }
        return url
    }
    func inferenceBase(_ text: String) throws -> URL {
        guard supportsInference else { throw AppError.unavailable(inferenceNotice) }
        let base = try baseURL(text)
        return self == .ollama ? base.appendingPathComponent("v1") : base
    }
}

enum CapabilitySupport: String, Codable, Sendable {
    case supported, unsupported, unknown
    init(_ value: Bool?) { self = value.map { $0 ? .supported : .unsupported } ?? .unknown }
    var label: String {
        switch self { case .supported: return "支持"; case .unsupported: return "不支持"; case .unknown: return "未知" }
    }
}

struct DiscoveredModel: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var vision: CapabilitySupport = .unknown
    var tools: CapabilitySupport = .unknown
    var generation: CapabilitySupport = .unknown
    var thinking: CapabilitySupport = .unknown
    var inputTokenLimit: Int?
    var outputTokenLimit: Int?
    var maxTemperature: Double?
    var supportedParameters: [String]?
    var generationMethods: [String]?
    var pricing: [String: String]?
    var detailNotice: String?
    var capabilitySummary: String { "图片：\(vision.label) · 工具：\(tools.label)" }
}

struct ModelCatalog: Codable, Equatable, Sendable {
    var endpoint: String
    var fetchedAt: Date
    var models: [DiscoveredModel]
}

enum ModelParameter: String, CaseIterable, Identifiable, Sendable {
    case temperature, topP = "top_p", maxTokens = "max_tokens", maxCompletionTokens = "max_completion_tokens", seed
    var id: String { rawValue }
    var isInteger: Bool { self != .temperature && self != .topP }
    static func fields(for protocolType: ProviderProtocol) -> [ModelParameter] {
        guard protocolType.supportsInference else { return [] }
        return protocolType == .openAI ? allCases : allCases.filter { $0 != .maxCompletionTokens }
    }
    func support(protocolType: ProviderProtocol, model: DiscoveredModel?) -> CapabilitySupport {
        guard Self.fields(for: protocolType).contains(self) else { return .unsupported }
        if let parameters = model?.supportedParameters { return CapabilitySupport(parameters.contains(rawValue)) }
        // A protocol accepting a field is not evidence that every model accepts it.
        return .unknown
    }
    func hint(protocolType: ProviderProtocol, model: DiscoveredModel?) -> String {
        if self == .temperature {
            return protocolType == .ollama ? "数值；接口未提供模型范围" : "0–2；模型可能有额外约束"
        }
        if self == .topP { return "0–1；通常与 temperature 二选一" }
        if self == .seed { return "整数；不保证结果完全确定" }
        return model?.outputTokenLimit.map { "正整数；接口报告上限 \($0)" } ?? "正整数；模型上限未知"
    }
}

struct ModelParameters: Codable, Equatable, Sendable {
    // Only allowlisted, explicitly entered values are sent. Empty means omitted.
    var values: [String: String] = [:]
    func requestFields(protocolType: ProviderProtocol, model: DiscoveredModel?) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for field in ModelParameter.fields(for: protocolType) {
            guard let text = values[field.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            guard field.support(protocolType: protocolType, model: model) != .unsupported else { continue }
            if field.isInteger {
                guard let value = Int64(text) else { throw AppError.invalid("\(field.rawValue) 需要整数") }
                if field != .seed {
                    guard value > 0, model?.outputTokenLimit.map({ value <= $0 }) ?? true else {
                        throw AppError.invalid("\(field.rawValue) 超出模型报告的输出范围")
                    }
                }
                result[field.rawValue] = value
            } else {
                guard let value = Double(text), value.isFinite else { throw AppError.invalid("\(field.rawValue) 需要有限数值") }
                if field == .topP, !(0...1).contains(value) { throw AppError.invalid("top_p 范围是 0–1") }
                if field == .temperature, protocolType != .ollama, !(0...2).contains(value) {
                    throw AppError.invalid("此协议的 temperature 范围是 0–2")
                }
                result[field.rawValue] = value
            }
        }
        guard result["max_tokens"] == nil || result["max_completion_tokens"] == nil else {
            throw AppError.invalid("max_tokens 与 max_completion_tokens 请选择一个填写")
        }
        return result
    }
}
