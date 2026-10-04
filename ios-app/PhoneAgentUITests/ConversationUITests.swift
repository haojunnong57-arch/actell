import XCTest

@MainActor final class ConversationUITests: XCTestCase {
    private func launch(demo: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (demo ? ["--ui-test-demo-history"] : [])
        app.launch()
        return app
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testDeviceControlsReplaceDebugAndSettingsUSBWithoutStartingAnything() {
        let app = launch()
        XCTAssertTrue(app.buttons["deviceControls"].waitForExistence(timeout: 10))
        app.buttons["deviceControls"].tap()
        XCTAssertTrue(app.navigationBars["设备控制"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connectUSBNCM"].exists)
        XCTAssertTrue(app.buttons["startScreenCapture"].exists)
        XCTAssertFalse(app.buttons["startScreenCapture"].isEnabled)
        XCTAssertEqual(app.staticTexts["usbConnectionStatus"].label, "USB 尚未连接")
        for label in ["离线演示", "最新截图", "动作记录", "旧 USB Host 方案", "开始监听"] {
            XCTAssertFalse(app.staticTexts[label].exists)
        }
        capture("device-panel")
        app.buttons["完成"].tap(); app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["controlDebug"].exists)
        XCTAssertFalse(app.staticTexts["USB 连接"].exists)
        capture("settings")
    }
    private func addProvider(_ app: XCUIApplication, name: String, model: String) {
        app.buttons["addProvider"].tap()
        let field = app.textFields["providerName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        let modelField = app.textFields["providerModel"]
        modelField.tap(); modelField.typeText(model)
        app.buttons["saveProvider"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
    }
    func testMultipleProvidersAndSessionModelSelection() {
        let app = launch()
        XCTAssertTrue(app.buttons["openProviders"].waitForExistence(timeout: 10))
        app.buttons["openProviders"].tap()
        addProvider(app, name: "Fixture One", model: "model-a")
        addProvider(app, name: "Fixture Two", model: "model-b")
        capture("providers")
        app.buttons["关闭"].tap(); app.buttons["newConversation"].tap()
        let picker = app.buttons["conversationModelPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap()
        app.buttons["Fixture Two"].tap()
        XCTAssertTrue(picker.label.contains("model-b"))
        picker.tap(); app.buttons["其他模型…"].tap()
        let input = app.alerts.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap(); input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "model-custom")
        app.alerts.buttons["使用"].tap()
        XCTAssertTrue(picker.label.contains("model-custom"))
        capture("conversation-model")
        app.buttons["deviceControls"].tap()
        XCTAssertTrue(app.navigationBars["设备控制"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(picker.label.contains("model-custom"))
    }
    func testProviderRemovalNeedsConfirmationAndCanBeRestored() {
        let app = launch(); app.buttons["openProviders"].tap()
        addProvider(app, name: "Recoverable", model: "model-a")
        app.staticTexts["Recoverable"].swipeLeft(); app.buttons["移除"].tap()
        XCTAssertTrue(app.buttons["移除服务商"].waitForExistence(timeout: 3))
        capture("provider-removal-confirmation")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["Recoverable"].exists)
        app.staticTexts["Recoverable"].swipeLeft(); app.buttons["移除"].tap()
        app.buttons["移除服务商"].tap()
        XCTAssertTrue(app.buttons["恢复"].waitForExistence(timeout: 3))
        app.buttons["恢复"].tap()
        XCTAssertFalse(app.buttons["恢复"].exists)
        XCTAssertTrue(app.staticTexts["Recoverable"].exists)
        capture("provider-restored")
    }
    func testHistoricalDemoStopDoesNotReplayOnReopen() {
        let app = launch(demo: true)
        XCTAssertTrue(app.staticTexts["新会话"].waitForExistence(timeout: 10))
        app.staticTexts["新会话"].tap()
        app.buttons["suggestedPrompt"].tap(); app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.buttons["approveTool"].waitForExistence(timeout: 10))
        app.buttons["stopRun"].tap()
        XCTAssertTrue(app.staticTexts["已停止"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["approveTool"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["查看演示画面，点击计数器一次，再检查结果"].firstMatch.tap()
        XCTAssertFalse(app.buttons["stopRun"].exists)
        XCTAssertFalse(app.buttons["approveTool"].exists)
    }
}
