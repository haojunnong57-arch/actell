import SwiftUI

@main @MainActor struct PhoneAgentApp: App {
    @StateObject private var model = PhoneAgentRuntime.shared.model
    @StateObject private var statusPiP = StatusPiPController()
    @AppStorage(BackgroundPlaybackMode.defaultsKey) private var backgroundMode = BackgroundPlaybackMode.defaultMode.rawValue
    @Environment(\.scenePhase) private var scenePhase
    init() { PairingFlow.shared.registerBackgroundTask() }
    var body: some Scene {
        WindowGroup {
            ContentView(model: model, statusPiP: statusPiP, commands: PhoneAgentRuntime.shared.commands)
                .overlay {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ncm-video-geometry-probe") { NCMVideoGeometryProbeView() }
                    else if ProcessInfo.processInfo.arguments.contains("--ncm-tools-probe") { NCMToolsProbeView(statusPiP: statusPiP) }
                    #endif
                }
                .preferredColorScheme(testColorScheme)
                // A covered backing layer supplies AVKit without occupying the UI.
                .background(alignment: .bottom) {
                    StatusSampleBufferView(displayLayer: statusPiP.displayLayer)
                        .frame(width: 320, height: 180)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .task {
                    statusPiP.setBackgroundMode(BackgroundPlaybackMode(rawValue: backgroundMode) ?? .defaultMode)
                    statusPiP.observeTasks(in: model)
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--task-pip-probe") {
                        model.start()
                        for step in 0..<5 {
                            try? await Task.sleep(for: .seconds(10))
                            statusPiP.recordTaskProbe(step: step, running: model.hasBusySessions,
                                liveActivities: model.liveActivities.activeCountForProbe)
                            if step == 0 { UIApplication.shared.perform(NSSelectorFromString("suspend")) }
                        }
                    } else { await PairingFlow.shared.runBackgroundProbeIfRequested() }
                    #endif
                }
                .onChange(of: backgroundMode) { _, value in
                    statusPiP.setBackgroundMode(BackgroundPlaybackMode(rawValue: value) ?? .defaultMode)
                }
                .onChange(of: model.approval?.id) { _, id in
                    #if DEBUG
                    if id != nil { Task { await PhoneAgentRuntime.shared.invokeSiriFixtureIfNeeded(busy: true) } }
                    #endif
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .background { PairingFlow.shared.background() }
                    else if phase == .active { PairingFlow.shared.resume() }
                    model.setScene(phase == .active ? .active : phase == .background ? .background : .inactive)
                    model.setProtectedDataAvailable(UIApplication.shared.isProtectedDataAvailable)
                    // Inactive is a transition, not a request to show PiP.
                    if phase == .active { statusPiP.setForeground(true) }
                    else if phase == .background { statusPiP.setForeground(false) }
                    #if DEBUG
                    if phase == .active { Task { await PhoneAgentRuntime.shared.invokeSiriFixtureIfNeeded(busy: false) } }
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    PairingFlow.shared.applicationWillTerminate()
                    statusPiP.setTaskRunning(false)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                    PairingFlow.shared.cancel()
                    statusPiP.setTaskRunning(false)
                    model.setProtectedDataAvailable(false)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                    model.setProtectedDataAvailable(true)
                }
        }
    }
    private var testColorScheme: ColorScheme? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), arguments.contains("--ui-test-dark") { return .dark }
        if arguments.contains("--ui-testing"), arguments.contains("--ui-test-light") { return .light }
        #endif
        return nil
    }
}

#if DEBUG
/// Explicit read-only screenshot probe. Raw media is saved only for this launch flag.
private struct NCMVideoGeometryProbeView: View {
    @State private var status = "视频截图诊断"
    var body: some View {
        VStack(spacing: 20) { Text("视频截图诊断").font(.title); Text(status) }
            .padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground))
            .task { await run() }
    }
    @MainActor private func run() async {
        let directory = URL.documentsDirectory
        let log = directory.appending(path: "ncm-video-geometry-probe.log")
        var lines: [String] = []
        func record(_ value: String) {
            lines.append(Date().ISO8601Format() + " " + value)
            try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
            NSLog("NCM video probe %@", value)
        }
        let flow = PairingFlow.shared
        record("started")
        if !flow.ready && !flow.running { flow.verify() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !flow.ready && flow.running && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        guard flow.ready else { status = "连接未就绪"; record(flow.lastFailure ?? flow.statusText); return }
        var bridge: NCMDeviceBridge?
        do {
            let control = try NCMDeviceBridge(flow: flow); bridge = control
            for index in 0..<3 {
                let frame = try await control.screenshot()
                try frame.png.write(to: directory.appending(path: "ncm-video-probe-\(index).jpg"))
                if let keyframe = await flow.videoDiagnosticKeyframe() {
                    try keyframe.write(to: directory.appending(path: "ncm-video-probe.hevc"))
                }
                record("screenshot \(index) \(frame.width)x\(frame.height)")
                status = "已截图 \(index+1)/3：\(frame.width) × \(frame.height)"
                try await Task.sleep(for: .milliseconds(1200))
            }
            record("completed")
        } catch { record("failed \(String(describing: error))"); status = "诊断未完成" }
        if let bridge { await bridge.stop() }
    }
}

/// Explicit real-device fixture, no provider calls or user conversation writes.
private struct NCMToolsProbeView: View {
    let statusPiP: StatusPiPController
    @State private var status = "验证准备中"
    var body: some View {
        VStack(spacing: 24) {
            Text("ESP32 工具验证").font(.title)
            Text(status)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground))
        .task { await run() }
    }
    @MainActor private func run() async {
        let url = URL.documentsDirectory.appending(path: "ncm-tools-probe.log")
        var records: [String] = []
        func record(_ value: String) { records.append(Date().ISO8601Format() + " " + value); try? records.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
        let flow = PairingFlow.shared
        statusPiP.setControlProbeRunning(true)
        let scheduler = PiPBackedRunScheduler(primary: ContinuedProcessingScheduler())
        let identifier = (Bundle.main.bundleIdentifier ?? "com.ja1chen.PhoneAgent") + ".backgroundRun." + UUID().uuidString
        var lease: (any RunBackgroundLease)?
        defer { lease?.complete(success: true); scheduler.cancel(identifier: identifier); statusPiP.setControlProbeRunning(false) }
        var expired = false
        do {
            try scheduler.submit(identifier: identifier, launched: { incoming in
                lease = incoming
                incoming.expirationHandler = { expired = true; record("execution expired") }
            })
        } catch { record("execution unavailable"); return }
        record("start")
        if !flow.ready && !flow.running { flow.verify() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !flow.ready && flow.running && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        guard flow.ready else { record("connection not ready"); status = "连接未就绪"; return }
        statusPiP.setControlProbeRunning(true)
        do {
            let bridge = try NCMDeviceBridge(flow: flow)
            defer { Task { await bridge.stop() } }
            let data = try await bridge.installedApplications()
            let apps = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            record("apps count=\(apps.count) notes=\(apps.contains { $0["bundle_id"] as? String == "com.apple.mobilenotes" })")
            var frame = try await bridge.screenshot()
            try await bridge.authorizeTaskInput(imageID: frame.id)
            try await bridge.systemAction(name: "home", text: "", arguments: [], imageID: frame.id)
            record("Home delivery acknowledged")
            try await Task.sleep(for: .seconds(1))
            frame = try await bridge.screenshot()
            try frame.png.write(to: URL.documentsDirectory.appending(path: "ncm-tools-home.png"))
            guard !expired else { throw AppError.stopped }
            try await bridge.authorizeTaskInput(imageID: frame.id)
            try await bridge.systemAction(name: "launch_app", text: "com.apple.mobilenotes", arguments: [], imageID: frame.id)
            record("Notes launch acknowledged")
            try await Task.sleep(for: .seconds(1))
            frame = try await bridge.screenshot()
            let screenURL = URL.documentsDirectory.appending(path: "ncm-tools-screen.png")
            try frame.png.write(to: screenURL)
            record("Notes screenshot ready \(frame.width)x\(frame.height)")
            lease?.report(completed: 3, subtitle: "Home、App 查询和备忘录启动已返回；等待测试操作")
            // Explicit debug-only command fixture. Never read task history,
            // arbitrary typed text, identities or paths from this command file.
            let commandURL = URL.documentsDirectory.appending(path: "ncm-tools-command.json")
            try? FileManager.default.removeItem(at: commandURL)
            var lastID = 0
            let testDeadline = ContinuousClock.now.advanced(by: .seconds(600))
            while ContinuousClock.now < testDeadline && !expired {
                try await Task.sleep(for: .milliseconds(200))
                guard let data = try? Data(contentsOf: commandURL), data.count < 4096,
                      let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = command["id"] as? Int, id > lastID,
                      let action = command["action"] as? String else { continue }
                // Commit consumption before dispatch; lost receipts never replay.
                lastID = id
                if action == "finish" { record("finished"); break }
                if action != "screenshot" {
                    try await bridge.authorizeTaskInput(imageID: frame.id)
                    if action == "tap" {
                        guard let x = command["x"] as? Int, let y = command["y"] as? Int else { throw AppError.invalid("测试坐标缺失") }
                        try await bridge.tap(x: x, y: y, imageID: frame.id)
                    } else if action == "type_text" {
                        try await bridge.systemAction(name: action, text: "ESP32 direct input", arguments: [], imageID: frame.id)
                    } else { throw AppError.invalid("不支持的测试操作") }
                    try await Task.sleep(for: .seconds(1))
                }
                frame = try await bridge.screenshot()
                try frame.png.write(to: screenURL)
                record("command id=\(id) action=\(action) delivered and screenshot received")
                lease?.report(completed: id + 3, subtitle: "备忘录真实操作已返回截图")
            }
            status = "验证完成"
        } catch { status = "验证未完成"; record("failed: " + String(describing: error)) }
    }
}
#endif
