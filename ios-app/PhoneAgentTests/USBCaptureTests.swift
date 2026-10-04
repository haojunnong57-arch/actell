import XCTest
import CoreVideo
import CryptoKit
@testable import PhoneAgent

private actor USBSpy: USBCommandTransport {
    private(set) var commands: [String] = []
    private(set) var stopped = false
    var failInput: Bool
    let beforeACK: @Sendable () -> Void
    init(failInput: Bool = false, beforeACK: @escaping @Sendable () -> Void = {}) {
        self.failInput = failInput; self.beforeACK = beforeACK
    }
    func command(_ body: String) async throws {
        commands.append(body)
        if body != "PING" {
            beforeACK()
            if failInput { throw AppError.unknownOutcome }
        }
    }
    func stop() async { stopped = true }
}

private struct ImmutableTestPixel: @unchecked Sendable { let pixel: CVPixelBuffer }

final class USBCaptureTests: XCTestCase {
    private func pixel() throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, 4, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let result = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(result, [])
        memset(CVPixelBufferGetBaseAddress(result), 120, CVPixelBufferGetDataSize(result))
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }
    func testLatestOnlyOrientationEncodingAndEpochFence() throws {
        let frames = LatestScreenFrame(), image = try pixel(), epoch = frames.begin()
        for i in 0..<100 { frames.put(image, orientation: 6, presentationSeconds: Double(i), epoch: epoch) }
        let encoded = try frames.encoded(maxDimension: 4)
        XCTAssertEqual(encoded.capture?.sequence, 100)
        XCTAssertEqual(encoded.capture?.width, 8); XCTAssertEqual(encoded.capture?.height, 4)
        XCTAssertEqual(encoded.capture?.videoOrientation, 6)
        XCTAssertEqual(encoded.width, 2); XCTAssertEqual(encoded.height, 4)
        XCTAssertEqual(Array(encoded.png.prefix(8)), [137,80,78,71,13,10,26,10])
        frames.invalidate()
        frames.put(image, orientation: 1, presentationSeconds: 101, epoch: epoch)
        XCTAssertThrowsError(try frames.encoded())
        let newEpoch = frames.begin()
        frames.put(image, orientation: 1, presentationSeconds: 102, epoch: epoch)
        XCTAssertThrowsError(try frames.latestStamp())
        frames.put(image, orientation: 1, presentationSeconds: 103, epoch: newEpoch)
        frames.invalidate(epoch: epoch) // A late stop from the old stream cannot stop the new one.
        XCTAssertNoThrow(try frames.latestStamp())
    }
    func testStaleOrInvalidOrientationCannotAuthorize() throws {
        let frames = LatestScreenFrame(), image = try pixel(), epoch = frames.begin()
        frames.put(image, orientation: 0, presentationSeconds: 1, epoch: epoch)
        XCTAssertThrowsError(try frames.latestStamp())
        frames.put(image, orientation: 1, presentationSeconds: 1, epoch: epoch, now: ProcessInfo.processInfo.systemUptime - 3)
        XCTAssertThrowsError(try frames.latestStamp())
        XCTAssertThrowsError(try frames.encoded())
        let stamp = CaptureStamp(sequence: 1, uptime: 100, presentationSeconds: 1, width: 8, height: 4, videoOrientation: 1)
        XCTAssertFalse(stamp.isFresh(now: 99)); XCTAssertFalse(stamp.isFresh(now: 103))
    }
    func testPostACKBarrierRejectsFrameThatArrivedDuringAction() async throws {
        let frames = LatestScreenFrame(), image = try pixel(), epoch = frames.begin()
        frames.put(image, orientation: 1, presentationSeconds: 1, epoch: epoch)
        let immutable = ImmutableTestPixel(pixel: image)
        let transport = USBSpy(beforeACK: { frames.put(immutable.pixel, orientation: 1, presentationSeconds: 2, epoch: epoch) })
        let bridge = USBDeviceBridge(frames: frames, transport: transport)
        let first = try await bridge.screenshot()
        try await bridge.tap(x: 65535, y: 0, imageID: first.id)
        let waiting = Task { try await bridge.screenshot() }
        try await Task.sleep(nanoseconds: 100_000_000)
        frames.put(image, orientation: 1, presentationSeconds: 3, epoch: epoch)
        let next = try await waiting.value
        XCTAssertEqual(next.capture?.sequence, 3)
        let commands = await transport.commands
        XCTAssertEqual(commands, ["TAP 65535 0"])
        await bridge.stop()
    }
    func testRotationBetweenApprovalAndInputStopsWithoutSending() async throws {
        let frames = LatestScreenFrame(), image = try pixel(), epoch = frames.begin()
        frames.put(image, orientation: 1, presentationSeconds: 1, epoch: epoch)
        let transport = USBSpy(), bridge = USBDeviceBridge(frames: frames, transport: transport)
        let first = try await bridge.screenshot()
        frames.put(image, orientation: 6, presentationSeconds: 2, epoch: epoch)
        do { try await bridge.tap(x: 1, y: 1, imageID: first.id); XCTFail("rotation must fail") } catch {}
        let commands = await transport.commands, stopped = await transport.stopped
        XCTAssertTrue(commands.isEmpty); XCTAssertTrue(stopped)
    }
    func testUnknownOutcomeStopsAndNeverReplays() async throws {
        let frames = LatestScreenFrame(), image = try pixel(), epoch = frames.begin()
        frames.put(image, orientation: 1, presentationSeconds: 1, epoch: epoch)
        let transport = USBSpy(failInput: true), bridge = USBDeviceBridge(frames: frames, transport: transport)
        let first = try await bridge.screenshot()
        for _ in 0..<2 {
            do { try await bridge.tap(x: 1, y: 1, imageID: first.id); XCTFail("input must fail") } catch {}
        }
        let commands = await transport.commands, stopped = await transport.stopped
        XCTAssertEqual(commands.count, 1); XCTAssertTrue(stopped)
    }
    func testStopInvalidatesScreenshotAndFurtherInput() async throws {
        let frames = LatestScreenFrame(), image = try pixel(), epoch = frames.begin()
        frames.put(image, orientation: 1, presentationSeconds: 1, epoch: epoch)
        let transport = USBSpy(), bridge = USBDeviceBridge(frames: frames, transport: transport)
        let first = try await bridge.screenshot(); await bridge.stop()
        do { try await bridge.tap(x: 0, y: 0, imageID: first.id); XCTFail() } catch {}
        do { _ = try await bridge.screenshot(); XCTFail() } catch {}
        let commands = await transport.commands; XCTAssertTrue(commands.isEmpty)
    }
    func testHMACVectorAndSessionDirectionTampering() throws {
        let key = try USBWire.key((0..<32).map { String(format: "%02x", $0) }.joined())
        let payload = "client|" + String(repeating: "0", count: 64) + "|1 TAP 32768 65535"
        let signature = "29e0e0535051be9c63b095eb44a7266f7d919f684df9158a1ab5b14bce5e491b"
        XCTAssertEqual(USBWire.mac(payload, key: key), signature)
        XCTAssertTrue(USBWire.verify(payload, signature: signature, key: key))
        XCTAssertFalse(USBWire.verify(payload + "0", signature: signature, key: key))
        XCTAssertFalse(USBWire.verify(payload.replacingOccurrences(of: "client", with: "server"), signature: signature, key: key))
        XCTAssertThrowsError(try USBWire.key(String(repeating: "z", count: 64)))
    }
    func testReceivedIsNotExecutedAndOutOfOrderACKFails() throws {
        var received = false
        XCTAssertThrowsError(try USBWire.acceptACK("executed", needsReceipt: true, received: &received))
        XCTAssertFalse(try USBWire.acceptACK("received", needsReceipt: true, received: &received))
        XCTAssertTrue(received)
        XCTAssertThrowsError(try USBWire.acceptACK("received", needsReceipt: true, received: &received))
        XCTAssertTrue(try USBWire.acceptACK("executed", needsReceipt: true, received: &received))
        XCTAssertThrowsError(try USBWire.acceptACK("rejected", needsReceipt: true, received: &received))
    }
}
