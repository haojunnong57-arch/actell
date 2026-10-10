import XCTest

@MainActor final class ConversationUITests: XCTestCase {
    private func launch(demo: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-deviceControlRoute", "ncmDeveloper"] + (demo ? ["--ui-test-demo-history"] : [])
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
    func testReasoningHeaderWhitespaceAndArrowCollapseWithOneTap() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-disclosure-scroll"]
        app.launch(); app.staticTexts["新会话"].firstMatch.tap()
        let header = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "思考")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let content = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reasoningContent-")).firstMatch
        for x in [0.5, 0.95, 0.5, 0.95, 0.5, 0.95] {
            // Tap the empty middle and the chevron, rather than only the text.
            header.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
            XCTAssertTrue(content.waitForExistence(timeout: 2))
            header.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
            let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: content)
            XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 2), .completed)
        }
        capture("reasoning-single-tap-collapse")
    }
    func testConversationEntryAndRepeatedActivityLinksScrollToLatest() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-composer-history", "--ui-test-conversation-navigation"]
        app.launch(); app.staticTexts["新会话"].firstMatch.tap()
        let scroll = app.scrollViews["conversationMessages"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let route = try XCTUnwrap(URL(string: try XCTUnwrap(scroll.value as? String)))
        let tail = app.staticTexts["滚动验收最后一条消息"]
        func assertAtBottom() {
            capture("conversation-navigation-position")
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tail.isHittable }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        }
        assertAtBottom()
        for _ in 0..<2 {
            scroll.swipeDown(); scroll.swipeDown()
            XCTAssertFalse(tail.isHittable, "History remains freely scrollable")
            XCUIDevice.shared.system.open(route)
            assertAtBottom()
        }
        scroll.swipeDown(); scroll.swipeDown()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["新会话"].firstMatch.tap()
        assertAtBottom()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.system.open(route)
        assertAtBottom()
        capture("conversation-entry-at-latest")
    }
    func testDeviceControlsAndSettingsDoNotStartAnything() {
        let app = launch()
        XCTAssertFalse(app.buttons["openProviders"].exists)
        XCTAssertFalse(app.buttons["deviceControls"].exists)
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["openProviders"].exists)
        XCTAssertTrue(app.buttons["esp32ControlSettings"].exists)
        let title = app.navigationBars["设置"].staticTexts["设置"]
        XCTAssertLessThan(title.frame.height, 30)
        let titleY = title.frame.minY
        app.swipeUp()
        XCTAssertEqual(title.frame.minY, titleY, accuracy: 1)
        capture("settings-scrolled-fixed-title")
        app.swipeDown()
        XCTAssertEqual(title.frame.minY, titleY, accuracy: 1)
        capture("settings")
        app.buttons["esp32ControlSettings"].tap()
        XCTAssertTrue(app.navigationBars["ESP32 控制"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.navigationBars["ESP32 控制"].staticTexts["ESP32 控制"].frame.height, 30)
        XCTAssertFalse(app.buttons["startScreenCapture"].exists)
        capture("device-panel")
    }
    func testVPNLoopbackModePersistsAndShowsEditableAddresses() {
        let app = launch()
        app.buttons["设置"].tap()
        let mode = app.buttons["deviceControlMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        capture("vpn-parent-settings")
        mode.tap()
        app.buttons["VPN 回环"].tap()
        app.buttons["esp32ControlSettings"].tap()
        XCTAssertTrue(app.navigationBars["VPN 回环控制"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "共用系统配对身份")).firstMatch.exists)
        XCTAssertEqual(app.textFields["vpnLoopbackInterfaceAddress"].value as? String, "10.7.1.1")
        XCTAssertEqual(app.textFields["vpnLoopbackPeerAddress"].value as? String, "10.7.0.1")
        XCTAssertTrue(app.buttons["配对"].exists)
        XCTAssertFalse(app.buttons["获取截图"].exists)
        let saveButton = app.navigationBars.buttons["saveVPNLoopbackConfiguration"]
        XCTAssertFalse(saveButton.exists)
        XCTAssertTrue(app.staticTexts["建立连接阶段需要处于 Wi-Fi 环境"].exists)
        func saveConfiguration() {
            XCTAssertEqual(app.navigationBars.buttons.matching(identifier: "saveVPNLoopbackConfiguration").count, 1)
            saveButton.tap()
            XCTAssertFalse(saveButton.exists)
        }
        capture("local-vpn-setup")
        let interfaceAddress = app.textFields["vpnLoopbackInterfaceAddress"]
        let presets = app.buttons["vpnLoopbackInterfaceAddressPresets"]
        for _ in 0..<3 {
            presets.tap()
            app.buttons["198.18.0.1"].tap()
            XCTAssertEqual(app.navigationBars.buttons.matching(identifier: "saveVPNLoopbackConfiguration").count, 1)
            presets.tap()
            app.buttons["10.7.1.1"].tap()
            XCTAssertFalse(saveButton.exists)
        }
        presets.tap()
        XCTAssertTrue(app.buttons["10.7.1.1"].exists)
        app.buttons["198.18.0.1"].tap()
        XCTAssertEqual(interfaceAddress.value as? String, "198.18.0.1")
        XCTAssertEqual(app.textFields["vpnLoopbackPeerAddress"].value as? String, "10.7.0.1")
        XCTAssertTrue(saveButton.exists)
        XCTAssertEqual(app.navigationBars.buttons.matching(identifier: "saveVPNLoopbackConfiguration").count, 1)
        capture("local-vpn-unsaved-preset")
        saveConfiguration()
        XCTAssertFalse(saveButton.exists)
        capture("local-vpn-preset")
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["设置"].tap()
        app.buttons["esp32ControlSettings"].tap()
        XCTAssertTrue(app.navigationBars["VPN 回环控制"].waitForExistence(timeout: 5))
        XCTAssertEqual(interfaceAddress.value as? String, "198.18.0.1")
        presets.tap()
        app.buttons["vpnLoopbackInterfaceAddressCustom"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        interfaceAddress.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        interfaceAddress.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "198.18.0.1".count) + "10.9.1.1")
        XCTAssertEqual(interfaceAddress.value as? String, "10.9.1.1")
        saveConfiguration()
        app.terminate(); app.launch()
        app.buttons["设置"].tap()
        app.buttons["esp32ControlSettings"].tap()
        XCTAssertTrue(interfaceAddress.waitForExistence(timeout: 5))
        XCTAssertEqual(interfaceAddress.value as? String, "10.9.1.1")
        capture("local-vpn-custom-address")
        presets.tap()
        app.buttons["10.7.1.1"].tap()
        saveConfiguration()
        let peerAddress = app.textFields["vpnLoopbackPeerAddress"]
        let peerPresets = app.buttons["vpnLoopbackPeerAddressPresets"]
        peerPresets.tap()
        XCTAssertTrue(app.buttons["10.7.0.1"].exists)
        XCTAssertFalse(app.buttons["198.18.0.1"].exists)
        capture("local-vpn-peer-options")
        app.buttons["vpnLoopbackPeerAddressCustom"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        peerAddress.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        peerAddress.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "10.7.0.1".count) + "10.9.0.1")
        XCTAssertEqual(peerAddress.value as? String, "10.9.0.1")
        saveConfiguration()
        app.terminate(); app.launch()
        app.buttons["设置"].tap()
        app.buttons["esp32ControlSettings"].tap()
        XCTAssertTrue(peerAddress.waitForExistence(timeout: 5))
        XCTAssertEqual(peerAddress.value as? String, "10.9.0.1")
        peerPresets.tap()
        app.buttons["10.7.0.1"].tap()
        saveConfiguration()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["deviceControlMode"].tap()
        app.buttons["ESP32 NCM"].tap()
        app.buttons["esp32ControlSettings"].tap()
        XCTAssertTrue(app.navigationBars["ESP32 控制"].waitForExistence(timeout: 5))
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
    func testResponsesContextSelectionPersistsAndChatResetsChain() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-test-composer-models"]; app.launch()
        openProviders(app); app.staticTexts["Fixture One"].tap()
        let service = app.buttons["providerProtocol"]
        XCTAssertTrue(service.waitForExistence(timeout: 5)); service.tap()
        XCTAssertTrue(app.buttons["OpenAI-compatible"].exists)
        XCTAssertTrue(app.buttons["OpenRouter"].exists)
        for removed in ["Anthropic", "Gemini", "Ollama"] { XCTAssertFalse(app.buttons[removed].exists) }
        app.buttons["OpenRouter"].tap()
        XCTAssertTrue(service.label.contains("OpenRouter"))
        service.tap(); app.buttons["OpenAI-compatible"].tap()
        let api = app.buttons["providerInferenceAPI"], context = app.buttons["providerContextPolicy"]
        XCTAssertTrue(api.waitForExistence(timeout: 5)); api.tap(); app.buttons["Responses"].tap()
        XCTAssertTrue(context.waitForExistence(timeout: 3)); context.tap()
        app.buttons["服务端响应链 · 保存远端响应"].tap()
        capture("responses-context-setting")
        app.buttons["saveProvider"].tap(); app.staticTexts["Fixture One"].tap()
        XCTAssertTrue(api.label.contains("Responses")); XCTAssertTrue(context.label.contains("服务端响应链"))
        api.tap(); app.buttons["Chat Completions"].tap(); XCTAssertFalse(context.exists)
        app.buttons["saveProvider"].tap(); app.staticTexts["Fixture One"].tap()
        XCTAssertTrue(api.label.contains("Chat Completions")); XCTAssertFalse(context.exists)
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
        // Match the existing composer-model test: complete the focus transition
        // after dismissing an editor keyboard before expecting its action row.
        app.textViews["messageInput"].tap(); app.textViews["messageInput"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("fixture-vision")); picker.tap(); app.buttons["fixture-other"].tap()
        XCTAssertTrue(picker.label.contains("fixture-other"))
        capture("discovered-model-selection")
    }
}
