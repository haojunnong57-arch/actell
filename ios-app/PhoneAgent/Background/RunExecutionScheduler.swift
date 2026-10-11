import Foundation

/// One coordinator per run. A SCK run never also requests
/// a BGContinuedProcessingTask. Neither source grants a device tool permission.
@MainActor final class RunExecutionScheduler: RunBackgroundScheduler {
    private let screen = ScreenCaptureRunScheduler()
    private let continued: any RunBackgroundScheduler
    private let continuedWithPiP: any RunBackgroundScheduler
    private let foregroundOnly = ForegroundOnlyScheduler()
    private let mediaOnly: MediaOnlyRunScheduler
    private var selected: any RunBackgroundScheduler
    private var owners: [String: any RunBackgroundScheduler] = [:]
    init(continued: any RunBackgroundScheduler = ContinuedProcessingScheduler(), activity: PiPExecutionActivity = .shared) {
        mediaOnly = MediaOnlyRunScheduler(activity: activity)
        self.continued = continued
        continuedWithPiP = PiPBackedRunScheduler(primary: continued, activity: activity)
        selected = ForegroundOnlyScheduler()
    }
    func configure(context: ScreenUSBExecutionContext?, allowSystemProcessing: Bool, useSystemProcessing: Bool = false) {
        screen.context = context
        if let context { selected = context.backgroundEnabled ? screen : foregroundOnly }
        else { selected = allowSystemProcessing ? (useSystemProcessing ? continuedWithPiP : mediaOnly) : foregroundOnly }
    }
    func setForeground(_ active: Bool) {
        mediaOnly.setForeground(active)
    }
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        try submit(identifier: identifier, launched: launched, failed: {})
    }
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void,
                failed: @escaping @MainActor () -> Void) throws {
        owners[identifier] = selected
        try selected.submit(identifier: identifier, launched: launched, failed: failed)
    }
    func cancel(identifier: String) {
        // The run may already have selected a different backend by the time an
        // old callback arrives; cancel through the original owner only.
        if let owner = owners.removeValue(forKey: identifier) { owner.cancel(identifier: identifier) }
        else {
            // After process death the owner map is empty. The coordinator has
            // validated this persisted ID's app prefix; cancel any old system
            // request too. A SCK-only segment has no system request to cancel.
            continued.cancel(identifier: identifier)
        }
    }
}
