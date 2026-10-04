import XCTest
import CoreVideo
@testable import PhoneAgent

private final class SyntheticCapture: @unchecked Sendable {
    let frames = LatestScreenFrame()
    let health = USBTransportHealth()
    let token = UUID()
    let epoch: UUID
    private let pixels: [CVPixelBuffer]
    init() throws {
        var result: [CVPixelBuffer] = []
        for byte in [UInt8(60), UInt8(180)] {
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 390, 844, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
                  let pixel else { throw AppError.stopped }
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(byte), CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            result.append(pixel)
        }
        pixels = result; epoch = frames.begin(); health.begin(token); push()
    }
    func push(alternate: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        frames.put(pixels[alternate ? 1 : 0], orientation: 1, presentationSeconds: now, epoch: epoch, now: now)
        health.receivedPing(token, now: now)
    }
}
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}
@MainActor private final class SystemSchedulerSpy: RunBackgroundScheduler {
    var submissions = 0
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws { submissions += 1 }
    func cancel(identifier: String) {}
}
@MainActor private final class TargetState { var changed = false }
private actor GuardedUSBFixture: USBCommandTransport {
    private(set) var inputs: [String] = []
    private(set) var stopped = false
    let delay: UInt64
    let fail: Bool
    let stopDelay: UInt64
    init(delay: UInt64 = 0, fail: Bool = false, stopDelay: UInt64 = 0) { self.delay = delay; self.fail = fail; self.stopDelay = stopDelay }
    func command(_ body: String) async throws { try await command(body, permit: nil) }
    func command(_ body: String, permit: USBInputPermit?) async throws {
        guard !stopped else { throw AppError.stopped }
        if body == "PING" { return }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let enqueue = { self.inputs.append(body) }
        if let permit { try permit.enqueue(enqueue) } else { enqueue() }
        if fail { throw AppError.unknownOutcome }
    }
    func stop() async { stopped = true; if stopDelay > 0 { try? await Task.sleep(nanoseconds: stopDelay) } }
}

final class ScreenUSBPermitTests: XCTestCase {
    func testStaleHeartbeatAndNewCaptureSessionCannotReusePermit() throws {
        let source = try SyntheticCapture(), clock = TestClock()
        source.push(now: clock.now())
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: true, now: { clock.now() })
        context.setScene(.background)
        XCTAssertThrowsError(try context.requireForegroundApproval())
        clock.advance(0.8)
        XCTAssertThrowsError(try context.requireHealthy())
        source.push(now: clock.now()); XCTAssertThrowsError(try context.requireHealthy())
        let next = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: true, now: { clock.now() })
        _ = source.frames.begin()
        XCTAssertThrowsError(try next.requireHealthy())
    }
    func testBackgroundDeadlineCannotBeResetByReturningForegroundAfterExpiry() throws {
        let source = try SyntheticCapture(), clock = TestClock()
        source.push(now: clock.now())
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: true, now: { clock.now() })
        context.setScene(.background); clock.advance(61); source.push(now: clock.now())
        XCTAssertThrowsError(try context.requireHealthy())
        context.setScene(.active)
        XCTAssertThrowsError(try context.requireHealthy())
    }
    func testNewerFrameSceneChangeAndOneShotConsumptionAreFencedAtEnqueue() throws {
        let source = try SyntheticCapture()
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: false)
        let scope = try XCTUnwrap(context.observation())
        var sent = 0
        let stale = USBInputPermit(context: context, observation: scope, sequence: try source.frames.latestStamp().sequence)
        source.push(alternate: true)
        XCTAssertThrowsError(try stale.enqueue { sent += 1 })
        let once = USBInputPermit(context: context, observation: scope, sequence: try source.frames.latestStamp().sequence)
        try once.enqueue { sent += 1 }
        XCTAssertThrowsError(try once.enqueue { sent += 1 })
        let changing = USBInputPermit(context: context, observation: scope, sequence: try source.frames.latestStamp().sequence)
        context.setScene(.inactive)
        XCTAssertThrowsError(try changing.enqueue { sent += 1 })
        XCTAssertEqual(sent, 1)
    }
    func testRevocationWhileTransportActorIsSuspendedPreventsEnqueue() async throws {
        let source = try SyntheticCapture()
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: false)
        let permit = USBInputPermit(context: context, observation: try XCTUnwrap(context.observation()), sequence: try source.frames.latestStamp().sequence)
        let transport = GuardedUSBFixture(delay: 200_000_000)
        let sending = Task { try await transport.command("TAP 1 2", permit: permit) }
        try await Task.sleep(nanoseconds: 50_000_000); context.revoke()
        do { try await sending.value; XCTFail("revoked permit was sent") } catch {}
        let inputs = await transport.inputs; XCTAssertTrue(inputs.isEmpty)
    }
}

@MainActor final class ScreenUSBBackgroundIntegrationTests: XCTestCase {
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw AppError.timeout
    }
    private func model(_ source: SyntheticCapture, transport: GuardedUSBFixture) throws -> AgentViewModel {
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: true)
        let bridge = USBDeviceBridge(frames: source.frames, transport: transport, context: context)
        return AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
                              runServices: .init(provider: DemoProvider(), bridge: bridge))
    }
    func testCaptureExecutionDoesNotSubmitSystemProcessingAndOptOutHasNoFallback() throws {
        let source = try SyntheticCapture(), system = SystemSchedulerSpy()
        let scheduler = RunExecutionScheduler(continued: system)
        let context = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: true)
        scheduler.configure(context: context, allowSystemProcessing: true)
        var lease: (any RunBackgroundLease)?
        try scheduler.submit(identifier: "capture", launched: { lease = $0 })
        XCTAssertNotNil(lease); XCTAssertEqual(system.submissions, 0)
        lease?.complete(success: true); scheduler.cancel(identifier: "capture")
        let optOut = try ScreenUSBExecutionContext(frames: source.frames, health: source.health, backgroundEnabled: false)
        scheduler.configure(context: optOut, allowSystemProcessing: true)
        XCTAssertThrowsError(try scheduler.submit(identifier: "opt-out", launched: { _ in XCTFail() }))
        XCTAssertEqual(system.submissions, 0)
    }
    func testRealAgentRequiresForegroundApprovalThenReturnsToMatchingTarget() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture(stopDelay: 350_000_000)
        let model = try model(source, transport: transport)
        let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        model.start(); model.setScene(.inactive); model.setScene(.background)
        XCTAssertTrue(model.running)
        try await waitUntil { model.approval != nil }
        XCTAssertEqual(model.lifecycle.checkpoint?.phase, .waitingApproval)
        XCTAssertFalse(model.lifecycle.hasLease)
        model.approve(true) // Background/lock-screen approval must be ignored.
        XCTAssertNotNil(model.approval)
        let beforeApproval = await transport.inputs; XCTAssertTrue(beforeApproval.isEmpty)
        model.setScene(.active); model.approve(true)
        try await Task.sleep(nanoseconds: 250_000_000)
        let stillInPhoneAgent = await transport.inputs; XCTAssertTrue(stillInPhoneAgent.isEmpty)
        model.setScene(.inactive); model.setScene(.background)
        try await waitUntil { !model.running }
        let inputs = await transport.inputs
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(model.activeRecord?.phase, .completed)
        XCTAssertEqual(model.lifecycle.checkpoint?.tools.first(where: { $0.name == "tap" })?.delivery, .observedResult)
    }
    func testSiriDraftLiveActivityApprovalHandoffAndBackgroundUSBCompletion() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture()
        let model = try model(source, transport: transport)
        let service = SessionCommandService(sessions: model.sessions, runner: model)
        let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        guard case .prepared(let id) = try service.perform(SessionCommand(.prepare("演示整合流程"))) else { return XCTFail() }
        model.selectConversation(id)
        XCTAssertFalse(model.running)
        XCTAssertFalse(model.send("演示整合流程", in: id))
        XCTAssertTrue(model.send("演示整合流程", in: id, cloudConsent: true))
        model.setScene(.background)
        try await waitUntil { model.approval != nil }
        let run = try XCTUnwrap(model.currentRun), request = try XCTUnwrap(model.approval)
        let stop = service.cancelCurrentCommand()
        XCTAssertEqual(model.activitySnapshot?.state.phase, .awaitingApproval)
        XCTAssertEqual(model.activitySnapshot?.state.approvalID, request.id)
        XCTAssertEqual(try service.perform(SessionCommand(.status)), .status(.awaitingApproval))
        guard case .prepared(let later) = try service.perform(SessionCommand(.prepare("下一条草稿"))) else { return XCTFail() }
        XCTAssertEqual(try service.perform(SessionCommand(.open, sessionID: later)), .deferred)
        XCTAssertEqual(model.currentRun, run)
        let link = AgentActivityRoute(sessionID: run.conversationID, runID: run.runID, approvalID: request.id).url
        XCTAssertTrue(model.openActivityURL(link))
        model.leaveControlDebug() // Settings closes to reveal this same approval.
        XCTAssertTrue(model.running); XCTAssertEqual(model.approval?.id, request.id)
        let before = await transport.inputs; XCTAssertTrue(before.isEmpty)
        model.setScene(.active); model.approve(true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(model.activitySnapshot?.state.phase, .approved)
        let inApp = await transport.inputs; XCTAssertTrue(inApp.isEmpty)
        model.setScene(.background)
        try await waitUntil { !model.running && !model.stopping }
        let after = await transport.inputs; XCTAssertEqual(after.count, 1)
        XCTAssertEqual(model.activitySnapshot?.state.phase, .completed)
        XCTAssertNil(model.activitySnapshot?.state.approvalID)
        XCTAssertEqual(try service.perform(stop), .noMatchingRun)
        XCTAssertEqual(model.sessions.conversation(id)?.entry?.state, .submitted)
        XCTAssertEqual(model.sessions.conversation(later)?.entry?.state, .pendingConfirmation)
        XCTAssertTrue(model.openActivityURL(link)) // Historical link only shows records.
        model.approve(true)
        let repeated = await transport.inputs; XCTAssertEqual(repeated.count, 1)
    }
    func testSiriScopedStopRevokesBackgroundApprovalAndManualDebugExitStillStops() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture()
        let model = try model(source, transport: transport)
        let service = SessionCommandService(sessions: model.sessions, runner: model)
        let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        model.start(); model.setScene(.background)
        try await waitUntil { model.approval != nil }
        let run = try XCTUnwrap(model.currentRun), request = try XCTUnwrap(model.approval)
        XCTAssertEqual(try service.perform(service.cancelCurrentCommand()), .cancelled)
        try await waitUntil { !model.running && !model.stopping }
        XCTAssertFalse(model.approvalRecords.isPending(request, run: run))
        XCTAssertEqual(model.activitySnapshot?.state.phase, .stopped)
        model.setScene(.active); model.approve(true)
        let sent = await transport.inputs, released = await transport.stopped
        XCTAssertTrue(sent.isEmpty); XCTAssertTrue(released)
        let another = try self.model(source, transport: GuardedUSBFixture())
        another.start()
        let newRun = try XCTUnwrap(another.currentRun)
        XCTAssertTrue(another.openActivityURL(AgentActivityRoute(sessionID: newRun.conversationID, runID: newRun.runID, approvalID: nil).url))
        another.enterControlDebug() // A prior link cannot exempt a future manual exit.
        another.leaveControlDebug()
        try await waitUntil { !another.running && !another.stopping }
        XCTAssertEqual(another.activeRecord?.phase, .interrupted)
    }
    func testDifferentTargetCannotSendAndCaptureLossCancelsPendingReturn() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture()
        let model = try model(source, transport: transport)
        let target = TargetState()
        let ticker = Task { while !Task.isCancelled { source.push(alternate: target.changed); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        model.start(); model.setScene(.background)
        try await waitUntil { model.approval != nil }
        model.setScene(.active); model.approve(true)
        target.changed = true; source.push(alternate: true); model.setScene(.background)
        try await Task.sleep(nanoseconds: 400_000_000)
        let inputs = await transport.inputs; XCTAssertTrue(inputs.isEmpty)
        source.frames.invalidate()
        try await waitUntil { !model.running && !model.stopping }
        let released = await transport.stopped; XCTAssertTrue(released)
        model.setScene(.active); model.approve(true)
        let after = await transport.inputs; XCTAssertTrue(after.isEmpty)
    }
    func testLockDuringApprovalStopsAndUnlockNeverResumes() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture()
        let model = try model(source, transport: transport)
        let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        model.start(); model.setScene(.background)
        try await waitUntil { model.approval != nil }
        model.setProtectedDataAvailable(false)
        try await waitUntil { !model.running && !model.stopping }
        model.setProtectedDataAvailable(true); model.setScene(.active); model.approve(true)
        let inputs = await transport.inputs, released = await transport.stopped
        XCTAssertTrue(inputs.isEmpty); XCTAssertTrue(released); XCTAssertFalse(model.running)
    }
    func testUnknownUSBExecutionPersistsUnknownAndNeverReplays() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture(fail: true)
        let model = try model(source, transport: transport)
        let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        model.start(); model.setScene(.background)
        try await waitUntil { model.approval != nil }
        model.setScene(.active); model.approve(true)
        try await Task.sleep(nanoseconds: 100_000_000)
        model.setScene(.background)
        try await waitUntil { !model.running && !model.stopping }
        XCTAssertEqual(model.lifecycle.checkpoint?.tools.first(where: { $0.name == "tap" })?.delivery, .outcomeUnknown)
        model.setScene(.active); model.approve(true)
        let inputs = await transport.inputs; XCTAssertEqual(inputs.count, 1)
    }
    func testCaptureLossWhileAwaitingApprovalReleasesWithoutSending() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture()
        let model = try model(source, transport: transport)
        let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        model.start(); model.setScene(.background)
        try await waitUntil { model.approval != nil }
        source.frames.invalidate()
        try await waitUntil { !model.running && !model.stopping }
        let inputs = await transport.inputs, released = await transport.stopped
        XCTAssertTrue(inputs.isEmpty); XCTAssertTrue(released)
    }
    func testUSBDisconnectWhileAwaitingApprovalStopsAndCannotBeRevived() async throws {
        let source = try SyntheticCapture(), transport = GuardedUSBFixture()
        let model = try model(source, transport: transport)
        let ticker = Task { while !Task.isCancelled { source.push(); try? await Task.sleep(nanoseconds: 90_000_000) } }
        defer { ticker.cancel(); model.stop() }
        model.start(); model.setScene(.background)
        try await waitUntil { model.approval != nil }
        ticker.cancel(); source.health.invalidate()
        try await waitUntil { !model.running && !model.stopping }
        source.push(); model.setScene(.active); model.approve(true)
        let inputs = await transport.inputs, released = await transport.stopped
        XCTAssertTrue(inputs.isEmpty); XCTAssertTrue(released); XCTAssertFalse(model.running)
    }
}
