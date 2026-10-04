import Foundation

/// Observed authenticated transport health, never inferred from interface presence.
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
}

/// A revocable capability checked again at the actual NWConnection enqueue.
/// RunLifecycleCoordinator remains the sole owner of lifecycle and transaction state.
/// This is NOT a grant from BGTaskScheduler and cannot keep a suspended process alive.
final class ScreenUSBExecutionContext: @unchecked Sendable {
    enum Scene: Sendable { case active, inactive, background }
    struct Observation: Sendable { let revision: UInt64; let after: TimeInterval }
    let backgroundEnabled: Bool
    let epoch: UUID
    private let frames: LatestScreenFrame
    private let health: USBTransportHealth
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private let deadline: TimeInterval
    private var revoked = false
    private var scene = Scene.active
    private var revision: UInt64 = 0
    private var entered: TimeInterval
    private var backgroundDeadline: TimeInterval?

    init(frames: LatestScreenFrame, health: USBTransportHealth, backgroundEnabled: Bool,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        self.frames = frames; self.health = health; self.backgroundEnabled = backgroundEnabled; self.now = now
        epoch = try frames.sessionID(); entered = now(); deadline = now() + 300
        try requireHealthy()
    }
    func setScene(_ next: Scene) {
        lock.withLock {
            guard scene != next else { return }
            if now() >= deadline || backgroundDeadline.map({ now() >= $0 }) == true { revoked = true }
            scene = next; revision += 1; entered = now()
            if next == .background { backgroundDeadline = entered + 60 }
            if next == .active { backgroundDeadline = nil }
            if !backgroundEnabled, next != .active { revoked = true }
        }
    }
    func revoke() { lock.withLock { revoked = true } }
    private func validate() throws {
        do {
            let time = now()
            guard !revoked, time < deadline, backgroundDeadline.map({ time < $0 }) ?? true else { throw AppError.stopped }
            try frames.requireSession(epoch, now: time)
            try health.requireHealthy(now: time)
        } catch {
            revoked = true // A late frame/PING never revives an observed loss.
            throw error
        }
    }
    func requireHealthy() throws { try lock.withLock { try validate() } }
    func requireForegroundApproval() throws {
        try lock.withLock {
            try validate()
            guard scene == .active else { throw AppError.stopped }
        }
    }
    func observation() throws -> Observation? {
        try lock.withLock {
            try validate()
            guard scene == (backgroundEnabled ? .background : .active) else { return nil }
            return Observation(revision: revision, after: backgroundEnabled ? entered + 0.2 : 0)
        }
    }
    func enqueue(observation: Observation, sequence: UInt64, _ send: () -> Void) throws {
        try lock.withLock {
            try validate()
            guard revision == observation.revision, scene == (backgroundEnabled ? .background : .active) else { throw AppError.stopped }
            // Invalidation/scene changes are serialized with this last send fence.
            try frames.withSession(epoch, now: now(), sequence: sequence, send)
        }
    }
}

final class USBInputPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false
    private let context: ScreenUSBExecutionContext
    private let observation: ScreenUSBExecutionContext.Observation
    private let sequence: UInt64
    init(context: ScreenUSBExecutionContext, observation: ScreenUSBExecutionContext.Observation, sequence: UInt64) {
        self.context = context; self.observation = observation; self.sequence = sequence
    }
    func enqueue(_ send: () -> Void) throws {
        try lock.withLock {
            guard !consumed else { throw AppError.stopped }
            consumed = true
            try context.enqueue(observation: observation, sequence: sequence, send)
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
