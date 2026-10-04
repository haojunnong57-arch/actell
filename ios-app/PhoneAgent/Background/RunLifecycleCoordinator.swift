// Selectively ported from feature/background-runs @ 2509d7098fc8a3af4c62bd8fc20e911df4aa4933.
// Integration selects either a capture context or a system processing lease.
import Foundation
import Combine

/// A delivered execution capability, never a successful scheduler submission.
/// The source is either SCK/USB health or a handler-delivered system task.
@MainActor protocol RunBackgroundLease: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func report(completed: Int, subtitle: String)
    func complete(success: Bool)
}
@MainActor protocol RunBackgroundScheduler {
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void,
                failed: @escaping @MainActor () -> Void) throws
    func cancel(identifier: String)
}
extension RunBackgroundScheduler {
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void,
                failed: @escaping @MainActor () -> Void) throws { try submit(identifier: identifier, launched: launched) }
}
@MainActor struct ForegroundOnlyScheduler: RunBackgroundScheduler {
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        throw AppError.unavailable("当前系统不支持后台片段；只在前台继续")
    }
    func cancel(identifier: String) {}
}

struct RunCheckpoint: Codable, Equatable {
    enum Phase: String, Codable { case running, waitingApproval, paused, stopped, completed }
    enum Delivery: String, Codable { case prepared, dispatching, acknowledged, observedResult, outcomeUnknown, failed }
    struct Tool: Codable, Equatable, Sendable {
        let callID: String
        let name: String
        /// Whitelisted numeric arguments plus hashes; no purpose, text, images or credentials.
        let parameterSummary: String
        let argumentDigest: String
        var delivery: Delivery = .prepared
    }
    let runID: UUID
    let conversationID: UUID
    let generation: UUID
    var segment = 0
    var segmentID: String?
    var phase: Phase = .running
    var tools: [Tool] = []
    var pendingApproval: String?
    var lastConfirmedStep: String?
    var milestones: Set<String> = []
    var message = ""
}

@MainActor protocol RunCheckpointStorage {
    func load() throws -> RunCheckpoint?
    func save(_ checkpoint: RunCheckpoint) throws
}
@MainActor final class RunCheckpointStore: RunCheckpointStorage {
    private let file: URL
    init(directory: URL? = nil) throws {
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PhoneAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excludedRoot = root
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try excludedRoot.setResourceValues(attributes)
        file = root.appendingPathComponent("run-checkpoint-v1.json")
    }
    func load() throws -> RunCheckpoint? {
        // Preserve the old SCK-only journal when upgrading. Recovery never
        // restores execution, and the old file is retained for inspection.
        let legacy = file.deletingLastPathComponent().appendingPathComponent("usb-run-checkpoint-v1.json")
        let source = FileManager.default.fileExists(atPath: file.path) ? file : legacy
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        return try JSONDecoder().decode(RunCheckpoint.self, from: Data(contentsOf: source))
    }
    func save(_ checkpoint: RunCheckpoint) throws {
        // This route stops on lock. The journal excludes text, screenshots and secrets.
        // Preserve full file protection; do not expand lock-screen access.
        try JSONEncoder().encode(checkpoint).write(to: file, options: [.atomic, .completeFileProtection])
    }
}
@MainActor final class MemoryRunCheckpointStore: RunCheckpointStorage {
    var value: RunCheckpoint?
    func load() throws -> RunCheckpoint? { value }
    func save(_ checkpoint: RunCheckpoint) throws { value = checkpoint }
}

/// Owned by the App's model, independent of any conversation View's lifetime.
/// All lifecycle/journal mutations are serialized on MainActor; no await lies
/// between a durable dispatching transition and returning dispatch permission.
@MainActor final class RunLifecycleCoordinator: ObservableObject {
    @Published private(set) var checkpoint: RunCheckpoint?
    @Published private(set) var backgroundStatus = "后台需有效采集资格或系统实际授予的有限片段"
    private(set) var foreground = true
    private(set) var hasLease = false
    var canAwaitApprovalInBackground: Bool { checkpoint?.phase == .waitingApproval && activeToolBackgroundCapable }
    var onPause: ((String) -> Void)?
    private let scheduler: any RunBackgroundScheduler
    private let storage: any RunCheckpointStorage
    private let identifierPrefix: String
    private let now: () -> Date
    private let inactivityTimeout: TimeInterval
    private var lastActivity = Date()
    private var lease: (any RunBackgroundLease)?
    private var activeToolBackgroundCapable = true
    private var watchdog: Task<Void, Never>?
    private var storageHealthy = true
    private var ownsRun = false

    init(scheduler: any RunBackgroundScheduler, storage: any RunCheckpointStorage,
         identifierPrefix: String = (Bundle.main.bundleIdentifier ?? "com.ja1chen.PhoneAgent") + ".backgroundRun",
         inactivityTimeout: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
        self.scheduler = scheduler; self.storage = storage; self.identifierPrefix = identifierPrefix
        self.inactivityTimeout = max(1, inactivityTimeout); self.now = now
        do {
            checkpoint = try storage.load()
            if var saved = checkpoint {
                // Process death loses every lease/continuation. Recovery is a
                // review checkpoint, never an executable queue of old actions.
                for i in saved.tools.indices where saved.tools[i].delivery == .dispatching { saved.tools[i].delivery = .outcomeUnknown }
                if saved.phase == .running { saved.phase = .paused }
                if let id = saved.segmentID, id.hasPrefix(identifierPrefix + ".") { scheduler.cancel(identifier: id) }
                saved.segmentID = nil
                if saved.phase == .paused || saved.phase == .waitingApproval {
                    if saved.tools.contains(where: { $0.delivery == .outcomeUnknown }) {
                        saved.message = "上次有已发送动作结果未知；请先核对设备，旧动作不会重放"
                    } else if saved.phase == .waitingApproval {
                        saved.message = "上次有待批准动作；原审批不能直接恢复，请重新获取截图"
                    } else {
                        saved.message = "上次执行已挂起；请核对设备并重新获取截图，旧动作不会重放"
                    }
                    backgroundStatus = saved.message
                }
                checkpoint = saved; try storage.save(saved)
            }
        } catch { storageHealthy = false; backgroundStatus = "检查点无法读写；原文件保留，执行已禁用" }
    }

    func begin(identity: RunIdentity, generation: UUID) throws {
        guard foreground, storageHealthy, !ownsRun else { throw AppError.stopped }
        activeToolBackgroundCapable = true
        checkpoint = RunCheckpoint(runID: identity.runID, conversationID: identity.conversationID, generation: generation)
        try persist(); ownsRun = true; requestSegment()
        guard storageHealthy else { throw AppError.unavailable("检查点保存失败") }
        lastActivity = now()
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self else { return }
                self.checkInactivity()
            }
        }
    }
    private func requestSegment() {
        guard foreground, checkpoint?.phase == .running else { return }
        checkpoint?.segment += 1
        let id = identifierPrefix + "." + UUID().uuidString
        checkpoint?.segmentID = id
        backgroundStatus = "检查本次后台执行资格"
        do {
            try persist()
            try scheduler.submit(identifier: id, launched: { [weak self] lease in
                guard let self else { lease.complete(success: false); return }
                self.accept(lease, identifier: id)
            }, failed: { [weak self] in self?.submissionRejected(identifier: id) })
        } catch {
            scheduler.cancel(identifier: id)
            if checkpoint?.segmentID == id { checkpoint?.segmentID = nil }
            backgroundStatus = "后台执行资格未获准；本轮仅前台继续，离开即暂停"
            saveOrPause()
        }
    }
    private func submissionRejected(identifier: String) {
        guard ownsRun, checkpoint?.phase == .running, checkpoint?.segmentID == identifier, !hasLease else { return }
        scheduler.cancel(identifier: identifier); checkpoint?.segmentID = nil
        backgroundStatus = "后台申请未获准；本轮仅前台继续，离开即暂停"
        saveOrPause()
        if !foreground { pause("系统未授予后台片段；已暂停，旧动作不会重放") }
    }
    private func accept(_ incoming: any RunBackgroundLease, identifier: String) {
        if let lease, lease === incoming { return }
        guard checkpoint?.phase == .running, checkpoint?.segmentID == identifier, lease == nil else {
            incoming.complete(success: false); return
        }
        lease = incoming; hasLease = true
        incoming.expirationHandler = { [weak self] in
            guard self?.checkpoint?.segmentID == identifier, self?.hasLease == true else { return }
            self?.pause("后台执行资格失效或到期；已暂停，请核对设备后手动继续")
        }
        backgroundStatus = "有限后台资格有效；设备工具仍需独立校验，真机能力待验证"
        incoming.report(completed: checkpoint?.milestones.count ?? 0, subtitle: "等待实际模型响应或工具结果；总步骤未知")
    }
    func setForeground(_ active: Bool) {
        foreground = active
        guard !active, checkpoint?.phase == .running else { return }
        if !hasLease { pause("离开前台时尚无有效后台片段；已暂停，需手动继续") }
        else if !activeToolBackgroundCapable { pause("当前设备工具尚未验证后台能力；已暂停，请返回前台核对") }
    }
    func requireExecution(generation: UUID, backgroundCapable: Bool) throws {
        guard ownsRun, checkpoint?.generation == generation, checkpoint?.phase == .running, storageHealthy else { throw AppError.stopped }
        guard foreground || (hasLease && backgroundCapable) else {
            pause("此步骤需要前台或有效后台能力；已暂停，未自动重发")
            throw AppError.stopped
        }
    }
    func prepare(_ tool: RunCheckpoint.Tool, generation: UUID, backgroundCapable: Bool) throws {
        try requireExecution(generation: generation, backgroundCapable: backgroundCapable)
        guard checkpoint?.tools.contains(where: { $0.callID == tool.callID }) == false else { throw AppError.stopped }
        activeToolBackgroundCapable = backgroundCapable
        checkpoint?.tools.append(tool)
        try persistOrPause()
    }
    func dispatch(callID: String, generation: UUID, backgroundCapable: Bool) throws {
        try requireExecution(generation: generation, backgroundCapable: backgroundCapable)
        guard let index = checkpoint?.tools.firstIndex(where: { $0.callID == callID }), checkpoint?.tools[index].delivery == .prepared else { throw AppError.stopped }
        checkpoint?.tools[index].delivery = .dispatching
        try persistOrPause() // Must succeed before the bridge is called.
    }
    func acknowledge(callID: String, generation: UUID, observation: Bool = false) throws {
        try requireExecution(generation: generation, backgroundCapable: activeToolBackgroundCapable)
        guard let index = checkpoint?.tools.firstIndex(where: { $0.callID == callID }), checkpoint?.tools[index].delivery == .dispatching else { throw AppError.stopped }
        checkpoint?.tools[index].delivery = observation ? .observedResult : .acknowledged
        if observation, let tools = checkpoint?.tools {
            // ObservedResult means a fresh screen was obtained after delivery,
            // not that the intended UI effect has been verified as successful.
            for i in tools.indices where tools[i].delivery == .acknowledged { checkpoint?.tools[i].delivery = .observedResult }
        }
        checkpoint?.lastConfirmedStep = callID; activeToolBackgroundCapable = true
        try persistOrPause()
        activity(generation: generation, milestone: "tool:" + callID)
    }
    func toolFailed(callID: String, generation: UUID) {
        guard ownsRun, checkpoint?.generation == generation, checkpoint?.phase == .running else { return }
        if let i = checkpoint?.tools.firstIndex(where: { $0.callID == callID }), checkpoint?.tools[i].delivery == .dispatching {
            if ["tap", "drag"].contains(checkpoint?.tools[i].name ?? "") {
                checkpoint?.tools[i].delivery = .outcomeUnknown
                pause("工具发送后未得到确认；结果未知，请核对设备，旧动作不会重放")
            } else {
                // Failed observations have no input side effect. Preserve the
                // ordinary tool-error -> model explanation path.
                checkpoint?.tools[i].delivery = .failed
                activeToolBackgroundCapable = true; saveOrPause()
            }
        } else {
            if let i = checkpoint?.tools.firstIndex(where: { $0.callID == callID }), checkpoint?.tools[i].delivery == .prepared {
                checkpoint?.tools[i].delivery = .failed
            }
            activeToolBackgroundCapable = true; saveOrPause()
        }
    }
    func waitForApproval(callID: String, generation: UUID) throws {
        guard ownsRun, checkpoint?.generation == generation, checkpoint?.phase == .running,
              checkpoint?.tools.contains(where: { $0.callID == callID && $0.delivery == .prepared }) == true else { throw AppError.stopped }
        checkpoint?.pendingApproval = callID; checkpoint?.phase = .waitingApproval
        try persistOrPause()
        endSegment(success: true)
        backgroundStatus = "等待前台确认；执行资格已暂停；无输入，需前台确认"
    }
    func resumeApproved(callID: String, digest: String, generation: UUID) throws {
        guard ownsRun, foreground, checkpoint?.generation == generation, checkpoint?.phase == .waitingApproval,
              checkpoint?.pendingApproval == callID,
              checkpoint?.tools.contains(where: { $0.callID == callID && $0.argumentDigest == digest && $0.delivery == .prepared }) == true else { throw AppError.stopped }
        checkpoint?.pendingApproval = nil; checkpoint?.phase = .running
        try persistOrPause(); lastActivity = now(); requestSegment()
    }
    func activity(generation: UUID, milestone: String? = nil) {
        guard ownsRun, checkpoint?.generation == generation, checkpoint?.phase == .running else { return }
        if let milestone, checkpoint?.milestones.contains(milestone) == true { return }
        lastActivity = now()
        if let milestone, checkpoint?.milestones.insert(milestone).inserted == true {
            saveOrPause()
            lease?.report(completed: checkpoint?.milestones.count ?? 0, subtitle: "已收到 \(checkpoint?.milestones.count ?? 0) 个响应或工具结果；总步骤未知")
        }
    }
    func checkInactivity() {
        guard checkpoint?.phase == .running, now().timeIntervalSince(lastActivity) >= inactivityTimeout else { return }
        pause("超过 \(Int(inactivityTimeout)) 秒未收到有效响应；已暂停，请检查网络后手动继续")
    }
    func pause(generation: UUID, message: String) {
        guard ownsRun, checkpoint?.generation == generation else { return }
        pause(message)
    }
    func pause(_ message: String) {
        guard checkpoint?.phase == .running || checkpoint?.phase == .waitingApproval else { return }
        terminate(phase: .paused, message: message, success: false, cancelExecution: true)
    }
    func stop(message: String) {
        guard checkpoint?.phase == .running || checkpoint?.phase == .waitingApproval else { return }
        terminate(phase: .stopped, message: message, success: false)
    }
    func finish(success: Bool) {
        guard checkpoint?.phase == .running else { return }
        terminate(phase: success ? .completed : .paused, message: success ? "运行结束" : "运行中断；请核对后继续", success: success)
    }
    private func terminate(phase: RunCheckpoint.Phase, message: String, success: Bool, cancelExecution: Bool = false) {
        if let tools = checkpoint?.tools {
            for i in tools.indices where tools[i].delivery == .dispatching { checkpoint?.tools[i].delivery = .outcomeUnknown }
        }
        checkpoint?.phase = phase; checkpoint?.message = message
        watchdog?.cancel(); watchdog = nil
        backgroundStatus = message
        if cancelExecution { onPause?(message) }
        try? persist()
        endSegment(success: success)
        ownsRun = false
    }
    private func endSegment(success: Bool) {
        let old = lease; lease = nil; hasLease = false
        if let id = checkpoint?.segmentID { scheduler.cancel(identifier: id) }
        checkpoint?.segmentID = nil
        old?.expirationHandler = nil; old?.complete(success: success)
        try? persist()
    }
    private func persist() throws {
        guard storageHealthy, let checkpoint else { throw AppError.unavailable("检查点不可用") }
        do { try storage.save(checkpoint) }
        catch { storageHealthy = false; throw AppError.unavailable("检查点保存失败；为避免未知动作继续，已停止") }
    }
    private func persistOrPause() throws {
        do { try persist() } catch { pause("检查点保存失败；已暂停，未允许继续发送"); throw error }
    }
    private func saveOrPause() { do { try persistOrPause() } catch {} }
}
