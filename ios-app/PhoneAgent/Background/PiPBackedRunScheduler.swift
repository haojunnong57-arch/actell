import Foundation

/// Tracks actual AVKit start/stop receipts. A requested or merely visible inline
/// preview does not qualify. Multiple runners share the one app-level window.
@MainActor final class PiPExecutionActivity {
    static let shared = PiPExecutionActivity()
    private var owners: Set<UUID> = []
    private var observers: [UUID: (Bool) -> Void] = [:]
    var active: Bool { !owners.isEmpty }
    func update(owner: UUID, active: Bool) {
        let previous = self.active
        if active { owners.insert(owner) } else { owners.remove(owner) }
        guard previous != self.active else { return }
        for observer in Array(observers.values) { observer(self.active) }
    }
    func observe(_ callback: @escaping (Bool) -> Void) -> UUID {
        let token = UUID(); observers[token] = callback; return token
    }
    func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }
}

/// System processing and an actually active PiP are independent sources. Losing
/// one source cannot revoke the whole run while the other remains available.
@MainActor final class PiPBackedRunScheduler: RunBackgroundScheduler {
    private let primary: any RunBackgroundScheduler
    private let activity: PiPExecutionActivity
    private var leases: [String: PiPBackedRunLease] = [:]
    init(primary: any RunBackgroundScheduler, activity: PiPExecutionActivity = .shared) {
        self.primary = primary; self.activity = activity
    }
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        try submit(identifier: identifier, launched: launched, failed: {})
    }
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void,
                failed: @escaping @MainActor () -> Void) throws {
        let lease = PiPBackedRunLease(activity: activity, launched: launched, failed: failed)
        leases[identifier] = lease
        lease.deliverIfAvailable()
        do {
            try primary.submit(identifier: identifier, launched: { [weak lease] grant in
                guard let lease else { grant.complete(success: false); return }
                lease.accept(grant)
            }, failed: { [weak lease] in lease?.primaryEnded() })
        } catch {
            if lease.valid { lease.deliverIfAvailable() }
            else { leases.removeValue(forKey: identifier); lease.complete(success: false); primary.cancel(identifier: identifier); throw error }
        }
    }
    func cancel(identifier: String) {
        leases.removeValue(forKey: identifier)?.complete(success: false)
        primary.cancel(identifier: identifier)
    }
}

@MainActor private final class PiPBackedRunLease: RunBackgroundLease {
    var expirationHandler: (() -> Void)?
    private let activity: PiPExecutionActivity
    private let launched: @MainActor (any RunBackgroundLease) -> Void
    private let failed: @MainActor () -> Void
    private var primary: (any RunBackgroundLease)?
    private var observer: UUID?
    private var delivered = false
    private var completed = false
    private var progress: (Int, String)?
    var valid: Bool { !completed && (primary != nil || activity.active) }
    init(activity: PiPExecutionActivity, launched: @escaping @MainActor (any RunBackgroundLease) -> Void,
         failed: @escaping @MainActor () -> Void) {
        self.activity = activity; self.launched = launched; self.failed = failed
        observer = activity.observe { [weak self] _ in self?.activityChanged() }
    }
    func deliverIfAvailable() {
        guard valid, !delivered else { return }
        delivered = true; launched(self)
    }
    func accept(_ grant: any RunBackgroundLease) {
        guard !completed else { grant.complete(success: false); return }
        if primary === grant { return }
        primary = grant
        grant.expirationHandler = { [weak self] in self?.primaryEnded() }
        if let progress { grant.report(completed: progress.0, subtitle: progress.1) }
        deliverIfAvailable()
    }
    func primaryEnded() {
        BackgroundExecutionTrace.record("execution.systemEnded pip=\(activity.active) delivered=\(delivered)")
        let old = primary; primary = nil
        old?.expirationHandler = nil; old?.complete(success: false)
        activityChanged()
    }
    private func activityChanged() {
        guard !completed else { return }
        if valid { deliverIfAvailable(); return }
        BackgroundExecutionTrace.record("execution.allSourcesEnded delivered=\(delivered)")
        if delivered { expirationHandler?() } else { failed() }
        complete(success: false)
    }
    func report(completed: Int, subtitle: String) {
        guard !self.completed else { return }
        progress = (completed, subtitle); primary?.report(completed: completed, subtitle: subtitle)
    }
    func complete(success: Bool) {
        guard !completed else { return }
        completed = true; expirationHandler = nil
        if let observer { activity.removeObserver(observer) }
        observer = nil
        let old = primary; primary = nil
        old?.expirationHandler = nil; old?.complete(success: success)
    }
}

/// Bounded lifecycle metadata only: no goals, messages, images or credentials.
@MainActor enum BackgroundExecutionTrace {
    static func record(_ event: String) {
        let file = URL.documentsDirectory.appending(path: "background-execution-events.log")
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append("\(Date().ISO8601Format()) \(event)")
        try? (lines.suffix(200).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
