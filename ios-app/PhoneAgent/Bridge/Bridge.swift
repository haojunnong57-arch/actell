import Foundation

protocol DeviceBridge: Sendable {
    func supportsBackgroundExecution(tool: String) async -> Bool
    func approvalContext(imageID: String) async throws -> String
    func acceptApproval(imageID: String) async throws
    func screenshot() async throws -> FrameImage
    func tap(x: Int, y: Int, imageID: String) async throws
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws
    func stop() async
}

extension DeviceBridge {
    func supportsBackgroundExecution(tool: String) async -> Bool { false }
    func approvalContext(imageID: String) async throws -> String { "foreground-only" }
    func acceptApproval(imageID: String) async throws {}
}

struct UnavailableBridge: DeviceBridge {
    func screenshot() async throws -> FrameImage { throw AppError.unavailable("设备未连接。可继续文字对话；设备操作需在设置 → 控制调试中连接桥接。") }
    func tap(x: Int, y: Int, imageID: String) async throws { throw AppError.unavailable("设备未连接") }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { throw AppError.unavailable("设备未连接") }
    func stop() async {}
}
