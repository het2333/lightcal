import XCTest

final class OfflineUITests: XCTestCase {
    func testHomeAndQwenSettingsWithoutBackend() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["首页"].waitForExistence(timeout: 30))
        capture(app, "offline-home")
        app.buttons["千问"].tap()
        let settings = app.buttons["coach.qwenSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let key = app.secureTextFields["qwen.apiKey"]
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        let save = app.buttons["qwen.save"]
        XCTAssertFalse(save.isEnabled)
        capture(app, "qwen-settings")
        key.tap()
        key.typeText("test-key-never-sent")
        XCTAssertFalse(save.isEnabled, "No API call is allowed until the user grants consent")
        app.buttons["完成"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        capture(app, "qwen-chat")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
