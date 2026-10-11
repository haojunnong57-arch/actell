import SwiftUI

struct ProvidersView: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject private var providers: ProviderStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ProviderProfile?
    @State private var removing: ProviderProfile?
    @State private var adding = false
    init(model: AgentViewModel) { self.model = model; providers = model.providers }
    var body: some View {
        Group {
            List {
                if let warning = providers.warning { Text(warning).foregroundStyle(.orange) }
                if providers.profiles.isEmpty {
                    ContentUnavailableView("添加模型供应商", systemImage: "server.rack", description: Text("配置地址和模型后，在会话中选择。"))
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
            .navigationTitle("供应商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("添加供应商").accessibilityIdentifier("addProvider")
                        .disabled(model.hasBusySessions || providers.warning != nil)
                }
            }
            .sheet(item: $editing) { profile in ProviderEditor(model: model, profile: profile) }
            .sheet(isPresented: $adding) { ProviderCreationView(model: model) }
            .alert("移除此供应商？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("移除供应商", role: .destructive) {
                    if let removing { model.removeProvider(removing.id) }; removing = nil
                }
                Button("取消", role: .cancel) { removing = nil }
            } message: {
                Text("配置和密钥会保留，可在本页恢复。")
            }
        }
    }
}

private struct ProviderCreationView: View {
    @ObservedObject var model: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProviderProfile?
    var body: some View {
        if let draft {
            ProviderEditor(model: model, profile: draft)
        } else {
            NavigationStack {
                List {
                    Button("OpenAI") { select(.openAI) }.accessibilityIdentifier("providerPresetOpenAI")
                    Button("OpenRouter") { select(.openRouter) }.accessibilityIdentifier("providerPresetOpenRouter")
                    Button("自定义供应商") { select(nil) }.accessibilityIdentifier("providerPresetCustom")
                }
                .navigationTitle("添加供应商").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            }
        }
    }
    private func select(_ preset: ProviderKind?) {
        var profile = ProviderProfile()
        profile.protocolKind = preset ?? .openAI
        profile.name = preset.map { $0 == .openAI ? "OpenAI" : $0.title } ?? ""
        profile.settings.baseURL = preset?.defaultBase ?? ""
        profile.settings.model = ""
        draft = profile
    }
}

private struct ProviderEditor: View {
    @ObservedObject var model: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ProviderProfile
    @State private var key = ""
    @State private var hasSavedKey = false
    @FocusState private var keyFocused: Bool
    @StateObject private var discovery = ModelDiscoveryState()
    @State private var showingModels = false
    @State private var addingModel = false
    @State private var manualModel = ""
    init(model: AgentViewModel, profile: ProviderProfile) {
        self.model = model
        var draft = profile
        draft.selectDefaultModelIfNeeded()
        _profile = State(initialValue: draft)
        _hasSavedKey = State(initialValue: model.hasSavedProviderKey(for: draft))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("供应商") {
                    TextField("名称", text: $profile.name).accessibilityIdentifier("providerName")
                    if !profile.providerKind.isSelectable {
                        Text("此供应商类型已从列表移除。原配置与密钥保留；请返回列表添加新的供应商。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    TextField("HTTPS API 基础地址", text: $profile.settings.baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("providerURL")
                    SecureField("API 密钥", text: $key, prompt: Text(hasSavedKey && key.isEmpty && !keyFocused ? "" : "API 密钥"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($keyFocused)
                        .overlay(alignment: .leading) {
                            if hasSavedKey && key.isEmpty && !keyFocused {
                                Text("••••••••").foregroundStyle(.primary)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel("API 密钥")
                        .accessibilityValue(key.isEmpty ? (hasSavedKey ? "已保存密钥" : "未设置密钥") : "已输入密钥")
                        .accessibilityIdentifier("providerKey")
                    if profile.providerKind.supportsResponses {
                        Picker("API格式", selection: Binding(get: { profile.inferenceAPI }, set: { api in
                            profile.inferenceKind = api
                            if api == .chatCompletions { profile.contextKind = .stateless }
                        })) { ForEach(InferenceAPI.allCases) { Text($0.title).tag($0) } }.accessibilityIdentifier("providerInferenceAPI")
                        if profile.inferenceAPI == .responses {
                            if profile.providerKind.supportsResponseChain { Picker("上下文", selection: Binding(get: { profile.contextPolicy }, set: { profile.contextKind = $0 })) {
                                ForEach(ProviderContextPolicy.allCases) { Text($0.title).tag($0) }
                            }.accessibilityIdentifier("providerContextPolicy") }
                        }
                    }
                }
                Section {
                    ForEach(profile.previewModels, id: \.self) { id in
                        Button { profile.settings.model = id } label: {
                            ProviderModelRow(id: id, metadata: profile.metadata(for: id), selected: id == profile.settings.model)
                        }.buttonStyle(.plain).accessibilityIdentifier("providerModel-" + id)
                            .accessibilityValue(id == profile.settings.model ? "已选中" : "未选中")
                    }
                    if profile.availableModels.count > 5 {
                        Button("浏览全部模型") { showingModels = true }.accessibilityIdentifier("browseAllProviderModels")
                    }
                } header: {
                    HStack(spacing: 0) {
                        Text("模型")
                        Spacer(minLength: 12)
                        HStack(spacing: 0) {
                            Button { manualModel = ""; addingModel = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                                .accessibilityLabel("添加模型").accessibilityIdentifier("addProviderModel")
                            if discovery.loading {
                                Button { discovery.cancel() } label: {
                                    ProgressView().frame(width: 44, height: 44)
                                }.accessibilityLabel("取消刷新模型").accessibilityIdentifier("cancelModels")
                            } else {
                                Button { refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                                    .accessibilityLabel("刷新模型").accessibilityIdentifier("fetchModels")
                                    .disabled(!profile.providerKind.isSelectable)
                            }
                        }
                        .font(.body)
                        // Align the visible trailing icon with the row content,
                        // while retaining each button's 44-point touch target.
                        .padding(.trailing, -12)
                    }.buttonStyle(.borderless)
                } footer: {
                    if let message = discovery.message { Text(message).font(.caption).accessibilityIdentifier("modelDiscoveryStatus") }
                }
                // Keep stored per-model parameters, but hide their editor until
                // the parameter UI is simplified. Saving must not clear them.
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .disabled(model.hasBusySessions)
            .navigationTitle("编辑供应商").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingModels) {
                ProviderModelPicker(profile: profile) { profile.settings.model = $0 }
            }
            .alert("添加模型", isPresented: $addingModel) {
                TextField("模型 ID", text: $manualModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("添加") {
                    let id = manualModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !profile.models.contains(id) { profile.models.append(id) }
                    profile.settings.model = id
                }.disabled(manualModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", role: .cancel) { manualModel = "" }
            }
            .onChange(of: profile.settings.baseURL) { _, _ in invalidateDiscovery(); hasSavedKey = model.hasSavedProviderKey(for: profile) }
            .onChange(of: profile.protocolKind) { _, _ in invalidateDiscovery(); hasSavedKey = model.hasSavedProviderKey(for: profile) }
            .onChange(of: key) { _, _ in discovery.cancel(); profile.catalog = nil }
            .onDisappear { discovery.cancel() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { key = ""; dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
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
            discovery.refresh(profile: profile, key: credential) {
                profile.catalog = $0
                profile.selectDefaultModelIfNeeded()
            }
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
                    ProviderModelRow(id: id, metadata: profile.metadata(for: id))
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("providerModelOption-" + id)
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索模型 ID")
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

private struct ProviderModelRow: View {
    let id: String
    let metadata: DiscoveredModel?
    var selected = false
    var body: some View {
        HStack(spacing: 8) {
            Text(id).foregroundStyle(.primary)
            HStack(spacing: 6) {
                capabilityIcon("photo", label: "支持图片输入", support: metadata?.vision)
                capabilityIcon("wrench.and.screwdriver", label: "支持工具调用", support: metadata?.tools)
                capabilityIcon("brain", label: "支持思考", support: metadata?.thinking)
                capabilityIcon("text.bubble", label: "支持文本生成", support: metadata?.generation)
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true) }
        }.padding(.vertical, 4)
    }
    @ViewBuilder private func capabilityIcon(_ symbol: String, label: String, support: CapabilitySupport?) -> some View {
        if support == .supported {
            Image(systemName: symbol).accessibilityLabel(label).help(label)
        }
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
                    TextField("未设置，使用供应商默认值", text: Binding(get: { parameters.values[field.rawValue] ?? "" }, set: { parameters.values[field.rawValue] = $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(field.support(providerKind: providerKind, model: metadata) == .unsupported)
                        .accessibilityIdentifier("parameter-" + field.rawValue)
                    Text(field.hint(providerKind: providerKind, model: metadata)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !providerKind.supportsInference { Text("原生推理尚未接入，暂不提供推理参数设置。") }
        } header: { Text("此供应商／模型的参数") }
        footer: { Text("留空不发送参数。未知表示模型接口未声明：可手动填写协议已知字段，但供应商仍可能拒绝。明确不支持的字段不会发送。设置仅用于此供应商的当前模型。") }
    }
}
