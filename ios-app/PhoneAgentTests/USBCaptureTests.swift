import XCTest
import CoreVideo
import Network
import Darwin
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
    func testNoPSKGreetingRequiresExplicitPA2Version() throws {
        XCTAssertFalse(try USBWire.supportsHID("PA2 READY 0"))
        XCTAssertTrue(try USBWire.supportsHID("PA2 READY 1"))
        for line in ["PA1 LOCKED", "PA1 CHALLENGE " + String(repeating: "0", count: 64),
                     "READY 1", "PA2 READY 2", "PA2 READY 1 ", " PA2 READY 1", "PA2  READY 1"] {
            XCTAssertThrowsError(try USBWire.supportsHID(line), line)
        }
    }
    func testACKRequiresCanonicalIDAndExactPhase() throws {
        let ack = try USBWire.parseACK("4294967295 executed")
        XCTAssertEqual(ack.id, UInt64(UInt32.max)); XCTAssertEqual(ack.phase, "executed")
        XCTAssertEqual(try USBWire.parseACK("1 received").phase, "received")
        for line in ["0 executed", "01 executed", "+1 executed", "4294967296 executed", "1 EXECUTED",
                     "1 executed mac", "1  executed", "1 executed ", "1\texecuted", "1 rejected"] {
            XCTAssertThrowsError(try USBWire.parseACK(line), line)
        }
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
    func testTransportFailureReportsNetworkErrorBeforeInputButPreservesUnknownInputOutcome() {
        let error = NWError.posix(.ENETUNREACH)
        let beforeInput = USBWire.transportError(error, inputInFlight: false)
        guard case .unavailable(let message) = beforeInput else { return XCTFail("A failed connection is not a sent HID action") }
        XCTAssertTrue(message.contains(String(POSIXErrorCode.ENETUNREACH.rawValue)))
        XCTAssertEqual(USBWire.transportError(error, inputInFlight: true), .unknownOutcome)
        XCTAssertEqual(USBWire.transportError(nil, inputInFlight: true), .unknownOutcome)
    }
    func testHeartbeatTimeoutKeepsConcurrentInputOutcomeUnknown() {
        XCTAssertEqual(USBWire.receiptTimeout(isPing: true, inputInFlight: true), .unknownOutcome)
        XCTAssertEqual(USBWire.receiptTimeout(isPing: false, inputInFlight: true), .unknownOutcome)
        guard case .unavailable(let message) = USBWire.receiptTimeout(isPing: true, inputInFlight: false) else { return XCTFail() }
        XCTAssertTrue(message.contains("PING"))
        var received = false
        XCTAssertThrowsError(try USBWire.acceptACK("received", needsReceipt: false, received: &received)) { error in
            XCTAssertEqual(error as? AppError, .protocolViolation("USB ACK 阶段不匹配"))
        }
    }
    func testPermissionSheetOnlyPreservesInitialUSBSetupAndNeverBackground() {
        let setup: [USBConnectionStatus] = [.connecting, .waiting("localNetworkDenied"), .awaitingGreeting, .checking]
        for state in setup {
            XCTAssertTrue(state.allowsSetup(in: .active))
            XCTAssertTrue(state.allowsSetup(in: .inactive), "An initial permission sheet must not cancel setup")
            XCTAssertFalse(state.allowsSetup(in: .background), "Leaving the app must still cancel setup")
        }
        for state in [USBConnectionStatus.idle, .ready(hid: false), .ready(hid: true), .failed("down"), .disconnected("stopped")] {
            XCTAssertFalse(state.allowsSetup(in: .inactive), "Existing input sessions must retain the old stop policy")
            XCTAssertFalse(state.allowsSetup(in: .background))
        }
    }
    private func interfaceRow(name: String = "en77", index: UInt32 = 77,
                              address: String = "192.168.7.2", mask: String = "255.255.255.0",
                              flags: UInt32 = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST),
                              linkType: UInt8? = UInt8(IFT_ETHER)) -> USBInterfaceBinding.Row {
        USBInterfaceBinding.Row(name: name, index: index, address: address, mask: mask, flags: flags, linkType: linkType)
    }
    func testUSBInterfaceSelectionUsesFixedIPNotInterfaceNameOrDefaultPath() throws {
        let usb = interfaceRow(name: "en77")
        let unrelated = interfaceRow(name: "en0", address: "192.168.1.2")
        XCTAssertEqual(try USBInterfaceBinding.select([unrelated, usb]), usb)
    }
    func testUSBInterfaceSelectionRejectsMissingAmbiguousAndUnsafeInterfaces() {
        XCTAssertThrowsError(try USBInterfaceBinding.select([]))
        XCTAssertThrowsError(try USBInterfaceBinding.select([interfaceRow(), interfaceRow(name: "en88", index: 88)]))
        let complete = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
        let invalid = [interfaceRow(index: 0), interfaceRow(mask: "255.255.0.0"),
                       interfaceRow(flags: complete & ~UInt32(IFF_UP)),
                       interfaceRow(flags: complete & ~UInt32(IFF_RUNNING)),
                       interfaceRow(flags: complete & ~UInt32(IFF_BROADCAST)),
                       interfaceRow(flags: complete | UInt32(IFF_POINTOPOINT)),
                       interfaceRow(flags: complete | UInt32(IFF_LOOPBACK)),
                       interfaceRow(linkType: nil), interfaceRow(linkType: 0)]
        for row in invalid { XCTAssertThrowsError(try USBInterfaceBinding.select([row]), "\(row)") }
    }
    func testUSBInterfaceTypeNeverPermitsWiFiCellularOrLoopback() {
        XCTAssertNoThrow(try USBInterfaceBinding.validateType(.wiredEthernet))
        XCTAssertNoThrow(try USBInterfaceBinding.validateType(.other)) // Physical checks precede this classification.
        for type in [NWInterface.InterfaceType.wifi, .cellular, .loopback] {
            XCTAssertThrowsError(try USBInterfaceBinding.validateType(type))
        }
    }
    func testScopedAddressAndParametersRequireExactInterfaceWithoutConnecting() throws {
        // Exercise the actual public Network parser and parameter objects on
        // loopback; no socket/connection or device traffic is created.
        let address = try XCTUnwrap(IPv4Address("127.0.0.1%lo0"))
        let interface = try XCTUnwrap(address.interface)
        XCTAssertEqual(interface.name, "lo0")
        XCTAssertEqual(interface.index, Int(if_nametoindex("lo0")))
        XCTAssertNil(IPv4Address("192.168.7.1%phoneagent_missing_interface_999"))
        let binding = USBInterfaceBinding(row: interfaceRow(name: "lo0", index: UInt32(interface.index)),
                                          interface: interface, localAddress: address, remoteAddress: address)
        let parameters = binding.parameters()
        XCTAssertEqual(parameters.requiredInterface, interface)
        XCTAssertEqual(parameters.requiredLocalEndpoint, .hostPort(host: .ipv4(address), port: .any))
        XCTAssertFalse(parameters.includePeerToPeer)
    }
    func testUSBResolveRejectsStaleIndexAndDoesNotTrustInventedPhysicalFlags() {
        let loopback = if_nametoindex("lo0")
        XCTAssertGreaterThan(loopback, 0)
        XCTAssertThrowsError(try USBInterfaceBinding.resolve([interfaceRow(name: "lo0", index: loopback + 10000)]))
        // Even if a row claims to be Ethernet, the framework's loopback type
        // must still prevent the connection from being created.
        XCTAssertThrowsError(try USBInterfaceBinding.resolve([interfaceRow(name: "lo0", index: loopback)]))
    }
    func testDiagnosticRingKeepsRecentEventsAndAttemptIdentity() throws {
        let log = USBDiagnosticsLog(capacity: 3, console: false)
        let first = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let second = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        log.record("connect.begin", attempt: first)
        log.record("timeout.setup", attempt: first)
        log.record("connect.begin", attempt: second)
        log.record("connection.state=preparing", attempt: second)
        let report = log.report()
        XCTAssertTrue(report.contains("retained=3 dropped=1"))
        XCTAssertFalse(report.contains("#1 [11111111]"))
        XCTAssertTrue(report.contains("#2 [11111111] timeout.setup"))
        XCTAssertTrue(report.contains("#4 [22222222] connection.state=preparing"))
        XCTAssertTrue(report.contains(USBDiagnosticsLog.revision))
    }
    func testDiagnosticConcurrentWritesRemainBoundedAndCannotForgeLines() {
        let log = USBDiagnosticsLog(capacity: 16, console: false)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in log.record("state\nforged\rline") }
        log.record(String(repeating: "x", count: 10_000))
        let report = log.report()
        let events = report.split(separator: "\n").filter { $0.contains(" [app] ") }
        XCTAssertEqual(events.count, 16)
        XCTAssertTrue(report.contains("retained=16 dropped=185"))
        XCTAssertTrue(events.first?.contains("#186 [app]") == true)
        XCTAssertTrue(events.last?.contains("#201 [app]") == true)
        XCTAssertFalse(report.contains("\nforged"))
        XCTAssertLessThan(events.last?.count ?? Int.max, 1750)
    }
    func testDiagnosticCommandLabelsAndInterfaceAddressesOmitUnrelatedData() {
        let log = USBDiagnosticsLog(console: false)
        for body in ["TAP 12345 54321", "DRAG 12345 54321 23456 65432 100", "UNRECOGNIZED secret-value"] {
            log.record("kind=\(USBDiagnosticsLog.commandKind(body)); arguments omitted")
        }
        XCTAssertFalse(log.report().contains("12345"))
        XCTAssertFalse(log.report().contains("secret-value"))
        XCTAssertEqual(USBDiagnosticsLog.commandKind("PING"), "PING")
        XCTAssertEqual(USBDiagnosticsLog.visibleIPv4("192.168.7.2"), "192.168.7.2")
        XCTAssertEqual(USBDiagnosticsLog.visibleIPv4("169.254.10.20"), "169.254.10.20")
        XCTAssertFalse(USBDiagnosticsLog.visibleIPv4("10.20.30.40").contains("10.20.30.40"))
    }
    @MainActor func testUSBConnectGuardShowsFailureWithoutOpeningTransport() {
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false)
        model.goal = "private-task-must-not-appear-in-diagnostics"
        model.setForeground(false)
        model.connectUSB()
        XCTAssertTrue(model.usbConnectionStatus.isFailure)
        XCTAssertTrue(model.usbConnectionStatus.message.contains("前台"))
        XCTAssertFalse(model.isListening)
        model.setForeground(true); model.stopping = true
        model.connectUSB()
        XCTAssertTrue(model.usbConnectionStatus.isFailure)
        XCTAssertTrue(model.usbConnectionStatus.message.contains("停止"))
        XCTAssertFalse(model.isListening)
        let report = model.usbDiagnosticReport()
        XCTAssertTrue(report.contains("rejected=notForeground"))
        XCTAssertTrue(report.contains("rejected=runningOrStopping"))
        XCTAssertFalse(report.contains("connect.begin"))
        XCTAssertFalse(report.contains(model.goal))
    }
}
