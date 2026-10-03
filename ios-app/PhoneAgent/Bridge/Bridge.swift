import Foundation

protocol DeviceBridge: Sendable {
    func screenshot() async throws -> FrameImage
    func tap(x: Int, y: Int, imageID: String) async throws
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws
    func stop() async
}
