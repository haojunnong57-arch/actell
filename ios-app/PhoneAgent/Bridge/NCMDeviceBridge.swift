import Foundation
import ImageIO

/// Snapshot the route once per run. A future setting can select the retained
/// local capture/USB implementation here without changing agent tools.
enum DeviceControlRoute: Sendable {
    case ncmDeveloper
    case localCaptureUSB
    static let current: Self = .ncmDeveloper
    var modelContext: String {
        switch self {
        case .ncmDeveloper:
            return "Screenshots and touch input use the authenticated ESP32 NCM developer connection. Background execution uses system-granted execution time; reconnecting invalidates this run."
        case .localCaptureUSB:
            return "Screenshots use this App's authorized ScreenCaptureKit capture, independently of USB. Touch input uses the retained USB HID route. Follow the tools' actual foreground/background capabilities."
        }
    }
}

@MainActor protocol NCMControlConnection: AnyObject {
    var ready: Bool { get }
    var connectionFailure: String? { get }
    var running: Bool { get }
    var agentReserved: Bool { get }
    var controlSessionID: UUID { get }
    func agentCapture(owner: UUID, session: UUID) async throws -> Data
    func agentTap(owner: UUID, session: UUID, x: UInt16, y: UInt16, validate: () throws -> Void) async throws
    func agentDrag(owner: UUID, session: UUID, fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16, validate: () throws -> Void) async throws
    func agentApplications(owner: UUID, session: UUID) async throws -> Data
    func agentSystemAction(owner: UUID, session: UUID, name: String, text: String, arguments: [String], validate: () throws -> Void) async throws
    func retainConnection(owner: UUID)
    func awaitControlRelease() async
    func releaseConnection(owner: UUID)
    func registerAgent(owner: UUID, session: UUID)
    func releaseAgent(owner: UUID, session: UUID)
}

extension NCMControlConnection {
    var connectionFailure: String? { nil }
    func agentApplications(owner: UUID, session: UUID) async throws -> Data { throw AppError.unavailable("当前连接不支持查询 App") }
    func agentSystemAction(owner: UUID, session: UUID, name: String, text: String, arguments: [String], validate: () throws -> Void) async throws { throw AppError.unavailable("当前连接不支持此操作") }
    func awaitControlRelease() async {}
    func retainConnection(owner: UUID) {}
    func releaseConnection(owner: UUID) {}
    func registerAgent(owner: UUID, session: UUID) {}
}

extension PairingFlow: NCMControlConnection {
    var connectionFailure: String? { lastFailure }
    func awaitControlRelease() async { await mediaLifetimeWait() }
    func agentApplications(owner: UUID, session: UUID) async throws -> Data {
        try await agentOperation(owner: owner, session: session) { try await $0.installedApplications() }
    }
    func agentSystemAction(owner: UUID, session: UUID, name: String, text: String, arguments: [String], validate: () throws -> Void) async throws {
        try await agentOperation(owner: owner, session: session) { services in
            if name == "home" || name == "type_text" { try await self.prepareAgentInput(services) }
            try Task.checkCancellation(); try validate()
            switch name {
            case "home": try await services.home()
            case "type_text": try await services.typeText(text)
            case "launch_app": try await services.launchApplication(bundleID: text, arguments: arguments)
            default: throw AppError.invalid("未注册的系统操作")
            }
        }
    }
    func agentCapture(owner: UUID, session: UUID) async throws -> Data {
        try await agentOperation(owner: owner, session: session) { try await self.prepareAgentInput($0); return try await $0.captureVideoJPEG() }
    }
    func agentTap(owner: UUID, session: UUID, x: UInt16, y: UInt16, validate: () throws -> Void) async throws {
        try await agentOperation(owner: owner, session: session) { services in
            try await self.prepareAgentInput(services)
            try Task.checkCancellation()
            try validate()
            _ = try await services.tapDelivery(x: x, y: y)
        }
    }
    func agentDrag(owner: UUID, session: UUID, fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16, validate: () throws -> Void) async throws {
        try await agentOperation(owner: owner, session: session) { services in
            try await self.prepareAgentInput(services)
            try Task.checkCancellation()
            try validate()
            _ = try await services.dragDelivery(fromX: fromX, fromY: fromY, toX: toX, toY: toY, durationMS: durationMS)
        }
    }
}

private final class NCMRunFence: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw AppError.stopped }
    }
}

/// Uses the Settings connection, never a second relay or the old HID route.
/// Images and approval are bound to this run and authenticated generation.
@MainActor final class NCMDeviceBridge: DeviceBridge {
    private let flow: any NCMControlConnection
    private var session: UUID?
    private let owner = UUID()
    private nonisolated let fence = NCMRunFence()
    private var imageID: String?
    private var approvedImageID: String?
    private var taskAuthorized = false
    init(flow: any NCMControlConnection = PairingFlow.shared) throws {
        self.flow = flow
        flow.retainConnection(owner: owner)
    }
    // Scheduling capability is independent of connection readiness; transport
    // failures are reported by tools, never used to pause ordinary chat.
    func supportsBackgroundExecution(tool: String) async -> Bool { (try? fence.check()) != nil }
    private func check() throws {
        try fence.check()
        guard flow.ready else {
            throw AppError.unavailable(flow.connectionFailure ?? "手机操控未连接，请在设置 → 手机操控 → ESP32 控制中连接")
        }
        if let session {
            guard flow.controlSessionID == session else {
                throw AppError.unavailable("手机操控连接已改变，请重新发起操控任务")
            }
        } else {
            session = flow.controlSessionID
            flow.registerAgent(owner: owner, session: flow.controlSessionID)
        }
    }
    private func requireSession() throws -> UUID {
        try check()
        guard let session else { throw AppError.stopped }
        return session
    }
    func approvalContext(imageID: String) async throws -> String {
        let session = try requireSession()
        guard self.imageID == imageID else { throw AppError.invalid("请先获取新的截图") }
        return "ncm:\(session.uuidString):\(owner.uuidString)"
    }
    func acceptApproval(imageID: String) async throws {
        _ = try await approvalContext(imageID: imageID)
        approvedImageID = imageID
    }
    func authorizeTaskInput(imageID: String) async throws {
        try await acceptApproval(imageID: imageID)
        taskAuthorized = true
    }
    func screenshot() async throws -> FrameImage {
        try check()
        imageID = nil; approvedImageID = nil
        let session = try requireSession()
        let png = try await perform { try await flow.agentCapture(owner: owner, session: session) }
        try check()
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw AppError.protocolViolation("NCM 截图格式无效")
        }
        let id = UUID().uuidString
        imageID = id; approvedImageID = nil
        return FrameImage(id: id, png: png, width: width, height: height, capturedAt: Date(), isDemo: false)
    }
    private func consumeImage(_ id: String, coordinates: [Int]) throws {
        try check()
        guard imageID == id, approvedImageID == id || taskAuthorized else { throw AppError.invalid("输入需要当前截图与本次任务授权") }
        guard coordinates.allSatisfy({ (0...65535).contains($0) }) else { throw AppError.invalid("输入坐标越界") }
        imageID = nil; approvedImageID = nil
    }
    func tap(x: Int, y: Int, imageID: String) async throws {
        try consumeImage(imageID, coordinates: [x, y])
        let session = try requireSession()
        try await perform { try await flow.agentTap(owner: owner, session: session, x: UInt16(x), y: UInt16(y), validate: { try self.check() }) }
    }

    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws {
        guard (100...2000).contains(durationMS) else { throw AppError.invalid("拖动时长需为 100–2000 毫秒") }
        try consumeImage(imageID, coordinates: [fromX, fromY, toX, toY])
        let session = try requireSession()
        try await perform { try await flow.agentDrag(owner: owner, session: session, fromX: UInt16(fromX), fromY: UInt16(fromY), toX: UInt16(toX), toY: UInt16(toY), durationMS: UInt16(durationMS), validate: { try self.check() }) }
    }
    func installedApplications() async throws -> Data {
        let session = try requireSession()
        return try await perform { try await flow.agentApplications(owner: owner, session: session) }
    }
    func systemAction(name: String, text: String, arguments: [String], imageID: String) async throws {
        try consumeImage(imageID, coordinates: [])
        let session = try requireSession()
        try await perform { try await flow.agentSystemAction(owner: owner, session: session, name: name, text: text, arguments: arguments, validate: { try self.check() }) }
    }
    private func perform<T>(_ action: () async throws -> T) async throws -> T {
        do {
            try check()
            let value = try await action()
            try check()
            return value
        }
        catch NCMControlError.unavailable(let message) { throw AppError.unavailable(message) }
        catch NCMControlError.stopped { throw AppError.stopped }
    }

    nonisolated func cancelTransport() {
        fence.cancel()
        Task { @MainActor in
            if let session = self.session { self.flow.releaseAgent(owner: self.owner, session: session) }
            self.flow.releaseConnection(owner: self.owner)
        }
    }
    func stop() async {
        fence.cancel(); imageID = nil; approvedImageID = nil; taskAuthorized = false
        if let session {
            flow.releaseAgent(owner: owner, session: session)
            if flow.controlSessionID == session { await flow.awaitControlRelease() }
        }
        flow.releaseConnection(owner: owner)
    }
}

/// Owns asynchronous media cleanup independently of UI visibility. A revoked
/// generation can never publish cleanup completion into a newer connection.
@MainActor final class ControlMediaLifetime {
    private(set) var active = false
    private(set) var stopping = false
    private var generation = UUID()
    private var cleanup: Task<Void, Never>?
    func didOpen() { active = true }
    @discardableResult func finishIfIdle(hasUsers: Bool,
        stop: @escaping @MainActor () async throws -> Void,
        completed: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard active, !hasUsers, !stopping else { return false }
        stopping = true
        let epoch = generation
        cleanup = Task { [weak self] in
            var success = false
            do { try Task.checkCancellation(); try await stop(); success = true } catch {}
            guard let self, self.generation == epoch else { return }
            self.active = false; self.stopping = false; self.cleanup = nil
            completed(success)
        }
        return true
    }
    func wait() async { await cleanup?.value }
    func revoke() {
        generation = UUID(); active = false; stopping = false
        cleanup?.cancel(); cleanup = nil
    }
}
