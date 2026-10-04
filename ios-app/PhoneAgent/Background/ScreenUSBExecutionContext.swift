import Foundation

/// Observed transport round-trip health, never inferred from interface presence.
final class USBTransportHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var session = UUID()
    private var pingAt: TimeInterval?
    func begin(_ token: UUID) { lock.withLock { session = token; pingAt = nil } }
    func receivedPing(_ token: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock { if session == token { pingAt = now } }
    }
    func invalidate(_ token: UUID? = nil) {
        lock.withLock { if token == nil || session == token { pingAt = nil } }
    }
    func requireHealthy(now: TimeInterval) throws {
        try lock.withLock {
            guard let pingAt, (0...0.75).contains(now - pingAt) else {
                throw AppError.unavailable("USB 心跳已失效，输入已停止")
            }
        }
    }
    var diagnosticSummary: String {
        lock.withLock { "pingAge=\(pingAt.map { String(format: "%.3fs", ProcessInfo.processInfo.systemUptime - $0) } ?? "none")" }
    }
}

/// A revocable capability checked again at the actual NWConnection enqueue.
/// RunLifecycleCoordinator remains the sole owner of lifecycle and transaction state.
/// This is NOT a grant from BGTaskScheduler and cannot keep a suspended process alive.
final class ScreenUSBExecutionContext: @unchecked Sendable {
    enum Scene: Sendable { case active, inactive, background }
    enum Failure: String, Sendable {
        case captureEnded, firstFrameTimeout, usbHeartbeat
        var message: String {
            switch self {
            case .captureEnded: return "采集会话已结束或改变，输入已停止"
            case .firstFrameTimeout: return "采集启动后 5 秒仍未收到有效画面，输入已停止"
            case .usbHeartbeat: return "USB 心跳超过 750 毫秒未更新，输入已停止"
            }
        }
    }
    struct Observation: Sendable { let revision: UInt64; let after: TimeInterval }
    let backgroundEnabled: Bool
    let epoch: UUID
    private let frames: LatestScreenFrame
    private let health: USBTransportHealth?
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private let firstFrameDeadline: TimeInterval
    private var revoked = false
    private var failure: Failure?
    private var revocationMessage: String?
    private var scene = Scene.active
    private var revision: UInt64 = 0
    private var entered: TimeInterval

    init(frames: LatestScreenFrame, health: USBTransportHealth? = nil, backgroundEnabled: Bool,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        self.frames = frames; self.health = health; self.backgroundEnabled = backgroundEnabled; self.now = now
        epoch = try frames.captureSessionID(); entered = now()
        firstFrameDeadline = now() + 5
        try requireHealthy()
    }
    func setScene(_ next: Scene) {
        lock.withLock {
            guard scene != next else { return }
            scene = next; revision += 1; entered = now()
            if !backgroundEnabled, next != .active { revoked = true }
        }
    }
    func revoke(message: String? = nil) {
        lock.withLock {
            if !revoked { revocationMessage = message }
            revoked = true
        }
    }
    var failureMessage: String? { lock.withLock { failure?.message ?? revocationMessage } }
    var diagnosticSummary: String {
        lock.withLock { "scene=\(scene) revoked=\(revoked) failure=\(failure?.rawValue ?? "none") \(health?.diagnosticSummary ?? "usb=none") \(frames.diagnostics(now: now()).summary)" }
    }
    private func validate() throws {
        guard !revoked else {
            if let failure { throw AppError.unavailable(failure.message) }
            if let revocationMessage { throw AppError.unavailable(revocationMessage) }
            throw AppError.stopped
        }
        var checking = Failure.captureEnded
        do {
            let time = now()
            try frames.requireCaptureSession(epoch)
            // Starting the stream does not imply a sample already arrived.
            // Only the initial empty session gets this bounded startup grace.
            if frames.diagnostics(now: time).accepted == 0 {
                checking = .firstFrameTimeout
                guard time < firstFrameDeadline else { throw AppError.unavailable("采集启动后 5 秒仍未收到有效画面；本轮已停止。\(frames.diagnostics(now: time).summary)") }
            } else {
                // Static content may produce no new samples. Only capture
                // invalidation, not the age of the retained frame, ends this run.
                try frames.requireSession(epoch)
            }
            checking = .usbHeartbeat
            try health?.requireHealthy(now: time)
        } catch {
            revoked = true // A late frame/PING never revives an observed loss.
            failure = checking
            throw AppError.unavailable(checking.message)
        }
    }
    func requireHealthy() throws { try lock.withLock { try validate() } }
    func requireForegroundApproval() throws {
        try lock.withLock {
            try validate()
            guard scene == .active else { throw AppError.stopped }
        }
    }
    // Snapshot metadata remains available to callers, but no longer grants or
    // rejects input based on the foreground app or a screen transition.
    func observation() throws -> Observation? {
        try lock.withLock {
            try validate()
            return Observation(revision: revision, after: 0)
        }
    }
    func captureObservation() throws -> Observation? {
        try lock.withLock {
            try validate()
            guard scene == .active || (backgroundEnabled && scene == .background) else { return nil }
            return Observation(revision: revision, after: scene == .background ? entered + 0.2 : 0)
        }
    }
    func enqueue(observation: Observation? = nil, sequence: UInt64? = nil, _ send: () -> Void) throws {
        try lock.withLock {
            try validate()
            guard health != nil else { throw AppError.unavailable("只读采集不能授权 USB 输入") }
            // Only revocation/session loss is serialized with enqueue. A new
            // frame or app transition does not revoke a live task capability.
            try frames.withSession(epoch, send)
        }
    }
}

final class USBInputPermit: @unchecked Sendable {
    let inputSession: USBInputSession?
    private let lock = NSLock()
    private var consumed = false
    private let context: ScreenUSBExecutionContext
    init(context: ScreenUSBExecutionContext, observation: ScreenUSBExecutionContext.Observation? = nil, sequence: UInt64? = nil, inputSession: USBInputSession? = nil) {
        self.context = context
        self.inputSession = inputSession
    }
    func enqueue(_ send: () -> Void) throws {
        try lock.withLock {
            guard !consumed else { throw AppError.stopped }
            consumed = true
            try context.enqueue(send)
        }
    }
}

/// Adapter for the selectively reused coordinator. No BackgroundTasks registration,
/// no audio keepalive, no automatic restart, and no changes to other routes.
@MainActor final class ScreenCaptureRunScheduler: RunBackgroundScheduler {
    var context: ScreenUSBExecutionContext?
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        guard let context, context.backgroundEnabled else { throw AppError.stopped }
        try context.requireForegroundApproval()
        launched(ScreenCaptureRunLease(context: context))
    }
    func cancel(identifier: String) {}
}
@MainActor private final class ScreenCaptureRunLease: RunBackgroundLease {
    var expirationHandler: (() -> Void)?
    private var monitor: Task<Void, Never>?
    private var completed = false
    init(context: ScreenUSBExecutionContext) {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try context.requireHealthy(); try await Task.sleep(nanoseconds: 100_000_000) }
                catch {
                    guard !Task.isCancelled, let self, !self.completed else { return }
                    self.expirationHandler?(); self.complete(success: false); return
                }
            }
        }
    }
    func report(completed: Int, subtitle: String) {}
    func complete(success: Bool) { completed = true; monitor?.cancel(); monitor = nil; expirationHandler = nil }
}

@MainActor enum RunLifecycleFactory {
    static func make(persistent: Bool, scheduler: any RunBackgroundScheduler) -> RunLifecycleCoordinator {
        let storage: any RunCheckpointStorage
        if persistent {
            do { storage = try RunCheckpointStore() }
            catch { storage = UnavailableCheckpointStore() }
        } else { storage = MemoryRunCheckpointStore() }
        return RunLifecycleCoordinator(scheduler: scheduler, storage: storage)
    }
}
@MainActor private struct UnavailableCheckpointStore: RunCheckpointStorage {
    func load() throws -> RunCheckpoint? { throw AppError.unavailable("检查点不可用") }
    func save(_ checkpoint: RunCheckpoint) throws { throw AppError.unavailable("检查点不可用") }
}
