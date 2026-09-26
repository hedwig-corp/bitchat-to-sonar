import XCTest

/// Headless share-sheet driver for scripts/qa/ios-share-smoke.sh.
///
/// Runs the `;`-separated steps in $QA_STEPS. A step is `cmd[@app]:arg`; the
/// app is one of `sonar` (default), `host` (the QA share host), `files`,
/// `photos`, `sb` (SpringBoard). `launch@x` / `activate@x` also make `x` the
/// current app for the steps that follow.
///
///   launch[@app]            sonar gets SONAR_BENCH_NSEC=$QA_NSEC
///   activate[@app] | wait:<s> | home
///   waitfg[@app]:<secs>     wait until the app comes forward by itself (the
///                           share hand-off opening Sonar)
///   hostshare:<items.json>  launch the host with those items, open its share sheet
///   files:<name>            Files → On My iPhone → long-press <name> → Share
///   filesselect:<a>|<b>     Files → On My iPhone → Select a, b → Share
///   photos:                 Photos → first photo → Share
///   sheet:<target>          tap <target> ("Sonar") in the open share sheet
///   handoff:<inbox>#<n>     wait for n committed payloads, then open Sonar as
///                           a user would (the extension cannot open it)
///   tap:<label> | tapc:<substring> | tapid:<id> | longpress:<substring>
///   tapif:<label>           tap only if it shows up within 5 s (e.g. tapif@sb:Allow)
///   expect:<substring>[@secs] | absent:<substring>[@secs] | count:<substring>[=n]
///   type:<text> | swipeup | swipedown | shot:<name> | tree:<name>
///
/// Screenshots, accessibility trees and steps.log land in $QA_OUT. Read labels
/// from the trees; never guess coordinates off a PNG.
final class QAShareDriver: XCTestCase {
    private static let bundles = [
        "sonar": "sh.hedwig.sonar",
        "host": "sh.hedwig.qasharehost",
        "files": "com.apple.DocumentsApp",
        "photos": "com.apple.mobileslideshow",
        "sb": "com.apple.springboard",
    ]

    private var apps: [String: XCUIApplication] = [:]
    private var current = "sonar"
    private var out: URL!
    private var log: [String] = []

    override func setUp() {
        continueAfterFailure = false
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
        for step in steps {
            log.append("> \(step)")
            flushLog()
            try run(step, env: env)
        }
        log.append("ALL STEPS OK")
        flushLog()
    }

    /// Written after every step, not in a `defer`: with continueAfterFailure
    /// off, XCTFail unwinds past Swift defers and the log would be lost exactly
    /// when it is needed.
    private func flushLog() {
        try? log.joined(separator: "\n").write(
            to: out.appendingPathComponent("steps.log"), atomically: true, encoding: .utf8)
    }

    // MARK: - Steps

    private func run(_ step: String, env: [String: String]) throws {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let head = parts[0].split(separator: "@", maxSplits: 1).map(String.init)
        let cmd = head[0]
        let appName = head.count > 1 ? head[1] : current
        let arg = parts.count > 1 ? parts[1] : ""
        let app = self.app(appName)

        switch cmd {
        case "launch":
            if appName == "sonar", let nsec = env["QA_NSEC"], !nsec.isEmpty {
                app.launchEnvironment["SONAR_BENCH_NSEC"] = nsec
            }
            app.launch()
            current = appName
        case "activate":
            app.activate()
            current = appName
        case "handoff":
            try handOff(arg)
        case "waitfg":
            // Wait for the app to come forward ON ITS OWN — after a share, the
            // extension opens Sonar. Activating it from here instead raced the
            // extension (still staging inside the host's sheet) and cut the
            // share off.
            let secs = Double(arg) ?? 40
            guard app.wait(for: .runningForeground, timeout: secs) else {
                return try fail("\(appName) never came to the foreground", app)
            }
            current = appName
            log.append("\(appName) in foreground")
        case "wait":
            Thread.sleep(forTimeInterval: Double(arg) ?? 1)
        case "home":
            XCUIDevice.shared.press(.home)
        case "hostshare":
            try hostShare(itemsFile: arg)
        case "files":
            try filesShare(names: [arg])
        case "filesselect":
            try filesShare(names: arg.components(separatedBy: "|"))
        case "photos":
            try photosShare()
        case "sheet":
            try tapShareTarget(arg)
        case "tap":
            try element(in: app, label: arg, contains: false).tap()
        case "tapif":
            // Optional UI (a permission alert that may or may not be up).
            let el = find(in: app, label: arg, contains: false)
            log.append(tapIfPresent(el, timeout: 5) ? "tapped \(arg)" : "tapif: no \(arg)")
        case "tapc":
            try element(in: app, label: arg, contains: true).tap()
        case "tapid":
            let el = app.descendants(matching: .any).matching(identifier: arg).firstMatch
            guard el.waitForExistence(timeout: 20) else { return try fail("no element with id \(arg)", app) }
            el.tap()
        case "longpress":
            try element(in: app, label: arg, contains: true).press(forDuration: 1.2)
        case "expect":
            let (needle, secs) = split(arg)
            let el = find(in: app, label: needle, contains: true)
            guard el.waitForExistence(timeout: secs) else { return try fail("expected \(needle)", app) }
            log.append("ok expect \(needle) label=\(el.label)")
        case "absent":
            let (needle, secs) = split(arg, default: 0)
            Thread.sleep(forTimeInterval: secs)
            if find(in: app, label: needle, contains: true).exists {
                return try fail("unexpected \(needle)", app)
            }
            log.append("ok absent \(needle)")
        case "count":
            let kv = arg.split(separator: "=").map(String.init)
            let n = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", kv[0])).count
            log.append("count \(kv[0]) = \(n)")
            if kv.count > 1, let want = Int(kv[1]), want != n {
                return try fail("count \(kv[0]) = \(n), want \(want)", app)
            }
        case "type":
            app.typeText(arg)
        case "swipeup":
            app.swipeUp()
        case "swipedown":
            app.swipeDown()
        case "shot":
            shot(arg)
        case "tree":
            dumpTree(app, name: arg)
        default:
            XCTFail("unknown step \(step)")
        }
    }

    /// After tapping Sonar in a share sheet: wait until the extension has
    /// committed `n` payloads to the App Group inbox (`<inbox path>#<n>`), then
    /// get Sonar to the front the way a user does. The extension tries to open
    /// `sonar://share`, but `extensionContext.open` is refused for share
    /// extensions — so the realistic next step is the user switching to Sonar.
    /// Activating Sonar BEFORE the payload is committed interrupts the
    /// extension mid-copy, which is why this waits on the inbox, not a timer.
    private func handOff(_ arg: String) throws {
        let parts = arg.split(separator: "#").map(String.init)
        let inbox = URL(fileURLWithPath: parts[0])
        let want = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        let sonar = app("sonar")
        let deadline = Date().addingTimeInterval(60)
        var stagedAt: Date?
        while Date() < deadline {
            if sonar.state == .runningForeground {
                log.append("handoff: the extension opened Sonar")
                current = "sonar"
                return
            }
            if stagedAt == nil, committedPayloads(in: inbox) >= want {
                stagedAt = Date()
                log.append("handoff: \(want) payload(s) committed")
            }
            // Let the extension finish its status + dismissal (2 s) first.
            if let stagedAt, Date().timeIntervalSince(stagedAt) > 3 {
                sonar.activate()
                current = "sonar"
                log.append("handoff: opened Sonar by hand (the extension cannot open it)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        try fail("handoff: no committed payload in \(inbox.path) after 60 s", app(current))
    }

    private func committedPayloads(in inbox: URL) -> Int {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("payload.json").path)
        }.count
    }

    /// Launch the host with the items listed in a JSON file on the Mac and
    /// open its share sheet.
    private func hostShare(itemsFile: String) throws {
        let host = app("host")
        let items = try String(contentsOfFile: itemsFile, encoding: .utf8)
        host.launchEnvironment["QA_SHARE_ITEMS"] = items
        host.launch()
        current = "host"
        let status = host.staticTexts["qa-share-status"]
        guard status.waitForExistence(timeout: 20) else { return try fail("host did not start", host) }
        let ready = NSPredicate(format: "label BEGINSWITH 'ready'")
        let waited = XCTWaiter.wait(
            for: [expectation(for: ready, evaluatedWith: status)], timeout: 20)
        guard waited == .completed else { return try fail("host not ready: \(status.label)", host) }
        log.append("host \(status.label)")
        host.buttons["qa-share-button"].tap()
    }

    /// Files → Browse → On My iPhone, then share the named item(s).
    private func filesShare(names: [String]) throws {
        let files = app("files")
        files.launch()
        current = "files"
        try openOnMyIPhone(files)
        if names.count == 1 {
            try fileCell(files, names[0]).press(forDuration: 1.2)
            try element(in: files, label: "Share", contains: false).tap()
            return
        }
        // Multi-select: the "More" (…) menu offers Select on recent iOS; the
        // Select button sits in the navigation bar on older ones.
        if !tapIfPresent(files.buttons["Select"], timeout: 3) {
            try element(in: files, label: "More", contains: false).tap()
            try element(in: files, label: "Select", contains: false).tap()
        }
        for name in names {
            try fileCell(files, name).tap()
        }
        try element(in: files, label: "Share", contains: false).tap()
    }

    /// Files hides extensions in labels ("report"); its cells are identified
    /// as "report, csv" (a folder: "Folder QA, Folder").
    private func fileCell(_ files: XCUIApplication, _ name: String) throws -> XCUIElement {
        let ns = name as NSString
        let key = ns.pathExtension.isEmpty ? name : "\(ns.deletingPathExtension), \(ns.pathExtension)"
        let cell = files.cells.matching(
            NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", key, key + ",")
        ).firstMatch
        guard cell.waitForExistence(timeout: 20) else {
            try fail("no Files item \(name)", files)
            return cell
        }
        return cell
    }

    private func openOnMyIPhone(_ files: XCUIApplication) throws {
        // Browse is a tab on iPhone; tapping it again pops to its root. The
        // back button of a pushed folder is ALSO labelled "Browse", so take
        // the tab bar's button, not the first match.
        let browse = files.tabBars.buttons["Browse"]
        if browse.waitForExistence(timeout: 10) {
            browse.tap()
            if browse.isHittable { browse.tap() }
        }
        let local = find(in: files, label: "On My iPhone", contains: false)
        guard local.waitForExistence(timeout: 10) else {
            return try fail("no On My iPhone location", files)
        }
        local.tap()
    }

    /// Photos → the newest photo (the one the script just added) → Share.
    private func photosShare() throws {
        let photos = app("photos")
        photos.launch()
        current = "photos"
        // First launch shows a "What's New" sheet.
        _ = tapIfPresent(photos.buttons["Continue"], timeout: 4)
        let grid = photos.images.matching(identifier: "PXGGridLayout-Info")
        guard grid.firstMatch.waitForExistence(timeout: 15) else { return try fail("no photo", photos) }
        grid.element(boundBy: grid.count - 1).tap()
        try element(in: photos, label: "Share", contains: false).tap()
    }

    /// Tap a share-sheet target. Waits for it to become hittable (the sheet
    /// animates in), then scrolls only the row that holds it, then falls back
    /// to the row's "More" list.
    private func tapShareTarget(_ name: String) throws {
        let app = self.app(current)
        let named = NSPredicate(format: "label == %@", name)
        // Cells in the app row; a button on some layouts. Resolved lazily —
        // choosing the query before the sheet exists picked one that never
        // matched.
        let target = app.descendants(matching: .any).matching(named)
            .matching(NSPredicate(format: "elementType == %d OR elementType == %d",
                                  XCUIElement.ElementType.cell.rawValue,
                                  XCUIElement.ElementType.button.rawValue)).firstMatch
        if target.waitForExistence(timeout: 20) {
            let deadline = Date().addingTimeInterval(6)
            while !target.isHittable, Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
            if !target.isHittable {
                let row = app.collectionViews.containing(named).firstMatch
                for _ in 0..<4 where !target.isHittable && row.exists { row.swipeLeft() }
            }
            if target.isHittable {
                target.tap()
                log.append("sheet: tapped \(name)")
                return
            }
        }
        // "More" at the end of the app row lists every share target.
        let more = app.cells.matching(NSPredicate(format: "label == 'More'")).firstMatch
        if more.exists, more.isHittable {
            more.tap()
            let listed = app.descendants(matching: .any).matching(named).firstMatch
            if listed.waitForExistence(timeout: 10), listed.isHittable {
                listed.tap()
                log.append("sheet: tapped \(name) from More")
                return
            }
        }
        try fail("share target \(name) not found", app)
    }

    // MARK: - Helpers

    private func app(_ name: String) -> XCUIApplication {
        if let existing = apps[name] { return existing }
        let bundle = Self.bundles[name] ?? name
        let created = XCUIApplication(bundleIdentifier: bundle)
        apps[name] = created
        return created
    }

    private func tapIfPresent(_ el: XCUIElement, timeout: TimeInterval) -> Bool {
        guard el.waitForExistence(timeout: timeout), el.isHittable else { return false }
        el.tap()
        return true
    }

    private func split(_ arg: String, default fallback: TimeInterval = 30) -> (String, TimeInterval) {
        if let at = arg.lastIndex(of: "@"), let secs = Double(arg[arg.index(after: at)...]) {
            return (String(arg[..<at]), secs)
        }
        return (arg, fallback)
    }

    private func find(in app: XCUIApplication, label: String, contains: Bool) -> XCUIElement {
        let predicate = contains
            ? NSPredicate(format: "label CONTAINS[c] %@", label)
            : NSPredicate(format: "label == %@", label)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func element(in app: XCUIApplication, label: String, contains: Bool) throws -> XCUIElement {
        let el = find(in: app, label: label, contains: contains)
        guard el.waitForExistence(timeout: 20) else {
            try fail("no element labelled \(label)", app)
            return el
        }
        return el
    }

    private func fail(_ message: String, _ app: XCUIApplication) throws {
        log.append("FAIL \(message)")
        flushLog()
        shot("FAIL")
        dumpTree(app, name: "FAIL")
        XCTFail(message)
        throw XCTSkip(message)
    }

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: out.appendingPathComponent("\(name).png"))
    }

    private func dumpTree(_ app: XCUIApplication, name: String) {
        try? app.debugDescription.write(
            to: out.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }
}
