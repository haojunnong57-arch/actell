// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import BackgroundTasks
import Observation

enum NCMControlError: Error { case unavailable(String), stopped }

@MainActor @Observable final class PairingFlow: NSObject, @preconcurrency NetServiceDelegate {
    static let shared = PairingFlow()
    static let taskID = (Bundle.main.bundleIdentifier ?? "com.ja1chen.PhoneAgent.NCMProbe") + ".pairing"
    private let pairing = RemotePairingSession()
    private let backend = NativeDeveloperServices()
    private let client = NCMProbeClient()
    private let store = RemotePairRecordStore(url: URL.applicationSupportDirectory.appending(path: "RemotePairing/identity.plist"))
    private var service: NetService?
    private var generation = UUID()
    private(set) var controlSessionID = UUID()
    private var agentOwner: UUID?
    private var connectionUsers: Set<UUID> = []
    private var agentRuns: Set<UUID> = []
    private var agentQueue: [UUID] = []
    private(set) var isBackground = false
    var agentReserved: Bool { !agentRuns.isEmpty || agentOwner != nil }
    private var registeredBackgroundTask = false
    private var mediaStarted = false
    private var job: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatEpoch = UUID()
    private var maintenanceBusy = false
    private var backgroundTask: BGTask?
    private var operationLease: ExecutionTransitionLease?
    private(set) var capturing = false
    var running = false
    var pairingActive = false
    var lastFailure: String?
    var ready = false
    var hasRecord = false
    var pin: String?
    var message = "先开始系统配对；已有身份会自动保留"
    var image: UIImage?
    var statusText: String {
        if pairingActive { return message }
        if running { return ready ? "正在处理操作" : "正在连接 ESP32" }
        if ready {
            if lastFailure != nil { return "点击准备失败，截图仍可用" }
            return image == nil ? "截图与点击可用" : "截图已收到"
        }
        if hasRecord { return lastFailure == nil ? "已配对，可连接 ESP32" : "连接未成功，请重新连接" }
        return message
    }
    override init() { super.init(); hasRecord = store.exists }

    func registerBackgroundTask() {
        guard !registeredBackgroundTask else { return }
        if #available(iOS 26.0, *) {
            registeredBackgroundTask = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskID, using: .main) { task in
                Task { @MainActor in
                    guard let continued = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                    Self.shared.begin(continued)
                }
            }
        }
    }
    func startPairing() {
        guard !running else { return }
        hasRecord = store.exists
        guard !hasRecord else { message = "身份已保留，直接验证 ESP32 连接；无需重新配对"; return }
        guard registeredBackgroundTask else { message = "系统配对后台任务未注册，请重新打开 App"; return }
        guard #available(iOS 26.0, *) else { message = "系统交互配对需要 iOS 26 或更新版本的持续后台任务"; return }
        generation = UUID(); running = true; pairingActive = true; message = "正在申请配对后台任务，请等待入口就绪"
        let request = BGContinuedProcessingTaskRequest(identifier: Self.taskID, title: "PhoneAgent 配对", subtitle: "在系统设置中完成授权")
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) }
        catch { running = false; pairingActive = false; message = "系统未批准后台任务，请保持 App 在前台后重试" }
    }
    @available(iOS 26.0, *) private func begin(_ continued: BGContinuedProcessingTask) {
        guard pairingActive, running, job == nil else { continued.setTaskCompleted(success: false); return }
        let epoch = generation
        backgroundTask = continued
        continued.progress.totalUnitCount = 4; continued.progress.completedUnitCount = 1
        continued.expirationHandler = { Task { @MainActor in
            guard Self.shared.generation == epoch else { return }
            Self.shared.cancel()
        } }
        job = Task { @MainActor in
            var success = false
            defer { if generation == epoch { finishPairing(success: success) } }
            do {
                try await pairing.pair(authorized: true, persist: { record in
                    guard self.generation == epoch else { throw CancellationError() }
                    try self.store.save(record); self.hasRecord = true
                }, update: { update in
                    guard self.generation == epoch else { throw CancellationError() }
                    switch update {
                    case .listening(let advertisement):
                        let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: advertisement.identifier, port: Int32(advertisement.port))
                        service.delegate = self
                        guard service.setTXTRecord(NetService.data(fromTXTRecord: advertisement.txt.mapValues { Data($0.utf8) })) else { throw NativeBackendError.malformedEvent }
                        self.service = service; service.publish()
                        self.message = "正在发布系统配对入口"
                    case .code(let value): self.pin = value; self.message = "在系统配对页面输入此 PIN"; continued.progress.completedUnitCount = 2
                    case .persisted(let committed): self.message = committed ? "身份已保存，正在确认配对完成" : "已验证手机身份，正在保存配对"; continued.progress.completedUnitCount = 3
                    case .completed: self.message = "配对成功。回到 App，点击验证 ESP32 连接"; continued.progress.completedUnitCount = 4
                    }
                })
                success = true
            } catch is CancellationError { guard generation == epoch else { return }; message = "配对已停止；已写入的身份会保留" }
            catch { guard generation == epoch else { return }; message = "配对未完成。检查本地网络权限和系统配对页面；已写入的身份会保留" }
        }
    }
    func netServiceDidPublish(_ sender: NetService) {
        guard service === sender else { return }
        message = "打开设置 → 隐私与安全性 → 开发者模式，选择与 PhoneAgent NCM 配对"
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard service === sender else { return }
        cancel(); message = "配对入口发布失败，请检查本地网络权限后重试"
    }
    private func finishPairing(success: Bool) {
        service?.stop(); service = nil; pairing.close(); pin = nil
        backgroundTask?.setTaskCompleted(success: success); backgroundTask = nil
        running = false; pairingActive = false; job = nil; hasRecord = store.exists
    }
    func cancel() {
        operationLease?.complete(success: false); operationLease = nil
        stopHeartbeat()
        generation = UUID(); controlSessionID = UUID(); agentOwner = nil; agentRuns.removeAll(); agentQueue.removeAll()
        job?.cancel(); pairing.close(); service?.stop(); service = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
        if pairingActive { finishPairing(success: false) }
        backend.close(); client.cancel(); ready = false; mediaStarted = false; image = nil; running = false; capturing = false; job = nil
        message = "已停止；已保存的身份会保留"
    }
    func background() {
        isBackground = true
        // App visibility does not revoke an authenticated device session.
        // Active runs own their system execution leases; settings operations
        // own a finite transition lease. Explicit stop/expiry/transport loss
        // still closes the session, without replaying input after reconnect.
    }
    func resume() {
        isBackground = false
        hasRecord = store.exists
        if hasRecord, !pairingActive, !running, !ready { verify() }
    }
    func verify() {
        guard !running, !agentReserved, store.exists else { return }
        let previousMaintenance = heartbeatTask
        stopHeartbeat()
        generation = UUID(); controlSessionID = UUID(); let epoch = generation
        running = true; ready = false; mediaStarted = false; image = nil; lastFailure = nil; backend.close()
        beginOperationLease(epoch: epoch)
        job = Task { @MainActor in
            defer { if generation == epoch { finishOperationLease(); running = false; job = nil } }
            do {
                await previousMaintenance?.value
                try Task.checkCancellation()
                guard generation == epoch else { return }
                var identity = try store.load().identity(); defer { identity.clearSeed() }
                message = "正在从 ESP32 发现手机 RemotePairing 服务"
                var discovery = try await client.request(.discoverIPv4)
                if discovery.endpoints?.contains(where: { $0.service == "remotepairing" }) != true {
                    discovery = try await client.request(.discoverIPv6)
                }
                try Task.checkCancellation()
                guard generation == epoch else { return }
                guard let endpoint = discovery.endpoints?.first(where: { $0.service == "remotepairing" }) else {
                    message = "ESP32 未发现手机 RemotePairing 服务。配对身份已保留，下一步需要定位 NCM 服务发现问题"; return
                }
                message = "正在经 ESP32 验证身份并建立开发者隧道"
                try await backend.connect(identity: identity, authorization: ExistingSessionAuthorization(verifyExistingIdentity: true, screen: true, screenVideoStream: true, input: true), discovery: discovery, endpoint: endpoint)
                try await backend.checkDeveloperReadiness()
                try Task.checkCancellation(); guard generation == epoch else { return }
                ready = true; startHeartbeat(); message = "ESP32 认证、开发者隧道和服务检查成功，可测试截图与输入"
            } catch { guard generation == epoch else { return }; backend.close(); message = failure(error); lastFailure = message }
        }
    }
    func capture() { operation(capturing: true) {
        let png = try await self.backend.capturePNG()
        try Task.checkCancellation()
        guard let image = UIImage(data: png) else { throw NativeBackendError.malformedEvent }
        self.image = image; self.message = "已收到手机截图"
    } }
    func tapCenter() { operation {
        if !self.mediaStarted {
            try await self.backend.startTouchMedia()
            try Task.checkCancellation()
            self.mediaStarted = true
        }
        _ = try await self.backend.tapDelivery(x: 32768, y: 32768)
        try Task.checkCancellation()
        self.message = "已发送屏幕中心点击，请观察手机确认实际效果"
    } }
    private func operation(capturing: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        guard ready, !running, !agentReserved else { return }
        generation = UUID(); let epoch = generation
        running = true; self.capturing = capturing
        beginOperationLease(epoch: epoch)
        job = Task { @MainActor in
            defer { if generation == epoch { finishOperationLease(); running = false; self.capturing = false; job = nil } }
            do {
                // User requests queue behind an in-flight keepalive; the UI only
                // becomes busy after a user operation, never for maintenance.
                while maintenanceBusy {
                    try await Task.sleep(for: .milliseconds(10))
                    guard generation == epoch else { return }
                }
                try Task.checkCancellation()
                guard generation == epoch, ready else { return }
                try await action()
                lastFailure = nil
            }
            catch {
                guard generation == epoch else { return }
                if case NativeBackendError.touchPreparationFailure = error {
                    mediaStarted = false
                    message = failure(error) + "。本次未发送点击，截图连接保留"
                    lastFailure = message
                } else {
                    stopHeartbeat(); ready = false; mediaStarted = false; backend.close()
                    message = failure(error) + "；请重新连接 ESP32"; lastFailure = message
                }
            }
        }
    }
    /// A task pins one authenticated session. Reconnect never silently substitutes
    /// another generation; diagnostics and task traffic share the operation gate.
    func agentOperation<T>(owner: UUID, session: UUID, action: (NativeDeveloperServices) async throws -> T) async throws -> T {
        guard ready, controlSessionID == session else { throw NCMControlError.unavailable("ESP32 控制未连接，请在设置 → 手机操控 → ESP32 控制中连接") }
        if agentOwner != owner {
            if !agentQueue.contains(owner) { agentQueue.append(owner) }
            defer { agentQueue.removeAll { $0 == owner } }
            while running || agentOwner != nil || agentQueue.first != owner {
                try Task.checkCancellation()
                guard ready, controlSessionID == session, agentRuns.contains(owner) else { throw NCMControlError.stopped }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        try Task.checkCancellation()
        guard ready, controlSessionID == session, agentRuns.contains(owner) else { throw NCMControlError.stopped }
        agentOwner = owner
        running = true
        defer { if controlSessionID == session { running = false } }
        do {
            while maintenanceBusy {
                try await Task.sleep(for: .milliseconds(10))
                guard ready, controlSessionID == session, agentOwner == owner else { throw NCMControlError.stopped }
            }
            try Task.checkCancellation()
            guard ready, controlSessionID == session, agentOwner == owner else { throw NCMControlError.stopped }
            let value = try await action(backend)
            try Task.checkCancellation()
            guard ready, controlSessionID == session, agentOwner == owner else { throw NCMControlError.stopped }
            return value
        } catch {
            guard controlSessionID == session else { throw NCMControlError.stopped }
            if case NativeBackendError.touchPreparationFailure = error {
                mediaStarted = false; message = failure(error) + "。本次未发送输入，截图连接保留"; lastFailure = message
                throw NCMControlError.unavailable(message)
            }
            if error is CancellationError || (error as? NCMControlError) != nil {
                cancel(); throw NCMControlError.stopped
            }
            message = failure(error) + "；请重新连接 ESP32"; lastFailure = message
            stopHeartbeat(); ready = false; mediaStarted = false; backend.close()
            invalidateAgentSession(); running = false
            throw NCMControlError.unavailable(message)
        }
    }
    func prepareAgentInput(_ services: NativeDeveloperServices) async throws {
        if !mediaStarted {
            try await services.startTouchMedia()
            try Task.checkCancellation()
            mediaStarted = true
        }
    }
    private func invalidateAgentSession() {
        controlSessionID = UUID(); agentOwner = nil
        agentRuns.removeAll(); agentQueue.removeAll()
    }
    func retainConnection(owner: UUID) { connectionUsers.insert(owner) }
    func releaseConnection(owner: UUID) {
        connectionUsers.remove(owner)
    }
    func registerAgent(owner: UUID, session: UUID) {
        guard ready, controlSessionID == session else { return }
        agentRuns.insert(owner)
    }
    func releaseAgent(owner: UUID, session: UUID) {
        guard controlSessionID == session else { return }
        agentRuns.remove(owner); agentQueue.removeAll { $0 == owner }
        guard agentOwner == owner else {
            return
        }
        // Cancellation during an operation revokes transport; normal completion
        // only releases ownership, retaining the control connection in either scene.
        if running { cancel() } else {
            agentOwner = nil
        }
    }
    private func beginOperationLease(epoch: UUID) {
        finishOperationLease()
        let lease = ExecutionTransitionLease()
        lease.expirationHandler = { [weak self] in
            guard let self, self.generation == epoch else { return }
            self.cancel()
            self.message = "系统后台执行时间已到期，当前操作已停止；配对身份保留"
            self.lastFailure = self.message
        }
        lease.begin(); operationLease = lease
    }
    private func finishOperationLease() {
        operationLease?.complete(success: true); operationLease = nil
    }
    private func stopHeartbeat() {
        heartbeatEpoch = UUID(); heartbeatTask?.cancel(); heartbeatTask = nil; maintenanceBusy = false
    }
    /// Read-only service traffic keeps the ESP32's 60-second relay idle lease alive.
    /// Shares the operation gate; never overlaps a screenshot or touch request.
    private func startHeartbeat() {
        stopHeartbeat(); let epoch = heartbeatEpoch
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self, self.heartbeatEpoch == epoch, self.ready else { return }
                if self.running { continue }
                self.maintenanceBusy = true
                do {
                    try await self.backend.checkDeveloperReadiness()
                    guard self.heartbeatEpoch == epoch else { return }
                    self.maintenanceBusy = false
                } catch {
                    guard self.heartbeatEpoch == epoch else { return }
                    self.maintenanceBusy = false; self.ready = false; self.mediaStarted = false
                    self.backend.close(); self.invalidateAgentSession()
                    self.message = "连接保活失败：" + self.failure(error) + "；请重新连接 ESP32"
                    self.lastFailure = self.message
                    return
                }
            }
        }
    }
    private func failure(_ error: Error) -> String {
        if case NativeBackendError.touchPreparationFailure(let stage, let cause) = error {
            let labels: [UInt32: String] = [10:"视频服务可用性", 11:"触控服务可用性", 13:"视频接收端口", 14:"连接视频服务", 15:"请求视频会话", 16:"解析视频协商回复", 17:"接收有效视频包", 18:"连接触控服务"]
            let reasons: [UInt32: String] = [1:"协议错误", 2:"超时", 3:"参数无效", 4:"服务缺失", 5:"尚未就绪"]
            return "触控准备失败：\(labels[stage] ?? "视频准备")，\(reasons[cause] ?? "原因 \(cause)")"
        }
        if case NativeBackendError.protocolFailure(let stage, let cause) = error {
            if stage == 19 || stage == 20 {
                return "截图\(stage == 19 ? "服务连接" : "请求与接收")失败（\(cause == 2 ? "超时" : "协议错误")）；身份已保留"
            }
            let labels: [UInt32: String] = [1:"配对身份", 2:"ESP32 转发连接", 3:"手机身份认证", 4:"动态隧道入口", 5:"隧道 TLS", 6:"远程服务列表", 7:"开发者模式", 8:"开发者镜像", 9:"截图", 10:"屏幕视频会话", 11:"点击发送", 12:"会话关闭"]
            let reasons: [UInt32: String] = [1:"协议错误", 2:"超时", 3:"参数无效", 4:"服务缺失", 5:"尚未就绪", 6:"屏幕会话失效", 7:"发送结果未知"]
            return "\(labels[stage] ?? "协议")失败（\(reasons[cause] ?? "原因 \(cause)")）；身份已保留"
        }
        if error is CancellationError { return "已停止，身份已保留" }
        return "连接失败，请检查 ESP32 固件、NCM 接口和本地网络权限；身份已保留"
    }
    #if DEBUG
    private var backgroundProbeStarted = false
    /// Opt-in real-device acceptance probe. Uses the production bridge and
    /// scheduler; logs state/dimensions. The additional input-probe flag saves
    /// three local verification images for the reversible Home-screen swipe.
    func runBackgroundProbeIfRequested(pip: StatusPiPController? = nil) async {
        guard (ProcessInfo.processInfo.arguments.contains("--ncm-background-probe") || pip != nil), !backgroundProbeStarted else { return }
        backgroundProbeStarted = true
        let url = URL.documentsDirectory.appending(path: "ncm-background-probe.txt")
        var lines: [String] = []
        func record(_ value: String) {
            lines.append("\(Date().ISO8601Format()) \(value)")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        record("start paired=\(hasRecord)")
        if !ready && !running { verify() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !ready && running && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard ready else { record("connect failed: \(message)"); return }
        let systemScheduler = ContinuedProcessingScheduler()
        systemScheduler.diagnostic = { record($0) }
        let scheduler: any RunBackgroundScheduler = pip == nil
            ? systemScheduler : PiPBackedRunScheduler(primary: ForegroundOnlyScheduler())
        let identifier = (Bundle.main.bundleIdentifier ?? "com.ja1chen.PhoneAgent") + ".backgroundRun." + UUID().uuidString
        var lease: (any RunBackgroundLease)?
        var expired = false
        var activeBridge: NCMDeviceBridge?
        do {
            try scheduler.submit(identifier: identifier, launched: { grant in
                lease = grant
                grant.expirationHandler = { expired = true; activeBridge?.cancelTransport(); record("execution expired") }
            })
            if pip != nil { record("PiP-only acceptance active=\(pip?.active == true); combined lease=\(lease != nil); no system execution lease requested") }
            let bridge = try NCMDeviceBridge(flow: self)
            activeBridge = bridge
            defer { lease?.complete(success: !expired); scheduler.cancel(identifier: identifier) }
            do {
                let frame = try await bridge.screenshot()
                record("foreground capture \(frame.width)x\(frame.height) bytes=\(frame.png.count); background switch window=15s")
                UIApplication.shared.perform(NSSelectorFromString("suspend"))
                for step in 1...3 {
                    try await Task.sleep(for: .seconds(15))
                    guard !expired else { throw AppError.stopped }
                    record("readiness \(step) start background=\(isBackground) pip=\(pip?.active == true)")
                    while maintenanceBusy { try await Task.sleep(for: .milliseconds(10)) }
                    running = true
                    do { try await backend.checkDeveloperReadiness(); running = false }
                    catch { running = false; throw error }
                    record("readiness \(step) ok")
                    let start = ContinuousClock.now
                    let frame = try await bridge.screenshot()
                    record("capture \(step) background=\(isBackground) ready=\(ready) \(frame.width)x\(frame.height) bytes=\(frame.png.count) elapsed=\(start.duration(to: .now))")
                    lease?.report(completed: step, subtitle: "后台截图验证 \(step)/3")
                    if step == 1 && ProcessInfo.processInfo.arguments.contains("--ncm-background-input-probe") {
                        try frame.png.write(to: URL.documentsDirectory.appending(path: "ncm-input-before.png"))
                        try await bridge.authorizeTaskInput(imageID: frame.id)
                        try await bridge.drag(fromX: 52428, fromY: 32768, toX: 13107, toY: 32768, durationMS: 300, imageID: frame.id)
                        record("background swipe-left reports written")
                        lease?.report(completed: step + 1, subtitle: "后台滑动已发送，正在验证实际画面")
                        try await Task.sleep(for: .seconds(1))
                        let changed = try await bridge.screenshot()
                        try changed.png.write(to: URL.documentsDirectory.appending(path: "ncm-input-after.png"))
                        lease?.report(completed: step + 2, subtitle: "已收到滑动后的截图，正在恢复桌面")
                        try await bridge.authorizeTaskInput(imageID: changed.id)
                        try await bridge.drag(fromX: 13107, fromY: 32768, toX: 52428, toY: 32768, durationMS: 300, imageID: changed.id)
                        record("background swipe-right reports written")
                        lease?.report(completed: step + 3, subtitle: "已发送恢复滑动，正在验证桌面")
                        try await Task.sleep(for: .seconds(1))
                        let restored = try await bridge.screenshot()
                        try restored.png.write(to: URL.documentsDirectory.appending(path: "ncm-input-restored.png"))
                        record("background swipe verification images saved")
                        record("complete"); break
                    }
                }
                record("complete")
            } catch { record("capture failed background=\(isBackground): \(message); \(error)") }
            await bridge.stop()
        } catch { record("probe failed: \(error)") }
    }
    #endif
}

struct PairingSection: View {
    @State private var flow = PairingFlow.shared
    let showTouchTest: () -> Void
    private var stateText: String {
        if flow.pairingActive { return "配对中" }
        if flow.ready { return "已连接" }
        if flow.running { return "连接中" }
        return flow.hasRecord ? "未连接" : "未配对"
    }
    private var showsDetail: Bool {
        (flow.running && !flow.ready) || flow.lastFailure != nil ||
        (!flow.hasRecord && flow.message != "先开始系统配对；已有身份会自动保留")
    }
    var body: some View {
        Section {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(stateText).foregroundStyle(flow.ready ? .green : .secondary)
                        if flow.running && !flow.ready { ProgressView().controlSize(.small) }
                    }
                    if showsDetail {
                        Text(flow.lastFailure ?? flow.statusText)
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("pairingResult")
                    }
                    if let pin = flow.pin {
                        Text(pin).font(.title.monospacedDigit())
                            .accessibilityIdentifier("pairingPIN")
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if flow.ready || (!flow.running && !flow.agentReserved) {
                        Button(flow.ready ? "重新连接" : flow.hasRecord ? "连接" : "配对") {
                            if flow.hasRecord { flow.verify() }
                            else { flow.startPairing() }
                        }.disabled(flow.running || flow.agentReserved)
                    }
                    if flow.running || flow.ready || flow.agentReserved {
                        Button("停止") { flow.cancel() }
                    }
                }.buttonStyle(.bordered)
            }
        }
        if flow.ready {
            Section("服务验证") {
                Button { flow.capture() } label: {
                    HStack {
                        Text(flow.capturing ? "正在获取截图" : "获取截图")
                        if flow.capturing { ProgressView().controlSize(.small) }
                    }
                }.disabled(flow.running || flow.agentReserved)
                Button("点击验证", action: showTouchTest).disabled(flow.running || flow.agentReserved)
            }
            if let image = flow.image {
                Section("截图") {
                    Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("手机截图")
                }
            }
        }
    }
}

/// The counter is changed only by UIKit/SwiftUI delivering a real button action,
/// never by an HID send acknowledgement. Keep this page foreground during test.
struct TouchVerificationView: View {
    let flow: PairingFlow
    @Environment(\.dismiss) private var dismiss
    @State private var count = 0
    @State private var baseline = 0
    @State private var testing = false
    @State private var result = "测试时不要用手触碰中央按钮"
    @State private var task: Task<Void, Never>?
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            Button { count += 1 } label: {
                VStack {
                    Text("中央触摸目标").font(.title2)
                    Text("收到触摸：\(count)").font(.title.monospacedDigit())
                }.frame(width: 260, height: 160)
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("touchVerificationTarget")
            VStack {
                HStack { Text("真实点击验证").font(.headline); Spacer(); Button("关闭") { dismiss() }.disabled(testing) }
                Spacer()
                Text(result).multilineTextAlignment(.center).accessibilityIdentifier("touchVerificationResult")
                Text(flow.message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !flow.ready {
                    Button("重新连接 ESP32") { flow.verify() }.disabled(flow.running || flow.agentReserved)
                }
                if testing { ProgressView() }
                Button("经 ESP32 点击中央目标") { test() }.buttonStyle(.bordered).disabled(testing || !flow.ready || flow.running || flow.agentReserved)
                Text("保持此页打开。计数增加才说明界面收到触摸；单纯报告发送成功不计入。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding()
        }
        .interactiveDismissDisabled()
        .onDisappear { task?.cancel(); if testing { flow.cancel() } }
    }
    private func test() {
        baseline = count; testing = true; result = "准备视频会话并发送一次中央点击，请勿手动触摸"
        task = Task { @MainActor in
            defer { testing = false; task = nil }
            flow.tapCenter()
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    if !flow.running {
                        try await Task.sleep(for: .milliseconds(500))
                        result = count > baseline ? "验证通过：测试页面实际收到触摸，计数增加" : "未确认实际点击：计数未变化。\n\(flow.message)"
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                flow.cancel()
                result = "等待超时，未确认实际点击；不会自动重发"
            } catch { result = "测试已停止" }
        }
    }
}
