import Foundation
import BackgroundTasks

@available(iOS 27.0, *)
@MainActor final class ContinuedProcessingScheduler: RunBackgroundScheduler {
    private var submissions: [String: Task<Void, Never>] = [:]
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        try submit(identifier: identifier, launched: launched, failed: {})
    }
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void,
                failed: @escaping @MainActor () -> Void) throws {
        // The permitted Info.plist prefix is a wildcard, but both registration
        // and submission use this same concrete, unique per-segment identifier.
        guard BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main, launchHandler: { task in
            MainActor.assumeIsolated {
                guard let continued = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                launched(ContinuedProcessingLease(task: continued))
            }
        }) else { throw AppError.unavailable("后台片段 ID 注册失败") }
        submissions[identifier] = Task { [weak self] in
            defer { self?.submissions.removeValue(forKey: identifier) }
            do {
                try Task.checkCancellation()
                try await Self.submitRequest(identifier: identifier)
                // Cancellation can race the asynchronous registration response.
                // Re-cancel after acceptance so an ended run leaves no request.
                if Task.isCancelled { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
            }
            catch { if !Task.isCancelled { failed() } }
        }
    }
    private nonisolated static func submitRequest(identifier: String) async throws {
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "PhoneAgent 正在处理任务", subtitle: "等待实际响应；可随时取消")
        request.strategy = .fail
        request.requiredResources = [] // CPU/network only; no GPU entitlement.
        // iOS 27's asynchronous API reports errors missed by deprecated submit.
        // No UI/MainActor work runs while waiting for the scheduler's response.
        try await BGTaskScheduler.shared.submitTaskRequest(request)
    }
    func cancel(identifier: String) {
        submissions.removeValue(forKey: identifier)?.cancel()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
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
