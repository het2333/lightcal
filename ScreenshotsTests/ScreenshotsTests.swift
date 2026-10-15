import XCTest

final class ScreenshotsTests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func launchHome() {
        app.terminate()
        app.launchArguments = ["-APIBaseURLOverride", "http://127.0.0.1:18018/v6", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["首页"].waitForExistence(timeout: 60))
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "819")).firstMatch.waitForExistence(timeout: 30)
        Thread.sleep(forTimeInterval: 2)
    }

    func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func open(_ button: XCUIElement) {
        for _ in 0..<6 {
            if button.exists && button.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(button.exists, app.debugDescription)
        button.tap()
    }

    func testCurrentScreenshots() {
        launchHome()
        capture("home")
        open(app.buttons["打开记录总览"])
        capture("meals")
        launchHome()
        open(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "补水节奏")).firstMatch)
        capture("hydration")
        launchHome()
        open(app.buttons["打开进食窗口"])
        capture("fasting")
    }
}
