import XCTest
import UIKit
@testable import PhoneAgent

@MainActor private final class NCMConnectionSpy: NCMControlConnection {
    var ready = true
    var running = false
    var agentReserved = false
    var controlSessionID = UUID()
    var taps = 0
    var drags: [UInt16] = []
    var releases = 0
    var png: Data = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 20), format: {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
    }()).pngData { context in UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 20)) }
    func agentCapture(owner: UUID, session: UUID) async throws -> Data { png }
    func agentTap(owner: UUID, session: UUID, x: UInt16, y: UInt16, validate: () throws -> Void) async throws { try validate(); taps += 1 }
    func agentDrag(owner: UUID, session: UUID, fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16, validate: () throws -> Void) async throws { try validate(); drags = [fromX, fromY, toX, toY, durationMS] }
    func releaseAgent(owner: UUID, session: UUID) { releases += 1 }
}

@MainActor final class NCMDeviceBridgeTests: XCTestCase {
    func testUsesRemotePixelsAndRequiresApprovalBeforeInput() async throws {
        let connection = NCMConnectionSpy(), bridge = try NCMDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        XCTAssertEqual(frame.width, 10); XCTAssertEqual(frame.height, 20); XCTAssertFalse(frame.isDemo)
        do { try await bridge.tap(x: 100, y: 200, imageID: frame.id); XCTFail("unapproved input") } catch {}
        XCTAssertEqual(connection.taps, 0)
        try await bridge.acceptApproval(imageID: frame.id)
        try await bridge.tap(x: 100, y: 200, imageID: frame.id)
        do { try await bridge.tap(x: 100, y: 200, imageID: frame.id); XCTFail("replayed input") } catch {}
        XCTAssertEqual(connection.taps, 1)
    }
    func testReconnectInvalidatesOldRunEvenWhenReadyAgain() async throws {
        let connection = NCMConnectionSpy(), bridge = try NCMDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        try await bridge.authorizeTaskInput(imageID: frame.id)
        connection.controlSessionID = UUID()
        do { try await bridge.tap(x: 0, y: 0, imageID: frame.id); XCTFail("new generation accepted") } catch {}
        do { _ = try await bridge.screenshot(); XCTFail("old run reconnect") } catch {}
        XCTAssertEqual(connection.taps, 0)
    }
    func testDragForwardsNormalizedCoordinatesAndInvalidatesImage() async throws {
        let connection = NCMConnectionSpy(), bridge = try NCMDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        try await bridge.authorizeTaskInput(imageID: frame.id)
        try await bridge.drag(fromX: 0, fromY: 65535, toX: 65535, toY: 0, durationMS: 1000, imageID: frame.id)
        XCTAssertEqual(connection.drags, [0, 65535, 65535, 0, 1000])
        do { try await bridge.tap(x: 0, y: 0, imageID: frame.id); XCTFail("stale image accepted") } catch {}
    }
    func testCancellationFencesBeforeAsynchronousRelease() async throws {
        let connection = NCMConnectionSpy(), bridge = try NCMDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        try await bridge.acceptApproval(imageID: frame.id)
        bridge.cancelTransport()
        do { try await bridge.tap(x: 0, y: 0, imageID: frame.id); XCTFail("cancelled input") } catch {}
        XCTAssertEqual(connection.taps, 0)
        await bridge.stop()
        XCTAssertTrue(connection.ready)
    }
    func testInvalidScreenshotRevokesPreviousImageApproval() async throws {
        let connection = NCMConnectionSpy(), bridge = try NCMDeviceBridge(flow: connection)
        let frame = try await bridge.screenshot()
        try await bridge.acceptApproval(imageID: frame.id)
        connection.png = Data()
        do { _ = try await bridge.screenshot(); XCTFail("invalid PNG accepted") } catch {}
        do { try await bridge.tap(x: 0, y: 0, imageID: frame.id); XCTFail("prior frame reused") } catch {}
        XCTAssertEqual(connection.taps, 0)
    }
    func testDisconnectedConnectionDoesNotFallBackToLocalCapture() throws {
        let connection = NCMConnectionSpy(); connection.ready = false
        XCTAssertThrowsError(try NCMDeviceBridge(flow: connection))
    }
}
