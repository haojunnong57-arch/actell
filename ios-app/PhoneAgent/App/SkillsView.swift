import SwiftUI
import UniformTypeIdentifiers

struct SkillsView: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject var store: SkillStore
    @State private var importing = false
    @State private var deleting: SkillPackage?
    @State private var status: String?
    var body: some View {
        List {
            Section {
                Text("技能是供模型按需读取的本地文本参考。启用后，发送任务时允许模型查询摘要、读取相关内容；不会执行脚本，也不能扩大任务或设备权限。")
                    .font(.caption)
                Button("导入 SKILL.md 或文本技能包", systemImage: "square.and.arrow.down") { importing = true }
                    .disabled(model.hasBusySessions).accessibilityIdentifier("importSkill")
                DisclosureGroup("支持的格式") {
                    Text("选择 SKILL.md，或根目录含 SKILL.md 的文件夹。元数据用 --- 包围，必须有 name: 和 description:，可选 version:；支持简单文本及 | / > 多行值。包内只支持 UTF-8 Markdown/TXT，最多 32 个文档、每个 64 KiB、整包 512 KiB；不支持 ZIP、脚本、二进制文件或符号链接。参考文档按相对路径单独加载。")
                        .font(.caption)
                    Text("---\nname: 示例技能\ndescription: 说明适用场景\nversion: 1\n---\n# 操作指南\n这里写任务相关的参考内容。")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                if let status { Text(status).font(.caption).accessibilityIdentifier("skillStatus") }
                if let warning = store.warning { Text(warning).foregroundStyle(.orange) }
            }
            if store.packages.isEmpty {
                ContentUnavailableView("尚未导入技能", systemImage: "books.vertical", description: Text("导入不会自动开始任务或发送正文。"))
            } else {
                Section("本地技能") {
                    ForEach(store.packages) { skill in
                        Group {
                            NavigationLink { SkillDetailView(skill: skill) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(skill.name, systemImage: "book.closed").font(.headline)
                                    Text(skill.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    Text("版本 \(skill.version) · \(skill.revision.prefix(8))").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                Text("启用")
                                Spacer()
                                Toggle("启用", isOn: Binding(get: { skill.enabled }, set: { value in perform { try store.setEnabled(value, id: skill.id) } }))
                                    .labelsHidden().fixedSize().accessibilityLabel("启用 " + skill.name)
                                    .accessibilityIdentifier("enableSkill-" + skill.id.uuidString)
                                Button("删除", role: .destructive) { deleting = skill }.buttonStyle(.borderless)
                                    .accessibilityIdentifier("deleteSkill-" + skill.id.uuidString)
                            }.disabled(model.hasBusySessions)
                        }
                    }
                }
            }
        }
        .navigationTitle("技能").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
            switch result {
            case .success(let url): perform {
                let before = store.packages.count
                let imported = try store.importPackage(url)
                status = before == store.packages.count ? "该内容版本已经存在，未重复导入：\(imported.name)" : "已导入：\(imported.name)。同名旧版本会保留，可分别启用或删除。"
            }
            case .failure: status = "导入未完成；原技能保留，可重新选择文件。"
            }
        }
        .alert("删除这个技能版本？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) { if let deleting { perform { try store.remove(deleting.id) } }; deleting = nil }
        } message: { Text("只删除 App 内此版本的副本，原始导入文件与其他版本保留。以后需要时可以重新导入。") }
    }
    private func perform(_ operation: () throws -> Void) {
        guard !model.hasBusySessions else { status = "请先停止当前任务再修改技能"; return }
        do { try operation() }
        catch { status = error.localizedDescription }
    }
}

private struct SkillDetailView: View {
    let skill: SkillPackage
    @State private var resource = "SKILL.md"
    var body: some View {
        VStack(spacing: 0) {
            Picker("文档", selection: $resource) {
                ForEach(skill.resources, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu).padding(.horizontal)
            ScrollView {
                Text(skill.documents[resource] ?? "此版本没有该文档").font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }.accessibilityIdentifier("skillDocument")
        }.navigationTitle(skill.name).navigationBarTitleDisplayMode(.inline)
    }
}
