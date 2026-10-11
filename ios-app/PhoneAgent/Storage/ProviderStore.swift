import Foundation
import Combine

struct ProviderProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var settings: ProviderSettings
    var models: [String]
    var protocolKind: ProviderKind?
    var inferenceKind: InferenceAPI?
    var contextKind: ProviderContextPolicy?
    var catalog: ModelCatalog?
    var modelParameters: [String: ModelParameters]?
    // Reference only. Credentials are never encoded into UserDefaults/history.
    var keyAccount: String

    init(id: UUID = UUID(), name: String = "", settings: ProviderSettings = ProviderSettings(), models: [String] = [], keyAccount: String? = nil) {
        self.id = id; self.name = name; self.settings = settings; self.models = models
        self.keyAccount = keyAccount ?? "provider-profile:\(id):\(settings.baseURL)"
    }
    var providerKind: ProviderKind { protocolKind ?? .openAI }
    var inferenceAPI: InferenceAPI { inferenceKind ?? .chatCompletions }
    var contextPolicy: ProviderContextPolicy { contextKind ?? .stateless }
    func catalogEndpoint() throws -> String { providerKind.rawValue + ":" + (try providerKind.baseURL(settings.baseURL)).absoluteString }
    var currentCatalog: ModelCatalog? { catalog?.endpoint == (try? catalogEndpoint()) ? catalog : nil }
    var availableModels: [String] {
        Array(NSOrderedSet(array: ([settings.model] + models + (currentCatalog?.models.map(\.id) ?? [])).filter { !$0.isEmpty })) as? [String] ?? []
    }
    var previewModels: [String] {
        let listed = Array(NSOrderedSet(array: (models + (currentCatalog?.models.map(\.id) ?? [])).filter { !$0.isEmpty })) as? [String] ?? []
        var preview = Array(listed.prefix(5))
        if !settings.model.isEmpty, !preview.contains(settings.model) { preview.append(settings.model) }
        return preview
    }
    mutating func selectDefaultModelIfNeeded() {
        guard settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        settings.model = availableModels.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }
    func metadata(for model: String) -> DiscoveredModel? { currentCatalog?.models.first { $0.id == model } }
    func parameters(for model: String) -> ModelParameters { modelParameters?[model] ?? ModelParameters() }
    func requireInference(model: String) throws {
        guard inferenceAPI == .chatCompletions || providerKind.supportsResponses else { throw AppError.invalid("此协议仅支持 Chat Completions 推理") }
        guard inferenceAPI == .responses || contextPolicy == .stateless else { throw AppError.invalid("服务端响应链需要 Responses") }
        guard contextPolicy == .stateless || providerKind.supportsResponseChain else { throw AppError.invalid("此供应商不支持服务端响应链；请选择本地回放") }
        guard providerKind.supportsInference else { throw AppError.unavailable(providerKind.inferenceNotice) }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.invalid("请先选择或手动填写模型 ID") }
        if let metadata = metadata(for: model), metadata.vision == .unsupported || metadata.tools == .unsupported || metadata.generation == .unsupported {
            throw AppError.unavailable("供应商明确报告此模型不支持图片、工具或文本生成，不能执行屏幕任务；请选择兼容模型")
        }
    }
}

@MainActor final class ProviderStore: ObservableObject {
    private struct Archive: Codable {
        var version = 1
        var profiles: [ProviderProfile]
        var removed: [ProviderProfile]
    }
    @Published private(set) var profiles: [ProviderProfile] = []
    @Published private(set) var removed: [ProviderProfile] = []
    @Published private(set) var warning: String?
    private let defaults: UserDefaults?
    private var writable = true
    static let storageKey = "providerProfiles-v1"
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        do {
            if let data = defaults?.data(forKey: Self.storageKey) {
                let saved = try JSONDecoder().decode(Archive.self, from: data)
                guard saved.version == 1 else { throw AppError.invalid("未知供应商配置版本") }
                profiles = saved.profiles; removed = saved.removed
                for index in profiles.indices { profiles[index].selectDefaultModelIfNeeded() }
            } else if let data = defaults?.data(forKey: "providerSettings") {
                let legacy = try JSONDecoder().decode(ProviderSettings.self, from: data)
                let host = URL(string: legacy.baseURL)?.host ?? "原供应商"
                let profile = ProviderProfile(name: host, settings: legacy, keyAccount: legacy.keyAccount)
                try persist(profiles: [profile], removed: [])
            }
        } catch { writable = false; warning = "供应商配置无法读取；原数据已保留，暂不能修改" }
    }
    func profile(_ id: UUID?) -> ProviderProfile? {
        guard let id else { return profiles.first }
        return profiles.first { $0.id == id }
    }
    func prepared(_ draft: ProviderProfile) throws -> ProviderProfile {
        guard writable else { throw AppError.unavailable(warning ?? "配置不可写") }
        var value = draft
        value.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.settings.baseURL = draft.settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        value.settings.model = draft.settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.inferenceAPI == .chatCompletions || value.providerKind.supportsResponses else { throw AppError.invalid("此协议尚不支持 Responses") }
        guard value.inferenceAPI == .responses || value.contextPolicy == .stateless else { throw AppError.invalid("响应链需要 Responses") }
        if value.inferenceAPI == .responses, value.modelParameters?.values.contains(where: { !($0.values["seed"] ?? "").isEmpty }) == true { throw AppError.invalid("Responses 不支持 seed，请清空该参数") }
        guard value.contextPolicy == .stateless || value.providerKind.supportsResponseChain else { throw AppError.invalid("此供应商不支持服务端响应链") }
        let url = try value.providerKind.baseURL(value.settings.baseURL)
        if value.name.isEmpty { value.name = url.host ?? "供应商" }
        value.models = draft.models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let previous = profiles.first(where: { $0.id == draft.id }) {
            // Editing a label/model keeps the old Keychain reference. Changing
            // destination never forwards that destination's credential.
            let sameEndpoint = try previous.catalogEndpoint() == value.catalogEndpoint()
            value.keyAccount = sameEndpoint ? previous.keyAccount : value.newKeyAccount
            if !sameEndpoint { value.modelParameters = nil }
        } else { value.keyAccount = value.newKeyAccount }
        if value.currentCatalog == nil { value.catalog = nil }
        value.selectDefaultModelIfNeeded()
        for (model, parameters) in value.modelParameters ?? [:] {
            _ = try parameters.requestFields(providerKind: value.providerKind, model: value.metadata(for: model))
        }
        return value
    }
    func save(_ draft: ProviderProfile) throws {
        let value = try prepared(draft)
        var next = profiles
        if let index = next.firstIndex(where: { $0.id == value.id }) { next[index] = value }
        else { next.append(value) }
        try persist(profiles: next, removed: removed)
    }
    func remove(_ id: UUID) throws {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        try persist(profiles: profiles.filter { $0.id != id }, removed: removed.filter { $0.id != id } + [profile])
    }
    func restore(_ id: UUID) throws {
        guard var profile = removed.first(where: { $0.id == id }) else { return }
        profile.selectDefaultModelIfNeeded()
        try persist(profiles: profiles + [profile], removed: removed.filter { $0.id != id })
    }
    private func persist(profiles: [ProviderProfile], removed: [ProviderProfile]) throws {
        guard writable else { throw AppError.unavailable(warning ?? "配置不可写") }
        let data = try JSONEncoder().encode(Archive(profiles: profiles, removed: removed))
        defaults?.set(data, forKey: Self.storageKey)
        self.profiles = profiles; self.removed = removed
    }
}

private extension ProviderProfile {
    var newKeyAccount: String {
        let discriminator = providerKind == .openAI ? "" : providerKind.rawValue + ":"
        return "provider-profile:\(id):\(discriminator)\(settings.baseURL)"
    }
}
