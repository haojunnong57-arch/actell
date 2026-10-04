import Foundation
import BackgroundTasks

@available(iOS 26.0, *)
@MainActor final class ContinuedProcessingScheduler: RunBackgroundScheduler {
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        // The permitted Info.plist prefix is a wildcard, but both registration
        // and submission use this same concrete, unique per-segment identifier.
        guard BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main, launchHandler: { task in
            MainActor.assumeIsolated {
                guard let continued = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                launched(ContinuedProcessingLease(task: continued))
            }
        }) else { throw AppError.unavailable("后台片段 ID 注册失败") }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Phone Agent 正在处理任务", subtitle: "等待实际响应；可随时取消")
        request.strategy = .fail
        request.requiredResources = [] // CPU/network only; no GPU entitlement.
        try BGTaskScheduler.shared.submit(request)
    }
    func cancel(identifier: String) { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
}

@available(iOS 26.0, *)
@MainActor private final class ContinuedProcessingLease: RunBackgroundLease {
    private let task: BGContinuedProcessingTask
    private var completed = false
    var expirationHandler: (() -> Void)?
    init(task: BGContinuedProcessingTask) {
        self.task = task
        // An adaptive agent does not know the final number of steps. Keep
        // Progress indeterminate, while the subtitle reports real receipts.
        task.progress.totalUnitCount = -1
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, !self.completed else { return }
                self.expirationHandler?()
                self.complete(success: false)
            }
        }
    }
    func report(completed: Int, subtitle: String) {
        guard !self.completed else { return }
        task.progress.completedUnitCount = Int64(completed)
        task.updateTitle("Phone Agent 正在处理任务", subtitle: subtitle)
    }
    func complete(success: Bool) {
        guard !completed else { return }; completed = true
        expirationHandler = nil; task.expirationHandler = nil
        if success {
            task.progress.totalUnitCount = max(1, task.progress.completedUnitCount)
            task.progress.completedUnitCount = task.progress.totalUnitCount
        }
        task.setTaskCompleted(success: success)
    }
}

@MainActor enum RunLifecycleFactory {
    static func make(persistent: Bool) -> RunLifecycleCoordinator {
        let scheduler: any RunBackgroundScheduler
        if persistent, #available(iOS 26.0, *) { scheduler = ContinuedProcessingScheduler() }
        else { scheduler = ForegroundOnlyScheduler() }
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
