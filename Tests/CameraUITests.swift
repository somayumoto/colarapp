import XCTest

/// Runs against Simulator's color chart, so no physical camera is required.
@MainActor
final class CameraUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.somayumoto.IroIroKae")
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["captureSettings"].waitForExistence(timeout: 15))
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testModesAndStrengthPersistAcrossLaunch() {
        select("colorModePicker", option: "赤の強さを青に")
        app.sliders["intensitySlider"].adjust(toNormalizedSliderPosition: 1)
        let descriptions = [
            ("赤の強さを青に", "R成分を青の濃淡で表示します。白や黄色も青くなります。"),
            ("赤と青を交換", "RとBを入れ替えます。白と灰色は保たれます。"),
            ("赤い部分を強調", "無彩色の映像で、赤が優勢な部分を青く強調します。"),
            ("変換なし", "上下とも元の映像を表示します。")
        ]
        for (title, description) in descriptions {
            select("colorModePicker", option: title)
            XCTAssertTrue(app.staticTexts[description].waitForExistence(timeout: 3))
            XCTAssertEqual(app.sliders["intensitySlider"].isEnabled, title != "変換なし")
            screenshot(title)
        }

        select("colorModePicker", option: "赤と青を交換")
        let slider = app.sliders["intensitySlider"]
        slider.adjust(toNormalizedSliderPosition: 0.35)
        let savedStrength = slider.value as? String
        XCTAssertNotNil(savedStrength)
        XCTAssertNotEqual(savedStrength, "100パーセント")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[descriptions[1].1].waitForExistence(timeout: 10))
        XCTAssertEqual(app.sliders["intensitySlider"].value as? String, savedStrength)
        XCTAssertFalse(app.staticTexts["映像を表示できません"].exists)
    }

    func testCaptureSettingsAreSelectableAndPersist() {
        app.buttons["captureSettings"].tap()
        XCTAssertTrue(app.buttons["settingsDone"].waitForExistence(timeout: 3))
        for resolution in ["480p", "720p", "1080p", "4K"] {
            select("resolutionPicker", option: resolution)
            expectSelection("resolutionPicker", contains: resolution)
        }
        select("frameRatePicker", option: "60 fps")
        expectSelection("frameRatePicker", contains: "60 fps")
        select("frameRatePicker", option: "30 fps")
        expectSelection("frameRatePicker", contains: "30 fps")
        select("frameRatePicker", option: "60 fps")
        expectSelection("frameRatePicker", contains: "60 fps")

        let fit = app.switches["showEntireFrameToggle"]
        let wasFit = fit.value as? String == "1"
        setFit(!wasFit)
        screenshot("撮影設定-4K-60fps")
        app.buttons["settingsDone"].tap()

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["captureSettings"].waitForExistence(timeout: 10))
        app.buttons["captureSettings"].tap()
        expectSelection("resolutionPicker", contains: "4K")
        expectSelection("frameRatePicker", contains: "60 fps")
        XCTAssertEqual(app.switches["showEntireFrameToggle"].value as? String, wasFit ? "0" : "1")

        // Leave the test installation at the documented power-saving defaults.
        select("resolutionPicker", option: "720p")
        select("frameRatePicker", option: "30 fps")
        setFit(false)
        app.buttons["settingsDone"].tap()
    }

    func testUnavailableCameraCanReturnToDemo() {
        app.buttons["sourceToggle"].tap()
        let unavailable = app.staticTexts["カメラを利用できません"]
        let permission = app.staticTexts["カメラの使用を許可してください"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let condition = NSPredicate { _, _ in
            unavailable.exists || permission.exists || springboard.alerts.firstMatch.exists
        }
        expectation(for: condition, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        if springboard.alerts.firstMatch.exists {
            let alert = springboard.alerts.firstMatch
            let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "許可", "OK"])).firstMatch
            if allow.exists { allow.tap() } else { alert.buttons.firstMatch.tap() }
        }
        // A simulator has no rear camera. The recovery button must remain accessible.
        if unavailable.waitForExistence(timeout: 5) {
            XCTAssertTrue(app.buttons["色見本を表示"].exists)
            app.buttons["色見本を表示"].tap()
        } else {
            XCTAssertTrue(permission.exists)
            XCTAssertTrue(app.buttons["設定を開く"].exists)
            app.buttons["sourceToggle"].tap()
        }
        XCTAssertTrue(app.staticTexts["色見本でプレビュー中"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["映像を表示できません"].exists)
    }

    func testLandscapePreviewAndSettings() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let landscape = NSPredicate { _, _ in self.app.frame.width > self.app.frame.height }
        expectation(for: landscape, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        let picker = app.buttons["colorModePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.isHittable)
        XCTAssertTrue(app.sliders["intensitySlider"].isHittable)
        XCTAssertTrue(app.buttons["captureSettings"].isHittable)
        XCTAssertFalse(app.staticTexts["映像を表示できません"].exists)
        print("IROIRO_LANDSCAPE_READY")
        screenshot("横向きプレビュー")
        XCTAssertTrue(app.frame.contains(picker.frame))
        XCTAssertTrue(app.frame.contains(app.sliders["intensitySlider"].frame))
        XCTAssertTrue(app.frame.contains(app.buttons["captureSettings"].frame))
        app.buttons["captureSettings"].tap()
        XCTAssertTrue(app.buttons["settingsDone"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["resolutionPicker"].firstMatch.isHittable)
        screenshot("横向き撮影設定")
        app.buttons["settingsDone"].tap()
    }

    private func select(_ identifier: String, option: String) {
        let picker = app.buttons[identifier]
        XCTAssertTrue(picker.waitForExistence(timeout: 3), identifier)
        picker.tap()
        let choices = app.buttons.matching(NSPredicate(format: "label == %@", option))
        // A native menu can still be finishing its dismissal when its row reappears.
        // Retry the row tap only if no choice opened and the row is still hittable.
        if !choices.firstMatch.waitForExistence(timeout: 3), picker.isHittable {
            picker.tap()
        }
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 3), "\(identifier): \(option)\n\(app.debugDescription)")
        choices.element(boundBy: choices.count - 1).tap()
    }

    private func expectSelection(_ identifier: String, contains value: String) {
        let picker = app.descendants(matching: .any)[identifier].firstMatch
        let selected = NSPredicate { _, _ in
            picker.label.contains(value) || (picker.value as? String)?.contains(value) == true
        }
        expectation(for: selected, evaluatedWith: picker)
        waitForExpectations(timeout: 3)
    }

    private func setFit(_ enabled: Bool) {
        let row = app.switches["showEntireFrameToggle"]
        let value = enabled ? "1" : "0"
        if row.value as? String != value {
            // SwiftUI exposes a switch row and its actual UISwitch separately.
            // Tap the thumb rather than the broad row accessibility frame.
            let thumb = row.switches.firstMatch
            if thumb.exists { thumb.tap() } else {
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
        }
        let updated = NSPredicate { _, _ in row.value as? String == value }
        expectation(for: updated, evaluatedWith: row)
        waitForExpectations(timeout: 3)
    }

    private func screenshot(_ name: String) {
        // Full-screen captures avoid XCUIApplication's incorrect crop after rotation.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
