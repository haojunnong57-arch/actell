import Foundation

protocol DeviceBridge: Sendable {
    /// Explicit tool capability, independently of the background CPU lease.
    func supportsBackgroundExecution(tool: String) async -> Bool
    /// Re-check device session and screenshot after the user approves.
    func approvalContext(imageID: String) async throws -> String
    func screenshot() async throws -> FrameImage
    func tap(x: Int, y: Int, imageID: String) async throws
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws
    func cancelTransport()
    func stop() async
}

struct UnavailableBridge: DeviceBridge {
    func screenshot() async throws -> FrameImage { throw AppError.unavailable("设备未连接。可继续文字对话；设备操作需在设置 → 控制调试中连接桥接。") }
    func tap(x: Int, y: Int, imageID: String) async throws { throw AppError.unavailable("设备未连接") }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { throw AppError.unavailable("设备未连接") }
    func stop() async {}
}

// Unverified bridges fail closed for background use. Test bridges can opt in.
extension DeviceBridge {
    func cancelTransport() {}
    func supportsBackgroundExecution(tool: String) async -> Bool { false }
    func approvalContext(imageID: String) async throws -> String { "foreground-only" }
}
