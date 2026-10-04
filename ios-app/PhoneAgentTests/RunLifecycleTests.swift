// Ported safety/transaction regression tests from 2509d7098fc8a3af4c62bd8fc20e911df4aa4933.
import XCTest
import LLMProviderKit
@testable import PhoneAgent

@MainActor private final class FakeLease: RunBackgroundLease {
    var expirationHandler: (() -> Void)?
    private(set) var completions: [Bool] = []
    private(set) var reports: [Int] = []
    // The protocol's concrete lease adapter also gates duplicate completion.
    func complete(success: Bool) { if completions.isEmpty { completions.append(success) } }
    func report(completed: Int, subtitle: String) { reports.append(completed) }
}
@MainActor private final class FakeScheduler: RunBackgroundScheduler {
    var reject = false
    var launches: [String: @MainActor (any RunBackgroundLease) -> Void] = [:]
    var identifiers: [String] = []
    var cancellations: [String] = []
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        identifiers.append(identifier); launches[identifier] = launched
        if reject { throw AppError.unavailable("rejected") }
    }
    func cancel(identifier: String) { cancellations.append(identifier) }
    func grant(_ lease: FakeLease = FakeLease()) -> FakeLease {
        launches[identifiers.last!]?(lease); return lease
    }
}
@MainActor private final class FailingJournal: RunCheckpointStorage {
    var checkpoint: RunCheckpoint?
    var fail = false
    func load() throws -> RunCheckpoint? { checkpoint }
    func save(_ checkpoint: RunCheckpoint) throws {
        if fail { throw AppError.unavailable("disk") }
        self.checkpoint = checkpoint
    }
}
@MainActor final class RunLifecycleTests: XCTestCase {
    private let identity = RunIdentity(conversationID: UUID(), runID: UUID())
    private let token = UUID()
    private func tool(_ id: String = "tap") -> RunCheckpoint.Tool {
        .init(callID: id, name: "tap", parameterSummary: "{\"x\":1,\"y\":2}", argumentDigest: "digest")
    }
    func testSuccessfulSubmissionIsNotLeaseAndLateHandlerCannotResumePausedRun() throws {
        let scheduler = FakeScheduler(), store = MemoryRunCheckpointStore()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
        try c.begin(identity: identity, generation: token)
        XCTAssertFalse(c.hasLease)
        var pauses = 0; c.onPause = { _ in pauses += 1 }
        c.setForeground(false)
        let lease = scheduler.grant()
        XCTAssertEqual(c.checkpoint?.phase, .paused)
        XCTAssertFalse(c.hasLease); XCTAssertEqual(pauses, 1)
        XCTAssertEqual(lease.completions, [false])
        XCTAssertTrue(scheduler.identifiers[0].contains(".backgroundRun."))
        XCTAssertFalse(scheduler.identifiers[0].contains("*"))
    }
    func testRejectedLeaseContinuesOnlyForeground() throws {
        let scheduler = FakeScheduler(); scheduler.reject = true
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        try c.begin(identity: identity, generation: token)
        try c.requireExecution(generation: token, backgroundCapable: true)
        XCTAssertTrue(c.backgroundStatus.contains("仅前台"))
        c.setForeground(false)
        XCTAssertEqual(c.checkpoint?.phase, .paused)
        XCTAssertThrowsError(try c.requireExecution(generation: token, backgroundCapable: true))
    }
    func testLeaseAllowsBackgroundModelButNotUnverifiedTool() throws {
        let scheduler = FakeScheduler()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        try c.begin(identity: identity, generation: token)
        let lease = scheduler.grant(); c.setForeground(false)
        try c.requireExecution(generation: token, backgroundCapable: true)
        XCTAssertThrowsError(try c.prepare(tool(), generation: token, backgroundCapable: false))
        XCTAssertEqual(c.checkpoint?.tools.count, 0)
        XCTAssertEqual(lease.completions, [false])
    }
    func testActiveForegroundToolPausesEvenWithLease() throws {
        let scheduler = FakeScheduler()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        try c.begin(identity: identity, generation: token); _ = scheduler.grant()
        try c.prepare(tool(), generation: token, backgroundCapable: false)
        try c.dispatch(callID: "tap", generation: token, backgroundCapable: false)
        c.setForeground(false)
        XCTAssertEqual(c.checkpoint?.tools[0].delivery, .outcomeUnknown)
    }
    func testNewRunDoesNotInheritPreviousForegroundOnlyTool() throws {
        let scheduler = FakeScheduler()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        try c.begin(identity: identity, generation: token); _ = scheduler.grant()
        try c.prepare(tool(), generation: token, backgroundCapable: false)
        c.stop(message: "stop")
        let next = UUID(); try c.begin(identity: identity, generation: next); _ = scheduler.grant()
        c.setForeground(false)
        try c.requireExecution(generation: next, backgroundCapable: true)
        XCTAssertEqual(c.checkpoint?.phase, .running)
        c.stop(message: "cleanup")
    }
    func testExpirationStopAndDuplicateCallbacksCompleteOnceAndFenceNewRun() throws {
        let scheduler = FakeScheduler()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore())
        try c.begin(identity: identity, generation: token)
        let oldID = scheduler.identifiers[0], lease = scheduler.grant()
        scheduler.launches[oldID]?(lease)
        let expire = lease.expirationHandler
        var pauses = 0; c.onPause = { _ in pauses += 1 }
        expire?(); expire?(); c.stop(message: "stop"); c.finish(success: true)
        XCTAssertEqual(pauses, 1); XCTAssertEqual(lease.completions, [false])
        let next = UUID(); try c.begin(identity: identity, generation: next)
        let fresh = scheduler.grant()
        expire?(); scheduler.launches[oldID]?(lease)
        c.activity(generation: token, milestone: "stale")
        c.pause(generation: token, message: "stale failure")
        XCTAssertTrue(c.hasLease); XCTAssertEqual(c.checkpoint?.generation, next)
        XCTAssertEqual(c.checkpoint?.milestones.count, 0); XCTAssertTrue(fresh.completions.isEmpty)
        c.stop(message: "cleanup"); XCTAssertEqual(fresh.completions, [false])
    }
    func testApprovalPersistsAndEndsSegmentThenExplicitApprovalStartsUniqueSegment() throws {
        let scheduler = FakeScheduler(), store = MemoryRunCheckpointStore()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
        try c.begin(identity: identity, generation: token); let first = scheduler.grant()
        try c.prepare(tool(), generation: token, backgroundCapable: true)
        try c.waitForApproval(callID: "tap", generation: token)
        XCTAssertEqual(c.checkpoint?.phase, .waitingApproval)
        XCTAssertEqual(store.value?.pendingApproval, "tap"); XCTAssertEqual(first.completions, [true])
        c.setForeground(false); c.checkInactivity()
        XCTAssertThrowsError(try c.resumeApproved(callID: "tap", digest: "digest", generation: token))
        XCTAssertEqual(scheduler.identifiers.count, 1)
        c.setForeground(true)
        XCTAssertThrowsError(try c.resumeApproved(callID: "tap", digest: "changed", generation: token))
        try c.resumeApproved(callID: "tap", digest: "digest", generation: token)
        XCTAssertEqual(scheduler.identifiers.count, 2)
        XCTAssertEqual(Set(scheduler.identifiers).count, 2); XCTAssertFalse(c.hasLease)
        XCTAssertEqual(c.checkpoint?.segment, 2)
        c.stop(message: "cleanup")
    }
    func testProgressFreezesWithoutRealReceiptsAndPausesOnConfigurableTimeout() throws {
        let scheduler = FakeScheduler(); var clock = Date()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: MemoryRunCheckpointStore(), inactivityTimeout: 10, now: { clock })
        try c.begin(identity: identity, generation: token); let lease = scheduler.grant()
        c.activity(generation: token, milestone: "model:1")
        c.activity(generation: token, milestone: "model:1")
        c.activity(generation: token) // Actual text token: activity, not a completed unit.
        XCTAssertEqual(lease.reports, [0, 1])
        clock.addTimeInterval(11); c.checkInactivity()
        XCTAssertEqual(lease.reports, [0, 1]); XCTAssertEqual(c.checkpoint?.phase, .paused)
        XCTAssertEqual(lease.completions, [false])
    }
    func testDispatchPersistedBeforeTransportAndDiskFailurePreventsSending() throws {
        let scheduler = FakeScheduler(), store = FailingJournal()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
        try c.begin(identity: identity, generation: token)
        try c.prepare(tool(), generation: token, backgroundCapable: true)
        XCTAssertEqual(store.checkpoint?.tools[0].delivery, .prepared)
        store.fail = true
        XCTAssertThrowsError(try c.dispatch(callID: "tap", generation: token, backgroundCapable: true))
        XCTAssertEqual(c.checkpoint?.phase, .paused)
        XCTAssertEqual(store.checkpoint?.tools[0].delivery, .prepared)
    }
    func testDisconnectAndRecoveryNeverReplayUncertainInput() throws {
        let scheduler = FakeScheduler(), store = MemoryRunCheckpointStore()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
        try c.begin(identity: identity, generation: token)
        try c.prepare(tool(), generation: token, backgroundCapable: true)
        try c.dispatch(callID: "tap", generation: token, backgroundCapable: true)
        XCTAssertEqual(store.value?.tools[0].delivery, .dispatching)
        // A fresh process has no lease. Persisted dispatching is ambiguous.
        let recovered = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
        XCTAssertEqual(recovered.checkpoint?.tools[0].delivery, .outcomeUnknown)
        XCTAssertEqual(recovered.checkpoint?.phase, .paused)
        XCTAssertThrowsError(try recovered.dispatch(callID: "tap", generation: token, backgroundCapable: true))
        XCTAssertEqual(scheduler.identifiers.count, 1)
        c.toolFailed(callID: "tap", generation: token)
        XCTAssertEqual(c.checkpoint?.tools[0].delivery, .outcomeUnknown)
        XCTAssertEqual(c.checkpoint?.phase, .paused)
    }
    func testAcknowledgementIsNotVisualObservation() throws {
        let scheduler = FakeScheduler(), store = MemoryRunCheckpointStore()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
        try c.begin(identity: identity, generation: token)
        try c.prepare(tool(), generation: token, backgroundCapable: true)
        try c.dispatch(callID: "tap", generation: token, backgroundCapable: true)
        try c.acknowledge(callID: "tap", generation: token)
        XCTAssertEqual(c.checkpoint?.tools[0].delivery, .acknowledged)
        try c.prepare(tool("screen"), generation: token, backgroundCapable: true)
        try c.dispatch(callID: "screen", generation: token, backgroundCapable: true)
        try c.acknowledge(callID: "screen", generation: token, observation: true)
        XCTAssertEqual(c.checkpoint?.tools[0].delivery, .observedResult)
        XCTAssertEqual(c.checkpoint?.lastConfirmedStep, "screen")
        c.finish(success: true)
    }
    func testFileCheckpointRoundTripPreservesApprovalWithoutExecution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RunCheckpointStore(directory: directory), scheduler = FakeScheduler()
        let c = RunLifecycleCoordinator(scheduler: scheduler, storage: store)
        try c.begin(identity: identity, generation: token)
        try c.prepare(tool(), generation: token, backgroundCapable: true)
        try c.waitForApproval(callID: "tap", generation: token)
        let restored = RunLifecycleCoordinator(scheduler: scheduler, storage: try RunCheckpointStore(directory: directory))
        XCTAssertEqual(restored.checkpoint?.phase, .waitingApproval)
        XCTAssertEqual(restored.checkpoint?.pendingApproval, "tap")
        XCTAssertFalse(restored.hasLease); XCTAssertEqual(scheduler.identifiers.count, 1)
        XCTAssertThrowsError(try restored.resumeApproved(callID: "tap", digest: "digest", generation: token))
        try restored.begin(identity: RunIdentity(conversationID: identity.conversationID, runID: UUID()), generation: UUID())
        XCTAssertEqual(restored.checkpoint?.tools.count, 0)
        restored.stop(message: "cleanup")
        c.stop(message: "cleanup")
    }
}
