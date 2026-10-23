import XCTest
import UIKit

/// Shared driver: launches with `-FigCraftDemo -FigCraftDemoAutoCreate`, waits for `demoReady`, records missing
/// elements as notes (a `-notes` text attachment) instead of failing. Only a missing window fails a test.
/// No screenshots anywhere: text attachments only.
@MainActor
class FigCraftUITestCase: XCTestCase {
    var app: XCUIApplication!
    var notes: [String] = []
    var prefix = ""
    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    func launchDemo(dark: Bool, extraArguments: [String] = []) {
        continueAfterFailure = false
        prefix = "\(isPad ? "ipad" : "iphone")-\(dark ? "dark" : "light")"
        notes = []
        XCUIDevice.shared.appearance = dark ? .dark : .light
        app = XCUIApplication()
        app.launchArguments = ["-FigCraftDemo", "-FigCraftDemoAutoCreate", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            + (dark ? ["-AppleInterfaceStyle", "Dark"] : []) + extraArguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "The app did not launch")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60), "The app has no window")
    }

    func waitForDemo() {
        if !element("demoReady").waitForExistence(timeout: 90) { note("demoReady never appeared") }
        pause(1.5)
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func prefixQuery(_ prefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    func canTap(_ e: XCUIElement) -> Bool {
        guard e.exists else { return false }
        let f = e.frame
        let w = app.windows.firstMatch.frame
        guard !f.isEmpty, w.contains(CGPoint(x: f.midX, y: f.midY)) else { return false }
        return e.isHittable
    }

    /// The first element with `identifier` that can be tapped.
    func hit(_ identifier: String) -> XCUIElement? {
        let q = app.descendants(matching: .any).matching(identifier: identifier)
        for e in q.allElementsBoundByIndex where canTap(e) { return e }
        return nil
    }

    func hit(prefix: String) -> XCUIElement? {
        for e in prefixQuery(prefix).allElementsBoundByIndex where canTap(e) { return e }
        return nil
    }

    @discardableResult
    func tap(_ identifier: String, timeout: TimeInterval = 5) -> Bool {
        let e = element(identifier)
        guard e.waitForExistence(timeout: timeout) else { note("\(identifier): not found"); return false }
        guard canTap(e) else { note("\(identifier): exists but not hittable (off screen or covered)"); return false }
        e.tap()
        return true
    }

    /// The full message of an alert on screen, dismissed; nil when none.
    func dismissAlert() -> String? {
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 1) else { return nil }
        let text = ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " | ")
        let button = alert.buttons.firstMatch
        if button.exists { button.tap() }
        return text
    }

    func pause(_ seconds: TimeInterval) {
        let e = expectation(description: "pause")
        e.isInverted = true
        wait(for: [e], timeout: seconds)
    }

    func note(_ text: String) {
        notes.append(text)
        NSLog("FigCraftUITests note: %@", text)
    }

    func attach(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "\(prefix)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func flushNotes(_ name: String = "notes") {
        attach(name, notes.isEmpty ? "no notes" : notes.joined(separator: "\n"))
    }

    /// Drag between two normalised points of an element.
    func drag(_ target: XCUIElement, _ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) {
        let from = target.coordinate(withNormalizedOffset: CGVector(dx: a.0, dy: a.1))
        let to = target.coordinate(withNormalizedOffset: CGVector(dx: b.0, dy: b.1))
        from.press(forDuration: 0.15, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
        pause(0.4)
    }

    var canvas: XCUIElement {
        let c = element("canvas")
        return c.exists ? c : app.windows.firstMatch
    }
}
