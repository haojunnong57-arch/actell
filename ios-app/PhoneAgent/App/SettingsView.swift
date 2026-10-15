import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var control = PairingFlow.shared
    @State private var clear = false
    @State private var clearAssets = false
    @State private var assetStatus = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("模型") {
                    NavigationLink { ProvidersView(model: model) } label: {
                        Text("供应商")
                    }.accessibilityIdentifier("openProviders")
                }
                Section("手机操控") {
                    Picker("连接模式", selection: Binding(get: { control.route }, set: { _ = control.selectRoute($0) })) {
                        Text(DeviceControlRoute.vpnLoopback.title).tag(DeviceControlRoute.vpnLoopback)
                        Text(DeviceControlRoute.ncmDeveloper.title).tag(DeviceControlRoute.ncmDeveloper)
                    }.disabled(model.hasBusySessions || !control.canChangeRoute)
                        .accessibilityIdentifier("deviceControlMode")
                    NavigationLink { ESP32ControlSettingsView() } label: {
                        Text("连接与验证")
                    }.accessibilityIdentifier("esp32ControlSettings")
                }
                Section("执行模式") {
                    NavigationLink { BackgroundSettingsView() } label: {
                        Text("模式")
                    }.accessibilityIdentifier("openBackgroundSettings")
                }
                Section("扩展能力") {
                    NavigationLink { SkillsView(model: model, store: model.skills) } label: {
                        Text("技能")
                    }.accessibilityIdentifier("manageSkills")
                }
                Section("本地记录") {
                    Button("清空本地会话与任务记录", role: .destructive) { clear = true }
                        .disabled(model.hasBusySessions)
                    Button("清理未引用附件", role: .destructive) { clearAssets = true }
                        .disabled(model.hasBusySessions).accessibilityIdentifier("clearUnusedAttachments")
                    if !assetStatus.isEmpty { Text(assetStatus).font(.caption) }
                }
                if let warning = model.storageWarning { Text(warning).foregroundStyle(.orange) }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .confirmationDialog("删除本机保存的任务和结果？无法在 App 内恢复。", isPresented: $clear, titleVisibility: .visible) {
                Button("清空记录", role: .destructive) { model.clearHistory() }
            }
            .alert("清理未引用附件？", isPresented: $clearAssets) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) {
                    Task {
                        do { assetStatus = "已清理 \(try await model.clearUnreferencedAttachments()) 个未引用文件" }
                        catch { assetStatus = "未能清理附件；原文件保留" }
                    }
                }
            } message: { Text("现有消息与草稿引用的原图和文件会保留。未引用文件删除后无法恢复。") }
        }
    }
}


private struct BackgroundSettingsView: View {
    @ObservedObject private var settings = BackgroundSettingsStore.shared
    @ObservedObject private var background = BackgroundExecutionCoordinator.shared

    var body: some View {
        Form {
            ForEach(BackgroundMechanism.allCases) { mechanism in
                Section {
                    Toggle(mechanism.title, isOn: Binding(
                        get: { settings.selection.contains(mechanism) },
                        set: { selected in
                            if mechanism == .location { background.setLocationSelected(selected) }
                            else { settings.set(mechanism, selected: selected) }
                        }))
                        .disabled(settings.futureSchema)
                        .accessibilityIdentifier("backgroundMechanism." + mechanism.rawValue)
                    if mechanism == .location && settings.selection.contains(.location) {
                        if background.location?.authorization == .denied {
                            Link("打开系统设置", destination: URL(string: UIApplication.openSettingsURLString)!)
                                .accessibilityIdentifier("backgroundLocationSettings")
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(explanation(mechanism))
                        if mechanism == .location && settings.selection.contains(.location) {
                            Text(locationPermissionStatus)
                                .accessibilityIdentifier("backgroundLocationPermissionStatus")
                        }
                    }
                }
            }
            Section {
                Toggle("后台常驻", isOn: Binding(
                    get: { settings.residentEnabled }, set: { settings.setResident($0) }))
                    .disabled(settings.futureSchema)
                    .accessibilityIdentifier("backgroundResidentEnabled")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("任务结束后，继续使用已开启的音频、画中画或定位方式待命，方便后续任务在后台启动。会增加耗电，不需要时可关闭。")
                    if settings.residentEnabled && settings.selection.intersection(BackgroundMechanism.continuous).isEmpty {
                        Text("请先开启音频、画中画或定位。仅开启系统后台任务无法保持待命。")
                            .accessibilityIdentifier("backgroundNoIdleSource")
                    }
                }
            }
            if let warning = settings.warning {
                Section { Text(warning).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("后台执行")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func explanation(_ mechanism: BackgroundMechanism) -> String {
        switch mechanism {
        case .audio:
            return "播放无声音频，帮助任务在切换 App 后继续，无需额外授权。任务结束后停止；开启后台常驻时会继续播放，可能增加耗电。"
        case .pictureInPicture:
            return background.media?.supported == true
                ? "用浮动小窗显示任务状态，帮助任务在切换 App 后继续，无需额外授权。关闭小窗会停止使用此方式。"
                : "当前设备不支持画中画。可以选择其他后台方式。"
        case .systemTask:
            return "向系统申请时间以继续执行当前任务，无需额外授权。是否允许和可运行多久由系统决定；系统取消或结束后台任务时，当前任务会暂停。"
        case .location:
            return "使用定位服务帮助任务在切换 App 后继续，需要允许“使用 App 期间”访问位置。仅在任务运行或后台常驻时使用，不保存或上传坐标；会显示系统定位标志并增加耗电。定位不是使用其他功能的必要条件。"
        }
    }

    private var locationPermissionStatus: String {
        guard let location = background.location else { return "当前无法使用定位。" }
        if !location.servicesEnabled { return "系统定位服务已关闭，请在系统设置中开启。" }
        switch location.authorization {
        case .notDetermined: return "尚未授权。打开定位开关时会请求权限。"
        case .denied: return "未允许访问位置。可在系统设置中修改，不影响其他后台方式。"
        case .restricted: return "系统限制了定位权限，当前无法使用此方式。"
        case .authorizedWhenInUse, .authorizedAlways: return "已允许访问位置；任务运行或后台常驻时才会使用。"
        @unknown default: return "暂时无法确认定位权限，请在系统设置中查看。"
        }
    }
}
