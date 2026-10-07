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
    func testExpandingLongReasoningAndToolKeepsDisclosureInPlace() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-disclosure-scroll"]
        app.launch()
        app.staticTexts["新会话"].firstMatch.tap()
        XCTAssertTrue(app.scrollViews["conversationMessages"].waitForExistence(timeout: 5))
        for title in ["思考", "查询 App"] {
            let toggle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            for _ in 0..<3 {
                XCTAssertTrue(toggle.isHittable)
                let before = toggle.frame.minY
                toggle.tap()
                // Wait through layout/animation; a bottom jump hides the header
                // above the viewport when the expanded body spans many screens.
                let jumped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    !toggle.isHittable || abs(toggle.frame.minY - before) >= 12
                }, object: app)
                jumped.isInverted = true
                XCTAssertEqual(XCTWaiter.wait(for: [jumped], timeout: 1.5), .completed)
                XCTAssertTrue(toggle.isHittable)
                toggle.tap()
            }
        }
        capture("disclosure-reading-position")
    }
    func testLongToolResultScrollsInsideBoundedCardToItsEnd() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-disclosure-scroll"]
        app.launch(); app.staticTexts["新会话"].firstMatch.tap()
        let toggle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "查询 App")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
        let card = app.scrollViews["toolResultScroll"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(card.frame.height, 321)
        app.scrollViews["conversationMessages"].swipeUp()
        let headerY = toggle.frame.minY
        let tail = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "工具结果末尾标记")).firstMatch
        for _ in 0..<15 {
            let last = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            last.press(forDuration: 0.05, thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
        XCTAssertTrue(tail.exists)
        XCTAssertEqual(card.value as? String, "已到末尾")
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(toggle.frame.minY, headerY, accuracy: 12)
        capture("tool-result-internal-scroll")
    }
    func testDeviceControlsAndSettingsDoNotStartAnything() {
        let app = launch()
        XCTAssertFalse(app.buttons["openProviders"].exists)
        XCTAssertFalse(app.buttons["deviceControls"].exists)
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["openProviders"].exists)
        XCTAssertTrue(app.buttons["esp32ControlSettings"].exists)
        capture("settings")
        app.buttons["esp32ControlSettings"].tap()
        XCTAssertTrue(app.navigationBars["ESP32 控制"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["startScreenCapture"].exists)
        capture("device-panel")
    }
    private func openProviders(_ app: XCUIApplication) {
        XCTAssertFalse(app.buttons["openProviders"].exists)
        app.buttons["设置"].tap()
        XCTAssertTrue(app.buttons["openProviders"].waitForExistence(timeout: 5))
        app.buttons["openProviders"].tap()
        XCTAssertTrue(app.navigationBars["服务商"].waitForExistence(timeout: 5))
    }
    private func closeProviders(_ app: XCUIApplication) {
        app.navigationBars["服务商"].buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
    }
    private func addProvider(_ app: XCUIApplication, name: String, model: String) {
        app.buttons["addProvider"].tap()
        let field = app.textFields["providerName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.tap(); field.typeText(name)
        let modelField = app.textFields["providerModel"]
        modelField.tap(); modelField.tap(); modelField.typeText(model)
        app.buttons["saveProvider"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
    }
    func testMultipleProvidersAndSessionModelSelection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-composer-models"]
        app.launch()
        openProviders(app)
        XCTAssertTrue(app.staticTexts["Fixture One"].exists)
        XCTAssertTrue(app.staticTexts["Fixture Two"].exists)
        capture("providers")
        closeProviders(app); app.buttons["newConversation"].tap()
        let picker = app.buttons["conversationModelPicker"]
        XCTAssertFalse(picker.exists)
        app.textViews["messageInput"].tap()
        app.textViews["messageInput"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap()
        app.buttons["Fixture Two"].tap()
        if app.buttons["Fixture Two"].exists { app.buttons["Fixture Two"].tap() }
        if !picker.exists { app.textViews["messageInput"].tap() }
        let selectedProvider = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "model-b"), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [selectedProvider], timeout: 5), .completed)
        picker.tap(); app.buttons["其他模型…"].tap()
        let input = app.alerts.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap(); input.tap(); input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "model-custom")
        XCTAssertEqual(input.value as? String, "model-custom")
        // Finish keyboard editing before tapping the alert action; iOS 27
        // relocates this alert while the software keyboard is visible.
        input.typeText("\n")
        if app.alerts.buttons["使用"].exists { app.alerts.buttons["使用"].tap() }
        app.textViews["messageInput"].tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "model-custom"), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        capture("conversation-model")
        XCTAssertFalse(app.buttons["deviceControls"].exists)
        XCTAssertFalse(app.buttons["设置"].exists)
        XCTAssertFalse(app.buttons["滚动到最新消息"].exists)
        let add = app.buttons["addAttachment"].frame
        let send = app.buttons["sendMessage"].frame
        XCTAssertEqual(add.midY, send.midY, accuracy: 1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["deviceControls"].exists)
        app.buttons["设置"].tap()
        app.buttons["esp32ControlSettings"].tap()
        XCTAssertTrue(app.navigationBars["ESP32 控制"].waitForExistence(timeout: 5))
    }
    func testComposerActivationPreservesVisibleBottomAndMovesActionsBelowText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-composer-history"]
        app.launch()
        app.staticTexts["新会话"].firstMatch.tap()
        let input = app.textViews["messageInput"]
        let last = app.staticTexts["滚动验收最后一条消息"]
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["conversationModelPicker"].exists)
        print("Collapsed viewport", app.scrollViews["conversationMessages"].value ?? "", "input", input.frame, "last", last.frame)
        let collapsedGap = input.frame.minY - last.frame.maxY
        let add = app.buttons["addAttachment"]
        let send = app.buttons["sendMessage"]
        XCTAssertEqual(add.frame.midY, send.frame.midY, accuracy: 1)
        XCTAssertLessThan(abs(add.frame.midY - input.frame.midY), 2)
        capture("composer-collapsed")
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["conversationModelPicker"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(add.frame.minY, input.frame.midY)
        XCTAssertGreaterThan(send.frame.minY, input.frame.midY)
        XCTAssertEqual(add.frame.midY, send.frame.midY, accuracy: 1)
        print("Expanded viewport", app.scrollViews["conversationMessages"].value ?? "", "input", input.frame, "last exists", last.exists)
        let bottomKept = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            last.exists && abs(input.frame.minY - last.frame.maxY - collapsedGap) < 12
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [bottomKept], timeout: 5), .completed)
        capture("composer-expanded-keyboard")
        app.scrollViews["conversationMessages"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.keyboards.firstMatch.exists && last.exists && abs(input.frame.minY - last.frame.maxY - collapsedGap) < 12
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["conversationModelPicker"].exists)
        capture("composer-keyboard-dismissed")
    }
    func testKeyboardPreservesBottomContentWhileReadingHistory() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-composer-history"]
        app.launch()
        app.staticTexts["新会话"].firstMatch.tap()
        let input = app.textViews["messageInput"]
        XCTAssertTrue(app.staticTexts["滚动验收最后一条消息"].waitForExistence(timeout: 5))
        app.scrollViews["conversationMessages"].swipeDown()
        let markers = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "滚动验收 ")).allElementsBoundByIndex
        let visible = markers.filter { $0.frame.minY > 116 && $0.frame.maxY < input.frame.minY }
        guard let selectedMarker = visible.max(by: { $0.frame.maxY < $1.frame.maxY }) else { return XCTFail("缺少底部可见的历史消息") }
        let marker = app.staticTexts[selectedMarker.label]
        let gap = input.frame.minY - marker.frame.maxY
        print("History before", app.scrollViews["conversationMessages"].value ?? "", marker.label, "gap", gap)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let preserved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            marker.exists && abs(input.frame.minY - marker.frame.maxY - gap) < 12
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [preserved], timeout: 5), .completed)
        print("History after", app.scrollViews["conversationMessages"].value ?? "", "gap", input.frame.minY - marker.frame.maxY)
        capture("composer-history-keyboard")
        app.scrollViews["conversationMessages"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.keyboards.firstMatch.exists && marker.exists && abs(input.frame.minY - marker.frame.maxY - gap) < 12
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        capture("composer-history-keyboard-dismissed")
    }
    func testProviderRemovalNeedsConfirmationAndCanBeRestored() {
        let app = launch(); openProviders(app)
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
        XCTAssertTrue(app.staticTexts["已停止；已发出的动作可能已执行，请核对设备"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["approveTool"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["查看演示画面，点击计数器一次，再检查结果"].firstMatch.tap()
        XCTAssertFalse(app.buttons["stopRun"].exists)
        XCTAssertFalse(app.buttons["approveTool"].exists)
    }
    func testDiscoverModelsConfigureParameterAndSelectCachedModelInConversation() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-test-model-catalog"]; app.launch()
        openProviders(app); app.staticTexts["Catalog Fixture"].tap()
        XCTAssertTrue(app.buttons["fetchModels"].waitForExistence(timeout: 5)); app.buttons["fetchModels"].tap()
        XCTAssertTrue(app.buttons["chooseDiscoveredModel"].waitForExistence(timeout: 5))
        app.buttons["chooseDiscoveredModel"].tap()
        XCTAssertTrue(app.staticTexts["fixture-vision"].waitForExistence(timeout: 3)); app.staticTexts["fixture-vision"].tap()
        app.swipeUp()
        let parameter = app.textFields["parameter-temperature"]
        XCTAssertTrue(parameter.waitForExistence(timeout: 3)); parameter.tap(); parameter.typeText("0.4")
        capture("model-parameters")
        app.buttons["saveProvider"].tap(); closeProviders(app); app.buttons["newConversation"].tap()
        let picker = app.buttons["conversationModelPicker"]
        app.textViews["messageInput"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("fixture-vision")); picker.tap(); app.buttons["fixture-other"].tap()
        XCTAssertTrue(picker.label.contains("fixture-other"))
        capture("discovered-model-selection")
    }
}
