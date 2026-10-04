import SwiftUI

struct ProvidersView: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject private var providers: ProviderStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ProviderProfile?
    @State private var removing: ProviderProfile?
    init(model: AgentViewModel) { self.model = model; providers = model.providers }
    var body: some View {
        NavigationStack {
            List {
                if let warning = providers.warning { Text(warning).foregroundStyle(.orange) }
                if providers.profiles.isEmpty {
                    ContentUnavailableView("添加模型服务商", systemImage: "server.rack", description: Text("配置地址和模型后，在会话中选择。"))
                }
                ForEach(providers.profiles) { profile in
                    Button { editing = profile } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(profile.name).foregroundStyle(.primary)
                            Text(profile.settings.model).font(.subheadline).foregroundStyle(.secondary)
                            Text(profile.settings.baseURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("provider-\(profile.id)")
                    .swipeActions { Button("移除", role: .destructive) { removing = profile }.disabled(model.running || model.stopping) }
                }
                if !providers.removed.isEmpty {
                    Section("已移除 · 可恢复") {
                        ForEach(providers.removed) { profile in
                            HStack {
                                Text(profile.name)
                                Spacer()
                                Button("恢复") { model.restoreProvider(profile.id) }.disabled(model.running || model.stopping)
                            }
                        }
                    }
                }
                Section {
                    Text("支持 HTTPS OpenAI Chat Completions 兼容服务。密钥保存在本机钥匙串；移除服务商保留配置与密钥，便于恢复。修改 API 地址后需保存对应地址的密钥。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("服务商")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = ProviderProfile() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("添加服务商").accessibilityIdentifier("addProvider")
                        .disabled(model.running || model.stopping || providers.warning != nil)
                }
            }
            .sheet(item: $editing) { profile in ProviderEditor(model: model, profile: profile) }
            .alert("移除此服务商？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("移除服务商", role: .destructive) {
                    if let removing { model.removeProvider(removing.id) }; removing = nil
                }
                Button("取消", role: .cancel) { removing = nil }
            } message: {
                Text("配置和密钥会保留，可在本页恢复。")
            }
        }
    }
}

private struct ProviderEditor: View {
    @ObservedObject var model: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ProviderProfile
    @State private var modelList: String
    @State private var key = ""
    init(model: AgentViewModel, profile: ProviderProfile) {
        self.model = model
        _profile = State(initialValue: profile)
        _modelList = State(initialValue: profile.models.joined(separator: "\n"))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("服务商") {
                    TextField("名称", text: $profile.name).accessibilityIdentifier("providerName")
                    TextField("HTTPS API 基础地址", text: $profile.settings.baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("providerURL")
                    SecureField("API 密钥（留空保留原值）", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("providerKey")
                }
                Section {
                    TextField("默认模型 ID", text: $profile.settings.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("providerModel")
                    TextField("其他模型 ID，每行一个", text: $modelList, axis: .vertical)
                        .lineLimit(3...6).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("providerModels")
                } header: { Text("模型") } footer: { Text("模型须支持图片和工具调用。会话中也可以直接填写其他模型 ID；保存不会请求服务商接口。") }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .disabled(model.running || model.stopping)
            .navigationTitle("编辑服务商").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { key = ""; dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        profile.models = modelList.components(separatedBy: .newlines)
                        if model.saveProvider(profile, key: key) { key = ""; dismiss() }
                    }.disabled(model.running || model.stopping).accessibilityIdentifier("saveProvider")
                }
            }
        }
    }
}
