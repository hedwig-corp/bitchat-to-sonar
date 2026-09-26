import XCTest

/// Headless iOS QA driver (scripts/qa/ios-drive.sh): runs the `;`-separated
/// steps in $QA_STEPS against the installed Sonar app, by bundle id, so a QA
/// pass can drive iOS without the Simulator panel. Screenshots, accessibility
/// trees and steps.log land in $QA_OUT.
///
///   launch (with $QA_NSEC as SONAR_BENCH_NSEC) | activate | wait:<s>
///   tap:<exact label> | tapc:<label substring> | tapid:<accessibility id>
///   tapnth:<exact label>#<n> | tapxy:<x>,<y> (points) | longpress:<substring>
///   longpressxy:<x>,<y> (points)
///   type:<text> | swipeup | swipedown | home
///   expect:<substring>[@secs] | absent:<substring>[@secs] | count:<substring>[=<n>]
///   shot:<name> | tree:<name> | sbtap:<SpringBoard button> | sbshot:<name>
final class QADriver: XCTestCase {
    private var app: XCUIApplication!
    private var out: URL!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "sh.hedwig.sonar")
        let env = ProcessInfo.processInfo.environment
        out = URL(fileURLWithPath: env["QA_OUT"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    // Not `testRun`: that name collides with XCTest's own `testRun` property,
    // and the runner then "passes" without executing a single step.
    func testDrive() throws {
        let env = ProcessInfo.processInfo.environment
        let steps = (env["QA_STEPS"] ?? "").components(separatedBy: ";").filter { !$0.isEmpty }
        if steps.isEmpty {
            XCTFail("QA_STEPS is empty (pass it as TEST_RUNNER_QA_STEPS)")
            return
        }
        var log: [String] = []
        defer {
            try? log.joined(separator: "\n").write(
                to: out.appendingPathComponent("steps.log"), atomically: true, encoding: .utf8)
        }
        for step in steps {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let cmd = parts[0]
            let arg = parts.count > 1 ? parts[1] : ""
            log.append("> \(step)")
            switch cmd {
            case "launch":
                if let nsec = env["QA_NSEC"] { app.launchEnvironment["SONAR_BENCH_NSEC"] = nsec }
                app.launch()
            case "activate":
                app.activate()
            case "wait":
                Thread.sleep(forTimeInterval: Double(arg) ?? 1)
            case "tap":
                try element(label: arg, contains: false).tap()
            case "tapid":
                let el = app.descendants(matching: .any).matching(identifier: arg).firstMatch
                if !el.waitForExistence(timeout: 20) {
                    shot("FAIL-find"); XCTFail("no element with id \(arg)"); return
                }
                el.tap()
            case "tapxy":
                // tapxy:<x>,<y> in points — for controls with no label or id.
                let xy = arg.split(separator: ",").compactMap { Double($0) }
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: xy[0], dy: xy[1])).tap()
            case "longpressxy":
                // longpressxy:<x>,<y> in points — photos and other unlabelled content.
                let xy = arg.split(separator: ",").compactMap { Double($0) }
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: xy[0], dy: xy[1])).press(forDuration: 1.2)
            case "tapnth":
                // tapnth:<exact label>#<n> — n-th (0-based) element with that label.
                let kv = arg.split(separator: "#").map(String.init)
                let el = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@", kv[0])).element(boundBy: Int(kv[1]) ?? 0)
                if !el.waitForExistence(timeout: 20) { shot("FAIL-find"); XCTFail("no \(arg)"); return }
                el.tap()
            case "tapc":
                try element(label: arg, contains: true).tap()
            case "longpress":
                try element(label: arg, contains: true).press(forDuration: 1.2)
            case "expect":
                let (needle, secs) = split(arg)
                let el = find(needle, contains: true)
                if !el.waitForExistence(timeout: secs) {
                    shot("FAIL-expect")
                    log.append("FAIL expect \(needle)")
                    XCTFail("expected \(needle)")
                    return
                }
                log.append("ok expect \(needle) label=\(el.label)")
            case "absent":
                let (needle, secs) = split(arg)
                Thread.sleep(forTimeInterval: secs == 30 ? 0 : secs)
                if find(needle, contains: true).exists {
                    shot("FAIL-absent")
                    log.append("FAIL absent \(needle)")
                    XCTFail("unexpected \(needle)")
                    return
                }
                log.append("ok absent \(needle)")
            case "count":
                // count:<substr>=<n> — number of elements whose label contains substr
                let kv = arg.split(separator: "=").map(String.init)
                let n = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", kv[0])).count
                log.append("count \(kv[0]) = \(n)")
                if kv.count > 1, let want = Int(kv[1]), want != n {
                    shot("FAIL-count")
                    XCTFail("count \(kv[0]) = \(n), want \(want)")
                    return
                }
            case "shot":
                shot(arg)
            case "tree":
                try? app.debugDescription.write(
                    to: out.appendingPathComponent("\(arg).txt"), atomically: true, encoding: .utf8)
            case "type":
                app.typeText(arg)
            case "swipeup":
                app.swipeUp()
            case "swipedown":
                app.swipeDown()
            case "home":
                XCUIDevice.shared.press(.home)
            case "sbtap":
                // System alerts (permission prompts) and banners live in SpringBoard.
                let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                let el = sb.buttons[arg]
                if el.waitForExistence(timeout: 5) { el.tap() } else { log.append("sbtap: no \(arg)") }
            case "sbshot":
                let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                try? sb.debugDescription.write(
                    to: out.appendingPathComponent("\(arg).txt"), atomically: true, encoding: .utf8)
            default:
                XCTFail("unknown step \(step)")
            }
        }
    }

    private func split(_ arg: String) -> (String, TimeInterval) {
        if let at = arg.lastIndex(of: "@"), let secs = Double(arg[arg.index(after: at)...]) {
            return (String(arg[..<at]), secs)
        }
        return (arg, 30)
    }

    private func find(_ label: String, contains: Bool) -> XCUIElement {
        let predicate = contains
            ? NSPredicate(format: "label CONTAINS %@", label)
            : NSPredicate(format: "label == %@", label)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func element(label: String, contains: Bool) throws -> XCUIElement {
        let el = find(label, contains: contains)
        if !el.waitForExistence(timeout: 20) {
            shot("FAIL-find")
            try? app.debugDescription.write(
                to: out.appendingPathComponent("FAIL-find.txt"), atomically: true, encoding: .utf8)
            XCTFail("no element labelled \(label)")
            throw XCTSkip("missing \(label)")
        }
        return el
    }

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: out.appendingPathComponent("\(name).png"))
    }
}
