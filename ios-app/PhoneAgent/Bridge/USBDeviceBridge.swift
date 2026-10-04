import Foundation
import CryptoKit

actor USBDeviceBridge: DeviceBridge {
    nonisolated let executionContext: ScreenUSBExecutionContext?
    private let frames: LatestScreenFrame
    private let transport: any USBCommandTransport
    private var stopped = false
    private var image: FrameImage?
    private var barrierSequence: UInt64 = 0
    private var barrierTime: TimeInterval = 0
    private var monitor: Task<Void, Never>?
    private var inputInFlight = false
    private var approvedImageID: String?
    private let onLoss: @Sendable () -> Void
    init(frames: LatestScreenFrame, transport: any USBCommandTransport,
         context: ScreenUSBExecutionContext? = nil, onLoss: @escaping @Sendable () -> Void = {}) {
        self.frames = frames; self.transport = transport; self.onLoss = onLoss
        executionContext = context
    }
    func supportsBackgroundExecution(tool: String) -> Bool { executionContext?.backgroundEnabled == true }
    func approvalContext(imageID: String) throws -> String {
        guard !stopped, image?.id == imageID else { throw AppError.stopped }
        try executionContext?.requireHealthy()
        return try frames.sessionID().uuidString
    }
    func acceptApproval(imageID: String) throws {
        guard !stopped, image?.id == imageID else { throw AppError.stopped }
        try executionContext?.requireForegroundApproval()
        approvedImageID = imageID
    }
    func arm() throws {
        _ = try frames.latestStamp()
        try executionContext?.requireHealthy()
        guard !stopped else { throw AppError.stopped }
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await self?.heartbeat(); try await Task.sleep(nanoseconds: 200_000_000) }
                catch { if !Task.isCancelled { await self?.lost() }; return }
            }
        }
    }
    private func heartbeat() async throws {
        guard !stopped else { throw AppError.stopped }
        _ = try frames.latestStamp()
        try executionContext?.requireHealthy()
        try await transport.command("PING")
    }
    private func lost() async { guard !stopped else { return }; await stop(); onLoss() }
    func screenshot() async throws -> FrameImage {
        guard !stopped else { throw AppError.stopped }
        let deadline = ProcessInfo.processInfo.systemUptime + (executionContext?.backgroundEnabled == true ? 15 : 2)
        repeat {
            try Task.checkCancellation()
            guard !stopped else { throw AppError.stopped }
            var transitionTime: TimeInterval = 0
            if let context = executionContext {
                guard let scope = try context.observation() else {
                    try await Task.sleep(nanoseconds: 40_000_000); continue
                }
                transitionTime = scope.after
            }
            if let frame = try? frames.encoded(after: barrierSequence, notBefore: max(barrierTime, transitionTime)) {
                // A scene transition during PNG encoding invalidates this observation.
                if let context = executionContext {
                    guard let scope = try context.observation(), frame.capture!.uptime > scope.after else { continue }
                }
                approvedImageID = nil; image = frame; return frame
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        await lost(); throw AppError.unavailable("采集没有返回新画面，输入已停止")
    }
    func tap(x: Int, y: Int, imageID: String) async throws {
        try await input("TAP \(x) \(y)", coordinates: [x, y], imageID: imageID)
    }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws {
        guard (100...2000).contains(durationMS) else { throw AppError.invalid("拖动时长无效") }
        try await input("DRAG \(fromX) \(fromY) \(toX) \(toY) \(durationMS)",
                        coordinates: [fromX, fromY, toX, toY], imageID: imageID)
    }
    private func input(_ body: String, coordinates: [Int], imageID: String) async throws {
        try Task.checkCancellation()
        guard !stopped, !inputInFlight, coordinates.allSatisfy({ (0...65535).contains($0) }),
              let approved = image, approved.id == imageID, let stamp = approved.capture else { throw AppError.stopped }
        let latest = try frames.latestStamp()
        guard stamp.isFresh(now: ProcessInfo.processInfo.systemUptime, maximumAge: executionContext?.backgroundEnabled == true ? 45 : 5),
              stamp.videoOrientation == latest.videoOrientation, stamp.width == latest.width, stamp.height == latest.height else {
            await lost(); throw AppError.unavailable("批准画面已过期或方向改变，请重新采集并确认")
        }
        guard executionContext == nil || approvedImageID == imageID else { throw AppError.stopped }
        image = nil; approvedImageID = nil; inputInFlight = true
        defer { inputInFlight = false }
        do {
            var permit: USBInputPermit?
            if let context = executionContext {
                // The user approves in PhoneAgent. For a background observation,
                // wait for their return to the target and compare a new complete
                // frame; never tap the approval UI or silently change the target.
                let returnDeadline = ProcessInfo.processInfo.systemUptime + 15
                repeat {
                    try Task.checkCancellation()
                    guard !stopped, stamp.isFresh(now: ProcessInfo.processInfo.systemUptime, maximumAge: context.backgroundEnabled ? 45 : 5) else { throw AppError.stopped }
                    if let scope = try context.observation(),
                       let fresh = try? frames.encoded(notBefore: scope.after),
                       fresh.capture?.videoOrientation == stamp.videoOrientation,
                       fresh.capture?.width == stamp.width, fresh.capture?.height == stamp.height,
                       SHA256.hash(data: fresh.png) == SHA256.hash(data: approved.png) {
                        permit = USBInputPermit(context: context, observation: scope, sequence: fresh.capture!.sequence)
                        break
                    }
                    try await Task.sleep(nanoseconds: 40_000_000)
                } while ProcessInfo.processInfo.systemUptime < returnDeadline
                guard permit != nil else { throw AppError.unavailable("未在 15 秒内返回匹配的目标画面；未允许发送，需重新截图批准") }
            }
            try await transport.command(body, permit: permit)
            guard !stopped else { throw AppError.stopped }
            // Require an arrival after executed ACK; a pre-ACK frame is insufficient.
            barrierSequence = (try frames.latestStamp()).sequence
            barrierTime = ProcessInfo.processInfo.systemUptime
        } catch { await lost(); throw error }
    }
    func stop() async {
        guard !stopped else { return }
        executionContext?.revoke()
        stopped = true; image = nil; monitor?.cancel(); monitor = nil
        await transport.stop()
    }
}
