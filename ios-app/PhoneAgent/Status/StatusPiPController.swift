import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

/// A user-initiated, paused sample-buffer display experiment, not a background
/// execution facility. No audio samples, video-call APIs, timers or agent access.
@MainActor final class StatusPiPController: NSObject, ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var message = "状态卡片默认关闭"
    @Published var previewEnabled = false
    let displayLayer = AVSampleBufferDisplayLayer()
    let supported = AVPictureInPictureController.isPictureInPictureSupported()
    let backgroundModeConfigured = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []).contains("audio")
    private var controller: AVPictureInPictureController?
    private var foreground = true
    private var starting = false
    private var ownsAudioSession = false
    private var snapshot = AgentStatusSnapshot(isDemo: true, phase: .idle)

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        guard supported else { message = "此设备或模拟器不支持画中画"; return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = false
        pip.requiresLinearPlayback = true
        controller = pip
    }

    func update(_ next: AgentStatusSnapshot) {
        // No ongoing background refresh, even if the OS retains the last frame.
        guard foreground else { return }
        snapshot = next
        if previewEnabled { render() }
    }

    func setForeground(_ value: Bool) {
        foreground = value
        if !value {
            if snapshot.phase == .running || snapshot.phase == .confirmation { snapshot = snapshot.interrupted }
            if previewEnabled { render() } // One final transition frame; never resumes agent work.
        }
    }

    func setPreviewEnabled(_ value: Bool) {
        previewEnabled = value
        if value {
            render()
            message = backgroundModeConfigured ? "仅由你主动开启；状态窗口不会保持 agent 执行" : "仅前台预览：尚未启用系统后台媒体/PiP 配置"
        } else {
            stop()
            displayLayer.flushAndRemoveImage()
            message = "状态卡片已关闭"
        }
    }

    func start() {
        guard foreground, previewEnabled, !starting, !active else { return }
        guard backgroundModeConfigured else {
            message = "此构建未启用后台媒体模式，不能承诺跨 App 显示"
            return
        }
        guard let controller, supported else { message = "当前环境不支持画中画"; return }
        do {
            // Required media-session setup only after an explicit button press.
            // There is no silent audio track or repeated playback to keep the app alive.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            ownsAudioSession = true
            render()
            guard controller.isPictureInPicturePossible else {
                releaseAudioSession()
                message = "系统尚不允许画中画；请保持预览可见后重试"
                return
            }
            starting = true
            message = "正在请求系统画中画"
            controller.startPictureInPicture()
        } catch {
            releaseAudioSession()
            message = "媒体会话不可用；没有启动画中画"
        }
    }

    func stop() {
        if active || starting { controller?.stopPictureInPicture() }
        starting = false
        releaseAudioSession()
    }

    private func releaseAudioSession() {
        guard ownsAudioSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        ownsAudioSession = false
    }

    private func render() {
        do {
            let sample = try StatusFrameRenderer.sample(for: snapshot)
            displayLayer.flushAndRemoveImage()
            displayLayer.enqueue(sample)
            controller?.invalidatePlaybackState()
        } catch { message = "状态画面生成失败；未显示任务内容" }
    }
}

extension StatusPiPController: AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.previewEnabled else { self.controller?.stopPictureInPicture(); return }
            self.starting = false; self.active = true
            self.message = "画中画已开启；离开前台仍会中断 agent"
        }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.starting = false; self.active = false
            self.releaseAudioSession()
            self.message = "画中画已关闭；agent 状态未因此改变"
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.starting = false; self.active = false
            self.releaseAudioSession()
            self.message = "系统未能启动画中画；继续使用 App 内预览"
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // The status card lives in the existing root screen. Restoring never starts a task.
        completionHandler(true)
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        // A system playback control cannot grant approval or resume the agent.
        Task { @MainActor [weak self] in self?.controller?.invalidatePlaybackState() }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { true }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool { true }
}

@MainActor enum StatusFrameRenderer {
    static func sample(for snapshot: AgentStatusSnapshot) throws -> CMSampleBuffer {
        let width = 640, height = 360
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor(red: 0.07, green: 0.10, blue: 0.17, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            func text(_ value: String, y: CGFloat, size: CGFloat, color: UIColor, weight: UIFont.Weight) {
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
                (value as NSString).draw(in: CGRect(x: 32, y: y, width: 576, height: 62), withAttributes: [
                    .font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph
                ])
            }
            text("PHONE AGENT · 状态预览", y: 28, size: 22, color: .lightGray, weight: .semibold)
            text(snapshot.title, y: 83, size: 29, color: .white, weight: .medium)
            text(snapshot.phase.rawValue, y: 143, size: 37, color: .systemTeal, weight: .bold)
            text(snapshot.detail, y: 216, size: 24, color: .white, weight: .regular)
        }
        var pixel: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else { throw AppError.unavailable("状态帧分配失败") }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue), let cgImage = image.cgImage else { throw AppError.unavailable("状态帧绘制失败") }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &description) == noErr, let description else { throw AppError.unavailable("状态帧格式失败") }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: 1, preferredTimescale: 600), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { throw AppError.unavailable("状态帧封装失败") }
        // The single paused snapshot is displayed immediately, without a media loop.
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
