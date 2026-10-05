import Foundation
import Combine

/// Metadata only: never calls a generation endpoint or follows a redirect.
final class ModelDiscoveryClient: @unchecked Sendable {
    private let session: URLSession
    private let redirectGuard = NoRedirectDelegate()
    init(configuration: URLSessionConfiguration = .ephemeral) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-model-catalog") {
            configuration.protocolClasses = [ModelCatalogUIFixture.self]
        }
        #endif
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    static func failure(_ error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return "已取消获取；仍可使用缓存或手动模型 ID" }
        if (error as? URLError)?.code == .timedOut { return "模型列表请求超时；可重试或手动填写模型 ID" }
        return (error as? AppError)?.localizedDescription ?? "无法获取模型列表；请检查网络，或使用缓存／手动模型 ID"
    }
    private func json(_ request: URLRequest) async throws -> [String: Any] {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.invalid("模型列表响应无效") }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw AppError.unavailable("401：密钥无效或未提供；请检查此服务商的密钥")
        case 403: throw AppError.unavailable("403：此密钥无权查看模型；可手动填写已授权的模型 ID")
        case 404: throw AppError.unavailable("404：模型接口不存在；请核对协议与基础地址，或手动填写模型 ID")
        case 429: throw AppError.unavailable("429：服务商限流；请稍后刷新，未自动重试")
        case 300..<400: throw AppError.unavailable("服务商返回重定向；为保护密钥未跟随，请直接填写最终基础地址")
        default: throw AppError.unavailable("模型列表请求失败（HTTP \(http.statusCode)）；可使用缓存或手动模型 ID")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 8 * 1_024 * 1_024 else { throw AppError.invalid("模型元数据响应过大，旧缓存已保留") }
            data.append(byte)
        }
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.invalid("模型接口未返回有效 JSON 对象；请核对协议与基础地址")
        }
        return result
    }
    func request(profile: ProviderProfile, key: String, cursor: String? = nil, offset: Int = 0, model: String? = nil) throws -> URLRequest {
        let kind = profile.protocolType, base = try kind.baseURL(profile.settings.baseURL)
        let endpoint = kind == .ollama ? base.appendingPathComponent(model == nil ? "api/tags" : "api/show") : base.appendingPathComponent("models")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        switch kind {
        case .anthropic: components.queryItems = [.init(name: "limit", value: "100")] + (cursor.map { [.init(name: "after_id", value: $0)] } ?? [])
        case .gemini: components.queryItems = [.init(name: "pageSize", value: "100")] + (cursor.map { [.init(name: "pageToken", value: $0)] } ?? [])
        case .openRouter: components.queryItems = [.init(name: "limit", value: "100"), .init(name: "offset", value: String(offset))]
        case .openAI: if let cursor { components.queryItems = [.init(name: "after", value: cursor)] }
        case .ollama: break
        }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch kind {
        case .anthropic:
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini: if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        default: if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        if let model {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "verbose": false])
        }
        return request
    }
    func fetch(profile: ProviderProfile, key: String) async throws -> ModelCatalog {
        let kind = profile.protocolType
        var models: [DiscoveredModel] = [], indices: [String: Int] = [:]
        var cursor: String?, seenCursors = Set<String>(), seenPages = Set<[String]>()
        var offset = 0
        while true {
            let value = try await json(request(profile: profile, key: key, cursor: cursor, offset: offset))
            let page = try Self.parseList(value, protocolType: kind)
            for model in page {
                if let index = indices[model.id] { models[index] = model }
                else { indices[model.id] = models.count; models.append(model) }
            }
            var hasMore = false
            switch kind {
            case .anthropic, .openAI:
                hasMore = value["has_more"] as? Bool == true
                cursor = value["last_id"] as? String ?? page.last?.id
            case .gemini:
                cursor = value["nextPageToken"] as? String
                hasMore = cursor?.isEmpty == false
            case .openRouter:
                offset += page.count
                if let total = value["total_count"] as? Int { hasMore = offset < total }
                else if let links = value["links"] as? [String: Any], links["next"] != nil {
                    hasMore = (links["next"] as? String)?.isEmpty == false
                } else { hasMore = page.count == 100 }
                cursor = String(offset) // Never follow server-provided URLs with credentials.
            case .ollama: break
            }
            guard hasMore else { break }
            guard !page.isEmpty, let next = cursor, !next.isEmpty,
                  seenCursors.insert(next).inserted, seenPages.insert(page.map(\.id)).inserted,
                  models.count <= 50_000 else { throw AppError.invalid("模型分页未取得进展或列表过大；旧缓存已保留") }
        }
        if kind == .ollama {
            // /show is metadata, not inference. Failed details remain explicitly unknown.
            for index in models.indices {
                try Task.checkCancellation()
                do {
                    let value = try await json(request(profile: profile, key: key, model: models[index].id))
                    models[index] = Self.ollamaDetails(value, model: models[index])
                } catch {
                    try Task.checkCancellation()
                    if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    models[index].detailNotice = Self.failure(error)
                }
            }
        }
        try Task.checkCancellation()
        return ModelCatalog(endpoint: try profile.catalogEndpoint(), fetchedAt: Date(), models: models)
    }
    static func parseList(_ value: [String: Any], protocolType: ProviderProtocol) throws -> [DiscoveredModel] {
        let arrayKey = [.gemini, .ollama].contains(protocolType) ? "models" : "data"
        // Google omits an empty repeated field. Other missing arrays are format errors.
        let rows: [[String: Any]]
        if let list = value[arrayKey] as? [[String: Any]] { rows = list }
        else if protocolType == .gemini && value.isEmpty { rows = [] }
        else { throw AppError.invalid("模型列表格式与所选协议不匹配") }
        return try rows.map { row in
            let raw = row[protocolType == .gemini ? "name" : protocolType == .ollama ? "name" : "id"] as? String
            guard let id = raw, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.invalid("模型列表中有无效 ID") }
            var model = DiscoveredModel(id: id, name: row["display_name"] as? String ?? row["displayName"] as? String ?? row["name"] as? String ?? id)
            switch protocolType {
            case .openAI, .ollama: break
            case .anthropic:
                let caps = row["capabilities"] as? [String: [String: Any]]
                model.vision = CapabilitySupport(caps?["image_input"]?["supported"] as? Bool)
                model.thinking = CapabilitySupport(caps?["thinking"]?["supported"] as? Bool)
                model.inputTokenLimit = positive(row["max_input_tokens"])
                model.outputTokenLimit = positive(row["max_tokens"])
            case .gemini:
                model.generationMethods = row["supportedGenerationMethods"] as? [String]
                model.generation = CapabilitySupport(model.generationMethods.map { $0.contains("generateContent") })
                model.thinking = CapabilitySupport(row["thinking"] as? Bool)
                model.inputTokenLimit = positive(row["inputTokenLimit"])
                model.outputTokenLimit = positive(row["outputTokenLimit"])
                model.maxTemperature = row["maxTemperature"] as? Double
            case .openRouter:
                let architecture = row["architecture"] as? [String: Any]
                model.vision = CapabilitySupport((architecture?["input_modalities"] as? [String]).map { $0.contains("image") })
                model.generation = CapabilitySupport((architecture?["output_modalities"] as? [String]).map { $0.contains("text") })
                model.supportedParameters = row["supported_parameters"] as? [String]
                model.tools = CapabilitySupport(model.supportedParameters.map { $0.contains("tools") })
                model.inputTokenLimit = positive(row["context_length"])
                model.outputTokenLimit = positive((row["top_provider"] as? [String: Any])?["max_completion_tokens"])
                model.pricing = row["pricing"] as? [String: String]
            }
            return model
        }
    }
    static func ollamaDetails(_ value: [String: Any], model: DiscoveredModel) -> DiscoveredModel {
        var result = model
        let caps = value["capabilities"] as? [String]
        result.vision = CapabilitySupport(caps.map { $0.contains("vision") })
        result.tools = CapabilitySupport(caps.map { $0.contains("tools") })
        result.generation = CapabilitySupport(caps.map { $0.contains("completion") })
        result.thinking = CapabilitySupport(caps.map { $0.contains("thinking") })
        if let info = value["model_info"] as? [String: Any], let architecture = info["general.architecture"] as? String {
            result.inputTokenLimit = positive(info[architecture + ".context_length"])
        }
        // The serialized parameters string contains defaults, not a schema/range.
        return result
    }
    private static func positive(_ value: Any?) -> Int? { (value as? Int).flatMap { $0 > 0 ? $0 : nil } }
}

#if DEBUG
private final class ModelCatalogUIFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "catalog-fixture.invalid", request.url?.path == "/v1/models" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"fixture-vision"},{"id":"fixture-other"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif

@MainActor final class ModelDiscoveryState: ObservableObject {
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let client: ModelDiscoveryClient
    init(client: ModelDiscoveryClient = ModelDiscoveryClient()) { self.client = client }
    func refresh(profile: ProviderProfile, key: String, receive: @escaping (ModelCatalog) -> Void) {
        cancel(); let token = UUID(); generation = token; loading = true; message = nil
        task = Task { [weak self, client] in
            do {
                let catalog = try await client.fetch(profile: profile, key: key)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                receive(catalog); self.message = catalog.models.isEmpty ? "列表为空；仍可手动填写模型 ID" : "已获取 \(catalog.models.count) 个模型"
                self.loading = false; self.task = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.message = ModelDiscoveryClient.failure(error); self.loading = false; self.task = nil
            }
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        if loading { message = "已取消获取；原缓存保留" }
        loading = false
    }
    func fail(_ error: Error) { message = ModelDiscoveryClient.failure(error) }
}
