import Foundation

/// One coordinator, one execution source per run. A SCK run never also requests
/// a BGContinuedProcessingTask. Neither source grants a device tool permission.
@MainActor final class RunExecutionScheduler: RunBackgroundScheduler {
    private let screen = ScreenCaptureRunScheduler()
    private let continued: any RunBackgroundScheduler
    private let foregroundOnly = ForegroundOnlyScheduler()
    private var selected: any RunBackgroundScheduler
    private var owners: [String: any RunBackgroundScheduler] = [:]
    init(continued: any RunBackgroundScheduler = ContinuedProcessingScheduler()) {
        self.continued = continued; selected = ForegroundOnlyScheduler()
    }
    func configure(context: ScreenUSBExecutionContext?, allowSystemProcessing: Bool) {
        screen.context = context
        if let context { selected = context.backgroundEnabled ? screen : foregroundOnly }
        else { selected = allowSystemProcessing ? continued : foregroundOnly }
    }
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        owners[identifier] = selected
        try selected.submit(identifier: identifier, launched: launched)
    }
    func cancel(identifier: String) {
        // The run may already have selected a different backend by the time an
        // old callback arrives; cancel through the original owner only.
        owners.removeValue(forKey: identifier)?.cancel(identifier: identifier)
    }
}
