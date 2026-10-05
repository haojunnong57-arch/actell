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
                            Text(profile.protocolType.title + (profile.protocolType.supportsInference ? "" : " · 仅模型发现"))
                                .font(.caption).foregroundStyle(.secondary)
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
                    Text("获取模型只读取元数据，不发送对话或开始推理。密钥保存在本机钥匙串；移除服务商可恢复。修改协议或 API 地址后需使用对应密钥。")
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
    @StateObject private var discovery = ModelDiscoveryState()
    @State private var showingModels = false
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
                    Picker("协议", selection: Binding(get: { profile.protocolType }, set: { kind in
                        let wasDefault = profile.settings.baseURL == profile.protocolType.defaultBase
                        profile.protocolKind = kind
                        if wasDefault { profile.settings.baseURL = kind.defaultBase }
                    })) {
                        ForEach(ProviderProtocol.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("providerProtocol")
                    TextField("HTTPS API 基础地址", text: $profile.settings.baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("providerURL")
                    SecureField("API 密钥（留空保留原值）", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("providerKey")
                    Text(profile.protocolType.baseHint).font(.caption).foregroundStyle(.secondary)
                    Text(profile.protocolType.inferenceNotice).font(.caption)
                        .foregroundStyle(profile.protocolType.supportsInference ? Color.secondary : Color.orange)
                }
                Section {
                    TextField("默认模型 ID", text: $profile.settings.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("providerModel")
                    HStack {
                        Button(profile.currentCatalog == nil ? "获取模型" : "刷新模型") { refresh() }
                            .disabled(discovery.loading).accessibilityIdentifier("fetchModels")
                        Spacer()
                        if discovery.loading {
                            ProgressView()
                            Button("取消获取") { discovery.cancel() }.accessibilityIdentifier("cancelModels")
                        }
                    }
                    if let message = discovery.message { Text(message).font(.caption).accessibilityIdentifier("modelDiscoveryStatus") }
                    if let catalog = profile.currentCatalog {
                        Button("选择已获取的模型（\(catalog.models.count)）") { showingModels = true }.accessibilityIdentifier("chooseDiscoveredModel")
                        Text("本地缓存：\(catalog.fetchedAt.formatted(date: .abbreviated, time: .shortened))；刷新失败保留缓存。保存后下次可离线使用。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("其他模型 ID，每行一个", text: $modelList, axis: .vertical)
                        .lineLimit(3...6).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("providerModels")
                } header: { Text("模型") } footer: { Text("无法获取列表时仍可手动填写 ID。列表不代表推理兼容性；未提供的能力显示未知。保存不会发起网络请求。") }
                if let metadata = profile.metadata(for: profile.settings.model) { ModelMetadataSection(metadata: metadata) }
                if !profile.settings.model.isEmpty {
                    ModelParameterSection(protocolType: profile.protocolType, metadata: profile.metadata(for: profile.settings.model),
                        parameters: Binding(get: { profile.parameters(for: profile.settings.model) }, set: { value in
                            if profile.modelParameters == nil { profile.modelParameters = [:] }
                            profile.modelParameters?[profile.settings.model] = value
                        }))
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .disabled(model.running || model.stopping)
            .navigationTitle("编辑服务商").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingModels) {
                ProviderModelPicker(profile: profile) { profile.settings.model = $0 }
            }
            .onChange(of: profile.settings.baseURL) { _, _ in invalidateDiscovery() }
            .onChange(of: profile.protocolKind) { _, _ in invalidateDiscovery() }
            .onChange(of: key) { _, _ in discovery.cancel(); profile.catalog = nil }
            .onDisappear { discovery.cancel() }
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
    private func invalidateDiscovery() {
        discovery.cancel(); profile.catalog = nil; profile.modelParameters = nil
    }
    private func refresh() {
        do {
            let credential = try model.discoveryKey(for: profile, typedKey: key)
            discovery.refresh(profile: profile, key: credential) { profile.catalog = $0 }
        } catch { discovery.fail(error) }
    }
}

struct ProviderModelPicker: View {
    let profile: ProviderProfile
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List(profile.availableModels.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { id in
                Button { select(id); dismiss() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(id).foregroundStyle(.primary)
                        Text(profile.metadata(for: id)?.capabilitySummary ?? "图片：未知 · 工具：未知").font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
            .searchable(text: $search, prompt: "搜索模型 ID")
            .navigationTitle("选择模型")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

private struct ModelMetadataSection: View {
    let metadata: DiscoveredModel
    var body: some View {
        Section("接口报告的能力") {
            Text(metadata.capabilitySummary)
            Text("文本生成：\(metadata.generation.label) · 思考：\(metadata.thinking.label)")
            if let input = metadata.inputTokenLimit { Text("输入／上下文上限：\(input) tokens") }
            if let output = metadata.outputTokenLimit { Text("输出上限：\(output) tokens") }
            if let maximum = metadata.maxTemperature { Text("模型报告 maxTemperature：\(maximum.formatted())") }
            if let methods = metadata.generationMethods { Text("生成方法：" + methods.joined(separator: ", ")) }
            if let prices = metadata.pricing {
                ForEach(prices.keys.sorted(), id: \.self) { key in Text("报价 \(key)：\(prices[key] ?? "")").font(.caption) }
                Text("报价单位和计费条件请以服务商为准。不会根据报价调用模型。").font(.caption).foregroundStyle(.secondary)
            }
            if let notice = metadata.detailNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
        }.font(.subheadline)
    }
}

private struct ModelParameterSection: View {
    let protocolType: ProviderProtocol
    let metadata: DiscoveredModel?
    @Binding var parameters: ModelParameters
    var body: some View {
        Section {
            ForEach(ModelParameter.fields(for: protocolType)) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.rawValue + " · " + field.support(protocolType: protocolType, model: metadata).label).font(.subheadline)
                    TextField("未设置，使用服务商默认值", text: Binding(get: { parameters.values[field.rawValue] ?? "" }, set: { parameters.values[field.rawValue] = $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(field.support(protocolType: protocolType, model: metadata) == .unsupported)
                        .accessibilityIdentifier("parameter-" + field.rawValue)
                    Text(field.hint(protocolType: protocolType, model: metadata)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !protocolType.supportsInference { Text("原生推理尚未接入，暂不提供推理参数设置。") }
        } header: { Text("此服务商／模型的参数") }
        footer: { Text("留空不发送参数。未知表示模型接口未声明：可手动填写协议已知字段，但服务商仍可能拒绝。明确不支持的字段不会发送。设置仅用于此服务商的当前模型。") }
    }
}
