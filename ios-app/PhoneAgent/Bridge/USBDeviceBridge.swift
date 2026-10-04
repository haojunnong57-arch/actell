import Foundation

actor USBDeviceBridge: DeviceBridge {
    private let frames: LatestScreenFrame
    private let transport: any USBCommandTransport
    private var stopped = false
    private var image: FrameImage?
    private var barrierSequence: UInt64 = 0
    private var barrierTime: TimeInterval = 0
    private var monitor: Task<Void, Never>?
    private var inputInFlight = false
    private let onLoss: @Sendable () -> Void
    init(frames: LatestScreenFrame, transport: any USBCommandTransport, onLoss: @escaping @Sendable () -> Void = {}) {
        self.frames = frames; self.transport = transport; self.onLoss = onLoss
    }
    func arm() throws {
        _ = try frames.latestStamp()
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
        try await transport.command("PING")
    }
    private func lost() async { guard !stopped else { return }; await stop(); onLoss() }
    func screenshot() async throws -> FrameImage {
        guard !stopped else { throw AppError.stopped }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            try Task.checkCancellation()
            guard !stopped else { throw AppError.stopped }
            if let frame = try? frames.encoded(after: barrierSequence, notBefore: barrierTime) {
                image = frame; return frame
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
        guard stamp.isFresh(now: ProcessInfo.processInfo.systemUptime, maximumAge: 5),
              stamp.videoOrientation == latest.videoOrientation, stamp.width == latest.width, stamp.height == latest.height else {
            await lost(); throw AppError.unavailable("批准画面已过期或方向改变，请重新采集并确认")
        }
        image = nil; inputInFlight = true
        defer { inputInFlight = false }
        do {
            try await transport.command(body)
            guard !stopped else { throw AppError.stopped }
            // Require an arrival after executed ACK; a pre-ACK frame is insufficient.
            barrierSequence = (try frames.latestStamp()).sequence
            barrierTime = ProcessInfo.processInfo.systemUptime
        } catch { await lost(); throw error }
    }
    func stop() async {
        guard !stopped else { return }
        stopped = true; image = nil; monitor?.cancel(); monitor = nil
        await transport.stop()
    }
}
