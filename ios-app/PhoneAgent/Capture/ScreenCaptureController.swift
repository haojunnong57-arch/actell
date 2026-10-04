import Foundation
import Combine
import CoreMedia
import UIKit

#if canImport(ScreenCaptureKit) && !targetEnvironment(simulator)
import ScreenCaptureKit

// Picker filters are read-only framework snapshots. Ownership is handed to the
// main actor once; callback code never reads or mutates them after this handoff.
private struct PickerSelection: @unchecked Sendable { let filter: SCContentFilter }

@available(iOS 27.0, *)
final class ScreenSampleSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let frames: LatestScreenFrame
    let epoch: UUID
    init(frames: LatestScreenFrame, epoch: UUID) { self.frames = frames; self.epoch = epoch }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let rawStatus = info[.status] as? Int, let status = SCFrameStatus(rawValue: rawStatus) else { return }
        if status == .stopped || status == .suspended || status == .blank { frames.invalidate(epoch: epoch); return }
        // Idle/blank frames cannot renew the input lease.
        guard status == .complete, let pixel = CMSampleBufferGetImageBuffer(buffer),
              let orientation = (info[.videoOrientation] as? NSNumber)?.uint32Value else { return }
        frames.put(pixel, orientation: orientation,
                   presentationSeconds: buffer.presentationTimeStamp.seconds, epoch: epoch)
    }
}


@available(iOS 27.0, *)
@MainActor final class ScreenCaptureController: NSObject, ObservableObject, SCContentSharingPickerObserver, SCStreamDelegate {
    @Published private(set) var status = "未采集。全屏采集需在系统面板中确认。"
    @Published private(set) var active = false
    let isSupported = true
    let frames = LatestScreenFrame()
    private var stream: SCStream?
    private var sink: ScreenSampleSink?
    private var generation = UUID()
    private var pending = false
    private let sampleQueue = DispatchQueue(label: "phoneagent.capture.latest", qos: .userInitiated)
    var onLoss: (@MainActor () -> Void)?

    override init() { super.init(); SCContentSharingPicker.shared.add(self) }
    func present() {
        guard UIApplication.shared.applicationState == .active, !pending, stream == nil else { return }
        generation = UUID(); pending = true
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.showsMicrophoneControl = false
        config.showsCameraControl = false
        picker.defaultConfiguration = config
        picker.isActive = true
        picker.present() // Full display; intentionally not presentForCurrentApplication().
        status = "等待系统采集授权"
    }
    func stop() async {
        generation = UUID(); pending = false; active = false; frames.invalidate()
        let old = stream; stream = nil; sink = nil
        SCContentSharingPicker.shared.isActive = false
        status = "采集已停止"; onLoss?()
        try? await old?.stopCapture()
    }
    private func start(_ filter: SCContentFilter) async {
        guard pending else { return }
        pending = false
        let token = generation
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        let target = SCStream(filter: filter, configuration: config, delegate: self)
        let output = ScreenSampleSink(frames: frames, epoch: frames.begin())
        stream = target; sink = output
        do {
            try target.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            try await target.startCapture()
            guard generation == token, stream === target else { try? await target.stopCapture(); return }
            active = true; status = "全屏采集中 · 图像仅在本机内存保留"
        } catch { if generation == token { await stop(); status = "系统未能开始采集，请重新授权" } }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let selection = PickerSelection(filter: filter)
        Task { @MainActor [weak self, selection] in await self?.start(selection.filter) }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in await self?.stop() }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in await self?.stop() }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let identity = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard self?.stream.map(ObjectIdentifier.init) == identity else { return }
            self?.frames.invalidate()
            await self?.stop()
        }
    }
}

#else
// Xcode 27A266a does not ship ScreenCaptureKit in its iOS Simulator SDK.
// Fail explicitly; never substitute app snapshots for full display capture.
@MainActor final class ScreenCaptureController: ObservableObject {
    @Published private(set) var status = "此 Simulator SDK 不含 ScreenCaptureKit；需 iOS 27 真机授权"
    @Published private(set) var active = false
    let isSupported = false
    let frames = LatestScreenFrame()
    var onLoss: (@MainActor () -> Void)?
    func present() {}
    func stop() async { frames.invalidate(); onLoss?() }
}
#endif
