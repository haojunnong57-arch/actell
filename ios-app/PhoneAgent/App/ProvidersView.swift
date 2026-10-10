import SwiftUI

struct ProvidersView: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject private var providers: ProviderStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ProviderProfile?
    @State private var removing: ProviderProfile?
    init(model: AgentViewModel) { self.model = model; providers = model.providers }
    var body: some View {
        Group {
            List {
                if let warning = providers.warning { Text(warning).foregroundStyle(.orange) }
                if providers.profiles.isEmpty {
                    ContentUnavailableView("添加模型服务商", systemImage: "server.rack", description: Text("配置地址和模型后，在会话中选择。"))
                }
                ForEach(providers.profiles) { profile in
                    Button { editing = profile } label: {
                        HStack {
                            Text(profile.name).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("provider-\(profile.id)")
                    .swipeActions { Button("移除", role: .destructive) { removing = profile }.disabled(model.hasBusySessions) }
                }
                if !providers.removed.isEmpty {
                    Section("已移除 · 可恢复") {
                        ForEach(providers.removed) { profile in
                            HStack {
                                Text(profile.name)
                                Spacer()
                                Button("恢复") { model.restoreProvider(profile.id) }.disabled(model.hasBusySessions)
                            }
                        }
                    }
                }
            }
            .navigationTitle("服务商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = ProviderProfile() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("添加服务商").accessibilityIdentifier("addProvider")
                        .disabled(model.hasBusySessions || providers.warning != nil)
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
                    Picker("服务商", selection: Binding<ProviderKind?>(get: { profile.providerKind.isSelectable ? profile.providerKind : nil }, set: { selection in
                        guard let kind = selection else { return }
                        let wasDefault = profile.settings.baseURL == profile.providerKind.defaultBase
                        profile.protocolKind = kind
                        if !kind.supportsResponses { profile.inferenceKind = .chatCompletions }
                        if !kind.supportsResponseChain { profile.contextKind = .stateless }
                        if wasDefault { profile.settings.baseURL = kind.defaultBase }
                    })) {
                        if !profile.providerKind.isSelectable { Text("请选择服务商").tag(Optional<ProviderKind>.none) }
                        ForEach(ProviderKind.selectableKinds) { Text($0.title).tag(Optional($0)) }
                    }.accessibilityIdentifier("providerProtocol")
                    if !profile.providerKind.isSelectable {
                        Text("此服务商类型已从列表移除。原配置与密钥保留；请选择服务商并核对地址后保存。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    TextField("HTTPS API 基础地址", text: $profile.settings.baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("providerURL")
                    SecureField("API 密钥（留空保留原值）", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("providerKey")
                    Text(profile.providerKind.baseHint).font(.caption).foregroundStyle(.secondary)
                    if profile.providerKind.supportsResponses {
                        Picker("推理接口", selection: Binding(get: { profile.inferenceAPI }, set: { api in
                            profile.inferenceKind = api
                            if api == .chatCompletions { profile.contextKind = .stateless }
                        })) { ForEach(InferenceAPI.allCases) { Text($0.title).tag($0) } }.accessibilityIdentifier("providerInferenceAPI")
                        if profile.inferenceAPI == .responses {
                            if profile.providerKind.supportsResponseChain { Picker("上下文", selection: Binding(get: { profile.contextPolicy }, set: { profile.contextKind = $0 })) {
                                ForEach(ProviderContextPolicy.allCases) { Text($0.title).tag($0) }
                            }.accessibilityIdentifier("providerContextPolicy") }
                            if !profile.providerKind.supportsResponseChain { Text("此服务商 Responses 仅支持本地回放，store=false；不支持 previous_response_id。 ").font(.caption).foregroundStyle(.secondary) }
                            Text(profile.contextPolicy == .stateless
                                 ? "每轮发送有效本地上下文，store=false；不代表服务商所有日志均不留存。网关须明确支持 Responses。"
                                 : "明确启用 store=true 与 previous_response_id。每轮只传新输入；旧截图可能仍在远端上下文，减少上传不等于删除。续接仅在当前任务内使用。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(profile.providerKind.inferenceNotice).font(.caption)
                        .foregroundStyle(profile.providerKind.supportsInference ? Color.secondary : Color.orange)
                }
                Section {
                    TextField("默认模型 ID", text: $profile.settings.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("providerModel")
                    HStack {
                        Button(profile.currentCatalog == nil ? "获取模型" : "刷新模型") { refresh() }
                            .disabled(discovery.loading || !profile.providerKind.isSelectable).accessibilityIdentifier("fetchModels")
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
                    ModelParameterSection(providerKind: profile.providerKind, metadata: profile.metadata(for: profile.settings.model),
                        parameters: Binding(get: { profile.parameters(for: profile.settings.model) }, set: { value in
                            if profile.modelParameters == nil { profile.modelParameters = [:] }
                            profile.modelParameters?[profile.settings.model] = value
                        }))
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .disabled(model.hasBusySessions)
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
                    }.disabled(model.hasBusySessions || !profile.providerKind.isSelectable).accessibilityIdentifier("saveProvider")
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
            .navigationBarTitleDisplayMode(.inline)
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
    let providerKind: ProviderKind
    let metadata: DiscoveredModel?
    @Binding var parameters: ModelParameters
    var body: some View {
        Section {
            ForEach(ModelParameter.fields(for: providerKind)) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.rawValue + " · " + field.support(providerKind: providerKind, model: metadata).label).font(.subheadline)
                    TextField("未设置，使用服务商默认值", text: Binding(get: { parameters.values[field.rawValue] ?? "" }, set: { parameters.values[field.rawValue] = $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(field.support(providerKind: providerKind, model: metadata) == .unsupported)
                        .accessibilityIdentifier("parameter-" + field.rawValue)
                    Text(field.hint(providerKind: providerKind, model: metadata)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !providerKind.supportsInference { Text("原生推理尚未接入，暂不提供推理参数设置。") }
        } header: { Text("此服务商／模型的参数") }
        footer: { Text("留空不发送参数。未知表示模型接口未声明：可手动填写协议已知字段，但服务商仍可能拒绝。明确不支持的字段不会发送。设置仅用于此服务商的当前模型。") }
    }
}
