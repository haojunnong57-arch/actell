import XCTest

@MainActor final class SiriEntryUITests: XCTestCase {
    private func launch(_ fixture: String = "--ui-test-siri-seed") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", fixture]
        app.launch()
        return app
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testColdRoutePersistsUntilExplicitConfirmationThenStillRequiresToolApproval() {
        var app = launch()
        XCTAssertTrue(app.buttons["confirmSiriTask"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["siriRecognizedTask"].exists)
        XCTAssertEqual(app.textViews["messageInput"].value as? String, "查看演示计数器")
        XCTAssertFalse(app.buttons["approveTool"].exists)
        XCTAssertFalse(app.buttons["stopRun"].exists)
        capture("siri-01-persisted-draft")
        app.terminate()
        app = launch("--ui-test-siri-restore")
        XCTAssertTrue(app.buttons["confirmSiriTask"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews["messageInput"].value as? String, "查看演示计数器")
        capture("siri-02-cold-route")
        app.buttons["confirmSiriTask"].tap()
        XCTAssertTrue(app.buttons["approveTool"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["confirmSiriTask"].exists)
        capture("siri-03-tool-approval-still-required")
        app.buttons["rejectTool"].tap()
        XCTAssertTrue(app.staticTexts["已拒绝"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["stopRun"].exists)
        capture("siri-04-denied")
    }
    func testDismissDoesNotExecuteOrRestorePendingRoute() {
        var app = launch()
        XCTAssertTrue(app.buttons["dismissSiriTask"].waitForExistence(timeout: 10))
        app.buttons["dismissSiriTask"].tap()
        XCTAssertFalse(app.buttons["confirmSiriTask"].exists)
        XCTAssertFalse(app.buttons["stopRun"].exists)
        app.terminate()
        app = launch("--ui-test-siri-restore")
        XCTAssertTrue(app.navigationBars["会话"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["confirmSiriTask"].exists)
    }
    func testWarmIntentRoutesToRecognizedDraft() {
        let app = launch("--ui-test-siri-warm")
        XCTAssertTrue(app.buttons["confirmSiriTask"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews["messageInput"].value as? String, "查看演示计数器")
        XCTAssertFalse(app.buttons["stopRun"].exists)
        capture("siri-05-warm-intent")
    }
    func testBusyIntentKeepsExistingApprovalThenRoutesAfterStop() {
        let app = launch("--ui-test-siri-busy")
        XCTAssertTrue(app.staticTexts["新会话"].waitForExistence(timeout: 10))
        app.staticTexts["新会话"].tap()
        XCTAssertTrue(app.buttons["suggestedPrompt"].waitForExistence(timeout: 5))
        app.buttons["suggestedPrompt"].tap(); app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.buttons["approveTool"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["confirmSiriTask"].exists)
        capture("siri-06-busy-keeps-approval")
        app.buttons["stopRun"].tap()
        XCTAssertTrue(app.buttons["confirmSiriTask"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["stopRun"].exists)
        XCTAssertEqual(app.textViews["messageInput"].value as? String, "查看演示计数器")
        capture("siri-07-deferred-draft")
    }
    func testUIStopStillWorksAfterConfirmation() {
        let app = launch()
        XCTAssertTrue(app.buttons["confirmSiriTask"].waitForExistence(timeout: 10))
        app.buttons["confirmSiriTask"].tap()
        XCTAssertTrue(app.buttons["approveTool"].waitForExistence(timeout: 10))
        app.buttons["stopRun"].tap()
        XCTAssertTrue(app.staticTexts["已停止"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["approveTool"].exists)
    }
}
