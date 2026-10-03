import XCTest
import CoreMedia
@testable import PhoneAgent

final class StatusTests: XCTestCase {
    func testPendingApprovalRequiresReturningToApp() {
        let snapshot = AgentStatusSnapshot.make(mode: .live, phase: .running, running: true, awaitingApproval: true)
        XCTAssertEqual(snapshot.phase, .confirmation)
        XCTAssertEqual(snapshot.detail, "请回到 App 查看截图并确认")
        XCTAssertEqual(snapshot.interrupted.phase, .interrupted)
    }
    func testStoppedCardCannotClaimTaskIsRunning() {
        let snapshot = AgentStatusSnapshot.make(mode: .live, phase: .interrupted, running: false, awaitingApproval: false)
        XCTAssertEqual(snapshot.phase, .interrupted)
        XCTAssertEqual(snapshot.title, "当前授权任务")
    }
    @MainActor func testPreviewRendersAValidVideoBuffer() throws {
        let sample = try StatusFrameRenderer.sample(for: .init(isDemo: true, phase: .confirmation))
        XCTAssertTrue(CMSampleBufferIsValid(sample))
        let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        XCTAssertEqual(dimensions.width, 640)
        XCTAssertEqual(dimensions.height, 360)
    }
    @MainActor func testStartingWithoutExplicitPreviewDoesNotStartPiP() {
        let controller = StatusPiPController()
        controller.start()
        XCTAssertFalse(controller.previewEnabled)
        XCTAssertFalse(controller.active)
    }
}
