import Foundation
import Combine

struct ProviderProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var settings: ProviderSettings
    var models: [String]
    // Reference only. Credentials are never encoded into UserDefaults/history.
    var keyAccount: String

    init(id: UUID = UUID(), name: String = "", settings: ProviderSettings = ProviderSettings(), models: [String] = [], keyAccount: String? = nil) {
        self.id = id; self.name = name; self.settings = settings; self.models = models
        self.keyAccount = keyAccount ?? "provider-profile:\(id):\(settings.baseURL)"
    }
    var availableModels: [String] { Array(NSOrderedSet(array: [settings.model] + models)) as? [String] ?? [] }
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
                guard saved.version == 1 else { throw AppError.invalid("未知服务商配置版本") }
                profiles = saved.profiles; removed = saved.removed
            } else if let data = defaults?.data(forKey: "providerSettings") {
                let legacy = try JSONDecoder().decode(ProviderSettings.self, from: data)
                let host = URL(string: legacy.baseURL)?.host ?? "原服务商"
                let profile = ProviderProfile(name: host, settings: legacy, keyAccount: legacy.keyAccount)
                try persist(profiles: [profile], removed: [])
            }
        } catch { writable = false; warning = "服务商配置无法读取；原数据已保留，暂不能修改" }
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
        let url = try value.settings.validatedURL()
        if value.name.isEmpty { value.name = url.host ?? "服务商" }
        value.models = draft.models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let previous = profiles.first(where: { $0.id == draft.id }) {
            // Editing a label/model keeps the old Keychain reference. Changing
            // destination never forwards that destination's credential.
            value.keyAccount = previous.settings.keyAccount == value.settings.keyAccount
                ? previous.keyAccount : "provider-profile:\(value.id):\(value.settings.baseURL)"
        } else { value.keyAccount = "provider-profile:\(value.id):\(value.settings.baseURL)" }
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
        guard let profile = removed.first(where: { $0.id == id }) else { return }
        try persist(profiles: profiles + [profile], removed: removed.filter { $0.id != id })
    }
    private func persist(profiles: [ProviderProfile], removed: [ProviderProfile]) throws {
        guard writable else { throw AppError.unavailable(warning ?? "配置不可写") }
        let data = try JSONEncoder().encode(Archive(profiles: profiles, removed: removed))
        defaults?.set(data, forKey: Self.storageKey)
        self.profiles = profiles; self.removed = removed
    }
}
