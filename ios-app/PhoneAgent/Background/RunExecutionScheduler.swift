import Foundation

/// One coordinator per run. A SCK run never also requests
/// a BGContinuedProcessingTask. Neither source grants a device tool permission.
@MainActor final class RunExecutionScheduler: RunBackgroundScheduler {
    private let screen = ScreenCaptureRunScheduler()
    private let continued: any RunBackgroundScheduler
    private let continuedWithPiP: any RunBackgroundScheduler
    private let foregroundOnly = ForegroundOnlyScheduler()
    private var selected: any RunBackgroundScheduler
    private var owners: [String: any RunBackgroundScheduler] = [:]
    init(continued: any RunBackgroundScheduler = ContinuedProcessingScheduler()) {
        self.continued = continued
        continuedWithPiP = PiPBackedRunScheduler(primary: continued)
        selected = ForegroundOnlyScheduler()
    }
    func configure(context: ScreenUSBExecutionContext?, allowSystemProcessing: Bool) {
        screen.context = context
        if let context { selected = context.backgroundEnabled ? screen : foregroundOnly }
        else { selected = allowSystemProcessing ? continuedWithPiP : foregroundOnly }
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
