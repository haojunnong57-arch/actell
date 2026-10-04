import XCTest

@MainActor final class ConversationUITests: XCTestCase {
    private func launch(demoHistory: Bool = false, toolError: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        if demoHistory { app.launchArguments.append("--ui-test-demo-history") }
        if toolError { app.launchArguments.append("--ui-test-tool-error") }
        app.launch()
        return app
    }
    private func capture(_ name: String) {
        // Allow DisclosureGroup/navigation animations to finish before evidence
        // capture; the test runner is a separate process from the app.
        Thread.sleep(forTimeInterval: 0.5)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testConversationListChatApprovalAndResult() {
        let app = launch(demoHistory: true)
        XCTAssertTrue(app.staticTexts["新会话"].waitForExistence(timeout: 10))
        capture("01-conversation-home")
        app.staticTexts["新会话"].tap()
        XCTAssertTrue(app.buttons["suggestedPrompt"].waitForExistence(timeout: 5))
        app.buttons["suggestedPrompt"].tap()
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.buttons["approveTool"].waitForExistence(timeout: 10))
        let card = app.otherElements["approvalCard"]
        XCTAssertTrue(card.exists)
        XCTAssertEqual(app.buttons.matching(identifier: "approveTool").count, 1)
        XCTAssertFalse(app.scrollViews["conversationMessages"].buttons["approveTool"].exists)
        XCTAssertLessThanOrEqual(card.frame.maxY, app.textViews["messageInput"].frame.minY)
        XCTAssertGreaterThan(app.buttons["rejectTool"].frame.minX, card.frame.midX)
        capture("02-chat-approval")
        app.staticTexts["approvalDetailsToggle"].tap()
        XCTAssertTrue(app.staticTexts["请求参数"].waitForExistence(timeout: 5))
        capture("02a-real-tool-parameters")
        app.scrollViews["approvalDetails"].swipeUp()
        app.staticTexts["toolScreenshot-approval"].tap()
        app.scrollViews["approvalDetails"].swipeUp()
        capture("02b-synthetic-screenshot")
        app.staticTexts["approvalDetailsToggle"].tap()
        XCTAssertTrue(app.buttons["approveTool"].isHittable)
        app.buttons["approveTool"].tap()
        XCTAssertTrue(app.staticTexts["已结束"].waitForExistence(timeout: 10))
        XCTAssertFalse(card.exists)
        if app.buttons["滚动到最新消息"].exists { app.buttons["滚动到最新消息"].tap() }
        XCTAssertTrue(app.staticTexts["离线演示完成：已确认一次合成点击并刷新合成截图。没有连接或控制真实设备。"].waitForExistence(timeout: 5))
        capture("03-chat-result")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["会话"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["查看演示画面，点击计数器一次，再检查结果"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["离线演示"].exists)
        XCTAssertFalse(app.staticTexts["已结束"].exists)
        XCTAssertFalse(app.staticTexts["conversation-needs-approval"].exists)
        capture("04-conversation-list")
        app.staticTexts["查看演示画面，点击计数器一次，再检查结果"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已结束"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["approveTool"].exists)
        XCTAssertFalse(app.buttons["stopRun"].exists)
    }
    func testControlDebugLivesUnderSettings() {
        let app = launch()
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 10))
        app.buttons["设置"].tap()
        XCTAssertTrue(app.buttons["controlDebug"].waitForExistence(timeout: 5))
        capture("05-settings")
        app.buttons["controlDebug"].tap()
        XCTAssertTrue(app.navigationBars["控制调试"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["最新截图"].exists)
        capture("06-control-debug")
    }
    func testUSBScreenCaptureRemainsExplicitAndSimulatorReportsUnsupported() {
        let app = launch()
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 10))
        app.buttons["设置"].tap(); app.buttons["controlDebug"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["真实模型"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["真实模型"].tap()
        XCTAssertTrue(app.buttons["connectUSBNCM"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["此 Simulator SDK 不含 ScreenCaptureKit；需 iOS 27 真机授权"].exists)
        XCTAssertEqual(app.switches["screenUploadConsent"].value as? String, "0")
        XCTAssertEqual(app.switches["usbBackgroundConsent"].value as? String, "0")
        XCTAssertFalse(app.buttons["仅在本机预览截图"].isEnabled)
        XCTAssertFalse(app.buttons["startScreenCapture"].isEnabled)
        capture("usb-capture-simulator-unavailable")
    }
    private func pendingDemo(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["新会话"].waitForExistence(timeout: 10))
        app.staticTexts["新会话"].tap()
        XCTAssertTrue(app.buttons["suggestedPrompt"].waitForExistence(timeout: 5))
        app.buttons["suggestedPrompt"].tap()
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.buttons["approveTool"].waitForExistence(timeout: 10))
    }
    func testDenialEndsRoundWithoutExecutingAction() {
        let app = launch(demoHistory: true); pendingDemo(app)
        app.buttons["rejectTool"].tap()
        XCTAssertTrue(app.staticTexts["已拒绝"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["已拒绝这次动作；本轮结束，没有发送该动作"].exists)
        app.staticTexts["已拒绝"].tap()
        XCTAssertTrue(app.staticTexts["用户拒绝；该动作未发送。本轮结束，不会自动重试。"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["approveTool"].exists)
        XCTAssertFalse(app.buttons["stopRun"].exists)
        XCTAssertFalse(app.otherElements["approvalCard"].exists)
        capture("07-denied")
    }
    func testToolFailureShowsConcreteResultAndAgentContinuesReplying() {
        let app = launch(toolError: true)
        XCTAssertTrue(app.staticTexts["新会话"].waitForExistence(timeout: 10))
        app.staticTexts["新会话"].tap()
        let input = app.textViews["messageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("View screen\n")
        XCTAssertTrue(app.staticTexts["已结束"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["失败"].exists)
        XCTAssertTrue(app.staticTexts["当前没有连接设备，暂时无法查看屏幕。连接桥接后可以再试；我们也可以继续文字对话。"].exists)
        let reason = "设备未连接。可继续文字对话；设备操作需在设置 → 控制调试中连接桥接。"
        XCTAssertFalse(app.staticTexts[reason].exists) // No separate notice outside the closed tool.
        app.staticTexts["失败"].tap()
        XCTAssertTrue(app.staticTexts[reason].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: reason).count, 1)
        XCTAssertTrue(app.otherElements["tool-invocation-failed-screenshot"].staticTexts[reason].exists)
        XCTAssertFalse(app.staticTexts["工具执行失败，后续动作已停止"].exists)
        XCTAssertFalse(app.buttons["stopRun"].exists)
        capture("13-tool-error-followed-by-agent-reply")
    }
    func testStopDuringApprovalAndHistoryDoesNotRestart() {
        let app = launch(demoHistory: true); pendingDemo(app)
        app.buttons["stopRun"].tap()
        XCTAssertTrue(app.staticTexts["已停止"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已取消"].exists)
        XCTAssertFalse(app.otherElements["approvalCard"].exists)
        capture("08-stopped")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["查看演示画面，点击计数器一次，再检查结果"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已停止"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["approveTool"].exists)
        XCTAssertFalse(app.buttons["stopRun"].exists)
    }
    func testLeavingControlDebugInterruptsPendingRun() {
        let app = launch()
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 10))
        app.buttons["设置"].tap(); app.buttons["controlDebug"].tap()
        XCTAssertTrue(app.buttons["debugStart"].waitForExistence(timeout: 5))
        app.buttons["debugStart"].tap()
        let pending = NSPredicate(format: "label CONTAINS %@", "等待确认一次动作")
        expectation(for: pending, evaluatedWith: app.staticTexts["debugStatus"])
        waitForExpectations(timeout: 10)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.navigationBars["会话"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["已中断"].exists)
        XCTAssertFalse(app.staticTexts["conversation-needs-approval"].exists)
        app.staticTexts["查看演示画面，点击计数器一次，再检查结果"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已中断"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["approveTool"].exists)
        capture("09-debug-exit-interrupted")
    }
    func testNewConversationOpensLiveWithoutModePicker() {
        let app = launch()
        XCTAssertTrue(app.buttons["newConversation"].waitForExistence(timeout: 10))
        app.buttons["newConversation"].tap()
        XCTAssertTrue(app.textViews["messageInput"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["选择这次会话的方式"].exists)
        XCTAssertFalse(app.buttons["createDemoConversation"].exists)
        XCTAssertFalse(app.staticTexts["离线脚本 · 合成屏幕"].exists)
        XCTAssertTrue(app.staticTexts["真实模型 · 尚未配置"].exists)
        XCTAssertFalse(app.buttons["sendMessage"].isEnabled)
        capture("10-new-live-conversation")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["会话"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["新会话"].exists)
        XCTAssertFalse(app.staticTexts["真实模型"].exists)
        XCTAssertFalse(app.staticTexts["准备就绪"].exists)
        XCTAssertFalse(app.staticTexts["conversation-needs-approval"].exists)
        app.buttons["newConversationToolbar"].tap()
        XCTAssertTrue(app.textViews["messageInput"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["离线脚本 · 合成屏幕"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(app.staticTexts.matching(identifier: "新会话").count, 2)
        XCTAssertFalse(app.staticTexts["真实模型"].exists)
        capture("12-compact-conversation-list")
    }
    func testKeyboardReturnSendsNonemptyTextOnly() {
        let app = launch(demoHistory: true)
        XCTAssertTrue(app.staticTexts["新会话"].waitForExistence(timeout: 10))
        app.staticTexts["新会话"].tap()
        let input = app.textViews["messageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("   \n")
        XCTAssertFalse(app.buttons["sendMessage"].isEnabled)
        XCTAssertFalse(app.buttons["approveTool"].exists)
        XCTAssertFalse(app.buttons["stopRun"].exists)
        input.tap()
        input.typeText("Return test\n")
        XCTAssertTrue(app.buttons["approveTool"].waitForExistence(timeout: 10))
        // The navigation title also becomes the first query; count only messages.
        XCTAssertEqual(app.scrollViews.firstMatch.staticTexts.matching(identifier: "Return test").count, 1)
        XCTAssertEqual(input.value as? String, "")
        capture("11-keyboard-send")
        app.buttons["stopRun"].tap()
        XCTAssertTrue(app.staticTexts["已停止"].waitForExistence(timeout: 5))
    }
}
