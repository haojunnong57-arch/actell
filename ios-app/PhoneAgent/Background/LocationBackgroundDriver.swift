import Foundation
import CoreLocation
import Combine

/// All permission flows participate. Rejected requests are never queued/auto-chained.
@MainActor final class PermissionRequestGate {
    static let shared = PermissionRequestGate()
    private var owner: UUID?
    func acquire() -> UUID? { guard owner == nil else { return nil }; let id = UUID(); owner = id; return id }
    func release(_ id: UUID) { if owner == id { owner = nil } }
}

struct LocationEvidence: Sendable { let timestamp: Date; let accuracy: Double }
enum LocationEvent: Sendable { case authorization, evidence([LocationEvidence]), paused, unavailable, failed }
@MainActor protocol LocationManaging: AnyObject {
    var authorization: CLAuthorizationStatus { get }
    var servicesEnabled: Bool { get }
    var reducedAccuracy: Bool { get }
    var onEvent: ((LocationEvent) -> Void)? { get set }
    func requestWhenInUse()
    func start()
    func stop()
}

/// No CLLocation crosses this adapter. Coordinates never enter app state or diagnostics.
@MainActor final class NativeLocationManager: NSObject, LocationManaging, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onEvent: ((LocationEvent) -> Void)?
    var authorization: CLAuthorizationStatus { manager.authorizationStatus }
    var servicesEnabled: Bool { CLLocationManager.locationServicesEnabled() }
    var reducedAccuracy: Bool { manager.accuracyAuthorization == .reducedAccuracy }
    override init() { super.init(); manager.delegate = self }
    func requestWhenInUse() { manager.requestWhenInUseAuthorization() }
    func start() {
        manager.activityType = .other
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
    }
    func stop() {
        manager.stopUpdatingLocation(); manager.allowsBackgroundLocationUpdates = false
        manager.delegate = nil; onEvent = nil
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.onEvent?(.authorization) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let evidence = locations.map { LocationEvidence(timestamp: $0.timestamp, accuracy: $0.horizontalAccuracy) }
        Task { @MainActor [weak self] in self?.onEvent?(.evidence(evidence)) }
    }
    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.onEvent?(.paused) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let temporary = (error as? CLError)?.code == .locationUnknown
        Task { @MainActor [weak self] in self?.onEvent?(temporary ? .unavailable : .failed) }
    }
}

@MainActor final class LocationBackgroundDriver: ObservableObject {
    @Published private(set) var state: BackgroundDriverState = .idle
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var servicesEnabled = true
    @Published private(set) var reducedAccuracy = false
    let configured: Bool
    private let factory: () -> any LocationManaging
    private let registry: BackgroundExecutionRegistry
    private let clock: () -> Date
    private let gate: PermissionRequestGate
    private var manager: (any LocationManaging)?
    private var permissionManager: (any LocationManaging)?
    private var token: BackgroundSourceToken?
    private let owner = UUID()
    private var startedAt: Date?
    private var wanted = false
    private var foreground = false
    private var blockedAttempt = false
    private var permissionToken: UUID?
    private var demandEpoch = UUID()
    var permissionAllowed = true
    init(registry: BackgroundExecutionRegistry, configured: Bool? = nil,
         factory: @escaping () -> any LocationManaging = { NativeLocationManager() },
         gate: PermissionRequestGate = .shared, clock: @escaping () -> Date = Date.init) {
        self.registry = registry; self.factory = factory; self.gate = gate; self.clock = clock
        self.configured = configured ?? ((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []).contains("location") &&
            !(Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String ?? "").isEmpty)
        refreshAuthorization()
    }
    var authorizationText: String {
        let value: String
        switch authorization {
        case .notDetermined: value = "尚未授权"
        case .denied: value = "已拒绝"
        case .restricted: value = "系统限制"
        case .authorizedWhenInUse: value = "使用 App 期间"
        case .authorizedAlways: value = "始终（既有授权）"
        @unknown default: value = "未知授权"
        }
        return "授权：\(value)；系统定位：\(servicesEnabled ? "开启" : "关闭")；精度：\(reducedAccuracy ? "大致" : "精确")"
    }
    func refreshAuthorization() {
        let probe = manager ?? permissionManager ?? factory()
        authorization = probe.authorization; servicesEnabled = probe.servicesEnabled; reducedAccuracy = probe.reducedAccuracy
    }
    func setDemand(_ wanted: Bool, foreground: Bool) {
        let wasWanted = self.wanted
        self.wanted = wanted; self.foreground = foreground
        refreshAuthorization()
        guard wanted else { stop(); blockedAttempt = false; return }
        if !wasWanted { blockedAttempt = false }
        guard configured else { state = .failed; return }
        guard servicesEnabled, authorization != .denied, authorization != .restricted else { stop(); state = .pausedBySystem; return }
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            if token != nil { stop() }
            state = foreground ? .requestingPermission : .waitingForForeground; return
        }
        guard permissionAllowed else { state = .idle; return }
        guard token == nil, !blockedAttempt else { return }
        guard foreground else { state = .waitingForForeground; return }
        start()
    }
    /// Called after a foreground purpose explanation or an explicit settings toggle.
    func requestPermission(gateToken: UUID, forSelection: Bool = false) {
        guard (wanted || forSelection), foreground, configured, permissionAllowed, servicesEnabled, authorization == .notDetermined else { gate.release(gateToken); return }
        permissionToken = gateToken; state = .requestingPermission
        let context = demandEpoch
        let permissionManager = factory(); self.permissionManager = permissionManager
        permissionManager.onEvent = { [weak self, weak permissionManager] event in
            guard let self, let permissionManager, self.permissionManager === permissionManager else { return }
            guard case .authorization = event else { return }
            self.refreshAuthorization()
            guard self.authorization != .notDetermined else { return }
            if let permissionToken = self.permissionToken { self.gate.release(permissionToken) }
            self.permissionToken = nil
            permissionManager.onEvent = nil; self.permissionManager = nil
            if self.demandEpoch == context { self.setDemand(self.wanted, foreground: self.foreground) }
            else if self.wanted { self.state = .waitingForForeground }
        }
        permissionManager.requestWhenInUse()
    }
    func retryIfFailed() { if [.failed, .pausedBySystem, .interrupted].contains(state) { retry() } }
    func retry() { guard foreground, wanted else { return }; stop(); blockedAttempt = false; setDemand(true, foreground: true) }
    private func start() {
        let current = BackgroundSourceToken(mechanism: .location, owner: owner)
        let next = factory(); manager = next; token = current; startedAt = clock(); state = .starting
        next.onEvent = { [weak self, weak next] event in
            guard let self, let next, self.token == current, self.manager === next, self.wanted else { return }
            switch event {
            case .authorization: self.setDemand(self.wanted, foreground: self.foreground)
            case .evidence(let values):
                let received = self.clock()
                guard let start = self.startedAt, values.contains(where: {
                    $0.accuracy.isFinite && $0.accuracy >= 0 && $0.timestamp >= start && $0.timestamp <= received && received.timeIntervalSince($0.timestamp) <= 5
                }) else { return }
                self.state = .active; self.registry.publish(current)
            case .unavailable: self.registry.revoke(current); self.state = .starting
            case .paused: self.stop(); self.blockedAttempt = true; self.state = .pausedBySystem
            case .failed: self.stop(); self.blockedAttempt = true; self.state = .failed
            }
        }
        next.start()
    }
    func stop() {
        demandEpoch = UUID()
        let old = token; token = nil; startedAt = nil
        if let old { registry.revoke(old) }
        manager?.stop(); manager = nil
        // An already visible native prompt keeps the gate until its own receipt.
        // Its eventual authorization callback cannot start without a current demand.
        state = .stopped
    }
}

#if DEBUG
/// Offline UI fixtures never create CLLocationManager or trigger native permissions.
@MainActor final class FixtureLocationManager: LocationManaging {
    let authorization: CLAuthorizationStatus
    var servicesEnabled = true, reducedAccuracy = true
    var onEvent: ((LocationEvent) -> Void)?
    init(denied: Bool) { authorization = denied ? .denied : .notDetermined }
    func requestWhenInUse() {}
    func start() {}
    func stop() { onEvent = nil }
}
#endif
