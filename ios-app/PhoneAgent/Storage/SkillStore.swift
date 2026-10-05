import Foundation
import Combine
import CryptoKit

struct SkillPackage: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let summary: String
    let version: String
    let revision: String
    let documents: [String: String]
    var enabled: Bool
    var resources: [String] { documents.keys.sorted() }
    static func validResource(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 240 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") } &&
        ["md", "txt", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }
    static func make(documents: [String: String]) throws -> SkillPackage {
        guard !documents.isEmpty, documents.count <= 32, documents.keys.allSatisfy(validResource),
              documents.values.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 64 * 1_024 }),
              documents.values.reduce(0, { $0 + $1.utf8.count }) <= 512 * 1_024,
              let main = documents["SKILL.md"] else { throw AppError.invalid("技能包需要根目录 SKILL.md，只支持最多 32 个 UTF-8 Markdown/TXT 文档，单文件 64 KiB、整包 512 KiB") }
        let lines = main.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { throw AppError.invalid("SKILL.md 需要 --- 元数据区，包含 name 和 description") }
        var metadata: [String: String] = [:], index = 1
        while index < end {
            let line = lines[index]; index += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else { throw AppError.invalid("技能元数据格式无效；支持简单文本字段或缩进的 | / > 多行文本") }
            let key = String(line[..<colon]), raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard metadata[key] == nil else { throw AppError.invalid("技能元数据字段重复") }
            var value = raw
            if ["|", ">", "|-", ">-"].contains(raw) {
                var parts: [String] = []
                while index < end && (lines[index].hasPrefix(" ") || lines[index].isEmpty) {
                    parts.append(lines[index].trimmingCharacters(in: .whitespaces)); index += 1
                }
                value = parts.joined(separator: raw.hasPrefix(">") ? " " : "\n")
            } else if value.count >= 2, (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            metadata[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let name = metadata["name"], !name.isEmpty, name.count <= 80,
              let summary = metadata["description"], !summary.isEmpty, summary.count <= 1_000 else {
            throw AppError.invalid("技能 name 不能为空且最多 80 字，description 不能为空且最多 1000 字")
        }
        let version = metadata["version"] ?? "未标注"
        guard version.count <= 80 else { throw AppError.invalid("技能版本文本过长") }
        let canonical = documents.keys.sorted().map { "\($0.utf8.count):\($0)\(documents[$0]!.utf8.count):\(documents[$0]!)" }.joined()
        let revision = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return SkillPackage(id: UUID(), name: name, summary: summary, version: version, revision: revision, documents: documents, enabled: true)
    }
}

@MainActor final class SkillStore: ObservableObject {
    @Published private(set) var packages: [SkillPackage] = []
    @Published private(set) var warning: String?
    private let file: URL?
    private var writable = true
    private struct Archive: Codable { var version = 1; let packages: [SkillPackage] }
    init(directory: URL? = nil, inMemory: Bool = false) {
        if inMemory { file = nil; return }
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhoneAgent/Skills")
        file = root.appendingPathComponent("skills-v1.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            var url = root, values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
            if let file, FileManager.default.fileExists(atPath: file.path) {
                let info = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 16 * 1_024 * 1_024 else { throw AppError.invalid("技能存档无效") }
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                guard archive.version == 1, Set(archive.packages.map(\.id)).count == archive.packages.count else { throw AppError.invalid("技能存档版本不支持") }
                for package in archive.packages {
                    let checked = try SkillPackage.make(documents: package.documents)
                    guard checked.revision == package.revision, checked.name == package.name, checked.summary == package.summary, checked.version == package.version else { throw AppError.invalid("技能内容校验失败") }
                }
                packages = archive.packages
            }
        } catch { writable = false; warning = "技能未能读取；已保留原存档，暂不能修改" }
    }
    var enabledSnapshot: [SkillPackage] { packages.filter(\.enabled) }
    @discardableResult func add(documents: [String: String]) throws -> SkillPackage {
        try Task.checkCancellation()
        let candidate = try SkillPackage.make(documents: documents)
        if let existing = packages.first(where: { $0.revision == candidate.revision }) { return existing }
        try save(packages + [candidate]); return candidate
    }
    @discardableResult func importPackage(_ url: URL) throws -> SkillPackage {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let rootInfo = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootInfo.isSymbolicLink != true else { throw AppError.invalid("不支持符号链接技能包") }
        var documents: [String: String] = [:]
        func read(_ file: URL, resource: String) throws {
            try Task.checkCancellation()
            guard SkillPackage.validResource(resource), documents.count < 32 else { throw AppError.invalid("技能包只允许 Markdown/TXT 文档，不包含脚本、图片或压缩包") }
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 64 * 1_024,
                  let text = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw AppError.invalid("技能文档不是有效 UTF-8 普通文件或超过 64 KiB") }
            documents[resource] = text
        }
        if rootInfo.isDirectory == true {
            let root = url.standardizedFileURL.path + "/"
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { throw AppError.invalid("无法读取技能文件夹") }
            var visited = 0
            for case let file as URL in enumerator {
                try Task.checkCancellation(); visited += 1
                guard visited <= 128 else { throw AppError.invalid("技能包目录过多；请选择只含技能文本的文件夹") }
                let info = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isSymbolicLink != true, file.standardizedFileURL.path.hasPrefix(root) else { throw AppError.invalid("技能包包含非法路径或符号链接") }
                if info.isDirectory == true { continue }
                try read(file, resource: String(file.standardizedFileURL.path.dropFirst(root.count)))
            }
        } else {
            guard url.lastPathComponent == "SKILL.md" else { throw AppError.invalid("请选择 SKILL.md 或包含它的文本技能文件夹") }
            try read(url, resource: "SKILL.md")
        }
        return try add(documents: documents)
    }
    func setEnabled(_ enabled: Bool, id: UUID) throws {
        var next = packages
        guard let index = next.firstIndex(where: { $0.id == id }) else { throw AppError.invalid("技能不存在") }
        next[index].enabled = enabled; try save(next)
    }
    func remove(_ id: UUID) throws { try save(packages.filter { $0.id != id }) }
    private func save(_ next: [SkillPackage]) throws {
        guard writable else { throw AppError.unavailable(warning ?? "技能不可写") }
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(Archive(packages: next))
        guard data.count <= 16 * 1_024 * 1_024 else { throw AppError.invalid("技能存储已满，请先确认删除不需要的版本") }
        if let file { try data.write(to: file, options: [.atomic, .completeFileProtection]) }
        packages = next
    }
}
