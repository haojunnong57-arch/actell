import Foundation

protocol DeviceBridge: Sendable {
    var executionContext: ScreenUSBExecutionContext? { get }
    func supportsBackgroundExecution(tool: String) async -> Bool
    func approvalContext(imageID: String) async throws -> String
    func acceptApproval(imageID: String) async throws
    func authorizeTaskInput(imageID: String) async throws
    func screenshot() async throws -> FrameImage
    func tap(x: Int, y: Int, imageID: String) async throws
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws
    func cancelTransport()
    func stop() async
}

extension DeviceBridge {
    var executionContext: ScreenUSBExecutionContext? { nil }
    func cancelTransport() {}
    func supportsBackgroundExecution(tool: String) async -> Bool { false }
    func approvalContext(imageID: String) async throws -> String { "foreground-only" }
    func acceptApproval(imageID: String) async throws {}
    func authorizeTaskInput(imageID: String) async throws {
        throw AppError.unavailable("当前输入通道不支持任务内自动授权")
    }
}

struct UnavailableBridge: DeviceBridge {
    static let screenshotMessage = "尚未授权 App 全屏采集。请在设置 → 控制调试中授权全屏采集；查看屏幕无需连接 ESP32。"
    func screenshot() async throws -> FrameImage { throw AppError.unavailable(Self.screenshotMessage) }
    func tap(x: Int, y: Int, imageID: String) async throws { throw AppError.unavailable("设备未连接") }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { throw AppError.unavailable("设备未连接") }
    func stop() async {}
}

/// Snapshot the capture and input capabilities separately for each run.
/// A local screenshot never requires a working USB connection or HID firmware.
enum LiveDeviceBridgeRouter {
    struct USBInput {
        let transport: any USBCommandTransport
        let health: USBTransportHealth
        let supportsHID: Bool
    }
    static func make(frames: LatestScreenFrame, captureActive: Bool,
                     usb: USBInput?, backgroundEnabled: Bool, legacy: (any DeviceBridge)? = nil,
                     usbStatus: USBConnectionStatus = .idle, diagnostics: USBDiagnosticsLog? = nil,
                     onLoss: @escaping @Sendable (USBBridgeStopReason) -> Void = { _ in }) throws -> any DeviceBridge {
        func record(_ route: String, reason: String) {
            diagnostics?.record("run.route selected=\(route) reason=\(reason) usbState=\(usbStatus.diagnosticState) hasClient=\(usb != nil) captureActive=\(captureActive) backgroundEnabled=\(backgroundEnabled)")
        }
        guard captureActive else {
            // The explicitly started legacy Host service remains available.
            if usb == nil, let legacy { record("legacy", reason: "explicitLegacyService"); return legacy }
            record("unavailable", reason: "captureNotActive")
            return UnavailableBridge()
        }
        var inputFailure = usbStatus.unavailableInputMessage
        var reason = "usbClientMissing"
        if let usb {
            reason = "firmwareNCMOnly"
            inputFailure = "当前 USB 固件仅支持 NCM；可以查看屏幕，点击或拖动还需启用 HID。"
            if usb.supportsHID {
                do {
                    let context = try ScreenUSBExecutionContext(frames: frames, health: usb.health, backgroundEnabled: backgroundEnabled)
                    record("usbHID", reason: "captureAndUSBHealthy")
                    return USBDeviceBridge(frames: frames, transport: usb.transport, context: context, diagnostics: diagnostics, onLoss: onLoss)
                } catch {
                    // Never grant inputs on an invalid capture/USB lease. The
                    // local read path independently validates its capture session.
                    inputFailure = "USB 输入条件已失效；重新连接并取得新画面后再开始控制任务。"
                    reason = "inputConditionsInvalid"
                }
            }
        }
        record("localScreen", reason: reason)
        return try LocalScreenBridge(frames: frames, backgroundEnabled: backgroundEnabled, inputFailure: inputFailure)
    }
}

/// Read-only Agent access to the App's existing capture session.
/// Stopping a run revokes this reader, not the user's system capture session.
struct LocalScreenBridge: DeviceBridge {
    private let frames: LatestScreenFrame
    let executionContext: ScreenUSBExecutionContext?
    private let context: ScreenUSBExecutionContext
    private let inputFailure: String
    init(frames: LatestScreenFrame, backgroundEnabled: Bool, inputFailure: String) throws {
        self.frames = frames; self.inputFailure = inputFailure
        context = try ScreenUSBExecutionContext(frames: frames, backgroundEnabled: backgroundEnabled)
        executionContext = context
    }
    func supportsBackgroundExecution(tool: String) async -> Bool {
        context.backgroundEnabled && ["screenshot", "wait", "finish"].contains(tool)
    }
    func screenshot() async throws -> FrameImage {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            try Task.checkCancellation()
            if let scope = try context.captureObservation(),
               let stamp = try? frames.latestStamp(), stamp.uptime > scope.after {
                let frame = try frames.encoded(notBefore: scope.after)
                try Task.checkCancellation()
                if let current = try context.captureObservation(), current.revision == scope.revision { return frame }
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        context.revoke()
        throw AppError.unavailable("等待有效采集画面超时。\(frames.diagnostics().summary)。请复制诊断日志检查接收状态。")
    }
    func approvalContext(imageID: String) throws -> String { throw AppError.unavailable(inputFailure) }
    func acceptApproval(imageID: String) throws { throw AppError.unavailable(inputFailure) }
    func tap(x: Int, y: Int, imageID: String) async throws { throw AppError.unavailable(inputFailure) }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { throw AppError.unavailable(inputFailure) }
    func cancelTransport() { context.revoke() }
    func stop() async { context.revoke() }
}
