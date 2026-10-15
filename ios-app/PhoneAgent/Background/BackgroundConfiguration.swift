import Foundation
import Combine

enum BackgroundMechanism: String, CaseIterable, Codable, Sendable, Identifiable {
    case audio, pictureInPicture, systemTask, location
    var id: String { rawValue }
    var title: String {
        switch self {
        case .audio: "音频"
        case .pictureInPicture: "画中画"
        case .systemTask: "系统后台任务"
        case .location: "定位"
        }
    }
    static let continuous: Set<Self> = [.audio, .pictureInPicture, .location]
}

struct BackgroundConfiguration: Equatable, Sendable, Codable {
    var version = 2
    var selectedRawValues: Set<String>
    var knownSelection: Set<BackgroundMechanism> { Set(selectedRawValues.compactMap(BackgroundMechanism.init(rawValue:))) }
    enum CodingKeys: String, CodingKey { case version, selected }
    init(selected: Set<BackgroundMechanism>) { selectedRawValues = Set(selected.map(\.rawValue)) }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        selectedRawValues = Set(try container.decode([String].self, forKey: .selected))
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(selectedRawValues.sorted(), forKey: .selected)
    }
}

/// Reads the persistent domain, never registration defaults, before any binding.
@MainActor final class BackgroundSettingsStore: ObservableObject {
    static let key = "backgroundExecutionConfiguration"
    static let residentKey = "backgroundResidentEnabled"
    static let legacyKey = "backgroundPlaybackMode" // Retained for one-version diagnostics.
    static let shared: BackgroundSettingsStore = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-testing") || ProcessInfo.processInfo.environment["PHONEAGENT_ISOLATED_TESTS"] == "1" {
            let domain = "Actell.Background.UITests"
            let defaults = UserDefaults(suiteName: domain)!
            if args.contains("--background-fixture-reset") { defaults.removePersistentDomain(forName: domain) }
            if args.contains("--background-fixture-legacy-system") {
                defaults.setPersistentDomain([legacyKey: "systemTask", residentKey: true], forName: domain)
            }
            return BackgroundSettingsStore(defaults: defaults, domain: domain)
        }
        #endif
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("PhoneAgent")
        let installed = root.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("conversations-v1.json").path) } ?? false
        return BackgroundSettingsStore(existingInstallation: installed)
    }()
    @Published private(set) var configuration = BackgroundConfiguration(selected: [])
    @Published private(set) var residentEnabled = false
    @Published private(set) var warning: String?
    private(set) var futureSchema = false
    var selection: Set<BackgroundMechanism> { configuration.knownSelection }
    var hasUnknownOptions: Bool { configuration.selectedRawValues.count != selection.count }
    private let defaults: UserDefaults
    private let domain: String
    private let writer: ((Data) -> Bool)?
    init(defaults: UserDefaults = .standard, domain: String = Bundle.main.bundleIdentifier ?? "com.ja1chen.PhoneAgent",
         existingInstallation: Bool = false, writer: ((Data) -> Bool)? = nil) {
        self.defaults = defaults; self.domain = domain; self.writer = writer
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        residentEnabled = saved[Self.residentKey] as? Bool ?? false
        if let raw = saved[Self.key] {
            if let data = raw as? Data {
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let version = object["version"] as? Int, version > 2 {
                    futureSchema = true; warning = "后台配置来自更新版本；请升级。此版本不使用可选后台方式。"; return
                }
                if let config = try? JSONDecoder().decode(BackgroundConfiguration.self, from: data), config.version == 2 {
                    configuration = config; return
                }
            }
            warning = "后台配置损坏，原数据已保留；请重新选择。"; return
        }
        var initial: Set<BackgroundMechanism>
        if let legacy = saved[Self.legacyKey] {
            if let raw = legacy as? String, let mechanism = BackgroundMechanism(rawValue: raw), mechanism != .location {
                initial = [mechanism]
            } else { initial = []; warning = "旧后台选项无法识别，原值已保留；请重新选择。" }
        } else if saved[Self.residentKey] != nil || existingInstallation {
            initial = [.audio]
        } else { initial = [.audio] }
        let config = BackgroundConfiguration(selected: initial)
        if persist(config) { configuration = config }
    }
    func set(_ mechanism: BackgroundMechanism, selected: Bool) {
        guard !futureSchema else { return }
        var next = configuration
        if selected { next.selectedRawValues.insert(mechanism.rawValue) }
        else { next.selectedRawValues.remove(mechanism.rawValue) }
        if persist(next) { warning = nil; configuration = next }
    }
    func setResident(_ enabled: Bool) {
        var saved = defaults.persistentDomain(forName: domain) ?? [:]
        saved[Self.residentKey] = enabled; defaults.setPersistentDomain(saved, forName: domain)
        residentEnabled = enabled
    }
    private func persist(_ value: BackgroundConfiguration) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        if let writer {
            guard writer(data) else { warning = "后台配置保存失败；原配置保留。"; return false }
        } else {
            var saved = defaults.persistentDomain(forName: domain) ?? [:]
            saved[Self.key] = data; defaults.setPersistentDomain(saved, forName: domain)
            guard defaults.persistentDomain(forName: domain)?[Self.key] as? Data == data else {
                warning = "后台配置保存失败；原配置保留。"; return false
            }
        }
        return true
    }
}
