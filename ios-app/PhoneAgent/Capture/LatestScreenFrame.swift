import Foundation
import CoreVideo
import CoreImage
import ImageIO

struct CaptureStamp: Sendable, Equatable {
    let sequence: UInt64
    let uptime: TimeInterval
    let presentationSeconds: Double
    let width: Int
    let height: Int
    let videoOrientation: UInt32
    func isFresh(now: TimeInterval, maximumAge: TimeInterval = 2) -> Bool {
        let age = now - uptime
        return age >= 0 && age <= maximumAge
    }
}

// One retained pixel buffer, no per-frame Task or PNG backlog. All access is locked.
final class LatestScreenFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var frame: (CVPixelBuffer, CaptureStamp, Date)?
    private var accepting = false
    private var epoch = UUID()
    private let context = CIContext(options: [.cacheIntermediates: false])

    @discardableResult func begin() -> UUID {
        lock.withLock { epoch = UUID(); accepting = true; frame = nil; return epoch }
    }
    func invalidate(epoch expected: UUID? = nil) {
        lock.withLock {
            guard expected == nil || expected == epoch else { return }
            accepting = false; frame = nil; epoch = UUID()
        }
    }
    func put(_ pixel: CVPixelBuffer, orientation: UInt32, presentationSeconds: Double,
             epoch expected: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            guard accepting, epoch == expected, (1...8).contains(orientation), presentationSeconds.isFinite else { return }
            sequence += 1
            frame = (pixel, CaptureStamp(sequence: sequence, uptime: now,
                presentationSeconds: presentationSeconds, width: CVPixelBufferGetWidth(pixel),
                height: CVPixelBufferGetHeight(pixel), videoOrientation: orientation), Date())
        }
    }
    func latestStamp(now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> CaptureStamp {
        try lock.withLock {
            guard accepting, let stamp = frame?.1, stamp.isFresh(now: now) else {
                throw AppError.unavailable("屏幕采集已停止或超过 2 秒未更新；输入已禁用")
            }
            return stamp
        }
    }
    func encoded(after sequence: UInt64 = 0, notBefore uptime: TimeInterval = 0,
                 maxDimension: Int = 1280) throws -> FrameImage {
        let snapshot = try lock.withLock { () throws -> (CVPixelBuffer, CaptureStamp, Date, UUID) in
            guard accepting, let (pixel, stamp, date) = frame,
                  stamp.sequence > sequence, stamp.uptime > uptime,
                  stamp.isFresh(now: ProcessInfo.processInfo.systemUptime) else { throw AppError.unavailable("等待动作之后的新画面") }
            return (pixel, stamp, date, epoch)
        }
        let (pixel, stamp, date, capturedEpoch) = snapshot
        var image = CIImage(cvPixelBuffer: pixel).oriented(forExifOrientation: Int32(stamp.videoOrientation))
        let scale = min(1, CGFloat(max(1, maxDimension)) / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(image, from: image.extent.integral) else {
            throw AppError.unavailable("无法编码采集画面")
        }
        let data = NSMutableData()
        guard let png = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw AppError.unavailable("PNG 编码不可用") }
        CGImageDestinationAddImage(png, cgImage, nil)
        guard CGImageDestinationFinalize(png) else { throw AppError.unavailable("PNG 编码失败") }
        try lock.withLock {
            guard accepting, epoch == capturedEpoch, stamp.isFresh(now: ProcessInfo.processInfo.systemUptime) else { throw AppError.stopped }
        }
        return FrameImage(id: "sck-\(capturedEpoch.uuidString)-\(stamp.sequence)", png: data as Data,
                          width: cgImage.width, height: cgImage.height, capturedAt: date, isDemo: false, capture: stamp)
    }
}
