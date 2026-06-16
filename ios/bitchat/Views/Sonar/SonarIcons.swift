//
// SonarIcons.swift
// bitchat
//
// Faithful port of design/handoff/project/sonar/icons.jsx: the minimal
// SF-style line glyph set (24×24, stroke currentColor, round caps/joins).
// SVG path data is transcribed verbatim and rendered through a small
// path-data parser, so the glyphs match the prototype exactly.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

// MARK: - Icon definitions (icons.jsx, verbatim path data)

enum SNIconName: String {
    case back, chevron, lock, plus, send, search, pin, people, mesh, globe
    case check, shield, shieldCheck, x, smile, navArrow, dice, slash, rings
    case pencil, key, inbox, arrowOut, faceid, drive, data, list, moon, bell
    case trash, info, compose, coin, bolt, mic
    // Calls (call.jsx): phone/videocam start a call; the in-call controls.
    case phone, videocam, phoneDown, micOff, videoOff, speaker, cameraFlip
    // Key sharing (settings.jsx KeyShareCard): copy key / share key.
    case copy, share
    // Private-key export / import (settings.jsx ExportKeySheet, onboarding restore).
    case eye, eyeOff, importKey
}

private enum SNIconElement {
    case path(String)            // stroked path
    case circle(Double, Double, Double, filled: Bool) // cx, cy, r
    case rect(Double, Double, Double, Double, Double) // x, y, w, h, rx (stroked)
}

private let snIconTable: [SNIconName: [SNIconElement]] = [
    .back: [.path("M14.5 4.5 7 12l7.5 7.5")],
    .chevron: [.path("M9.5 5l7 7-7 7")],
    .lock: [.rect(5.5, 10.5, 13, 9.5, 2.6), .path("M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5")],
    .plus: [.path("M12 5.5v13M5.5 12h13")],
    .send: [.path("M12 18.5v-13M6.5 11 12 5.5 17.5 11")],
    .search: [.circle(11, 11, 5.6, filled: false), .path("M15.4 15.4 20 20")],
    .pin: [
        .path("M12 20.8s-6.3-5.3-6.3-10.2a6.3 6.3 0 0 1 12.6 0c0 4.9-6.3 10.2-6.3 10.2z"),
        .circle(12, 10.4, 2.2, filled: false),
    ],
    .people: [
        .circle(9, 8.4, 3.1, filled: false),
        .path("M3.6 19.4c.6-3.3 2.8-5 5.4-5s4.8 1.7 5.4 5"),
        .circle(16.8, 9.4, 2.5, filled: false),
        .path("M16.6 14.5c2.1.4 3.5 2 3.9 4.7"),
    ],
    .mesh: [
        .circle(12, 12, 1.7, filled: true),
        .path("M8.7 8.7a4.7 4.7 0 0 0 0 6.6M15.3 8.7a4.7 4.7 0 0 1 0 6.6M6.2 6.2a8.2 8.2 0 0 0 0 11.6M17.8 6.2a8.2 8.2 0 0 1 0 11.6"),
    ],
    .globe: [
        .circle(12, 12, 8.2, filled: false),
        .path("M3.8 12h16.4M12 3.8c-2.7 2.5-4.1 5.2-4.1 8.2s1.4 5.7 4.1 8.2c2.7-2.5 4.1-5.2 4.1-8.2S14.7 6.3 12 3.8z"),
    ],
    .check: [.path("M5 12.8l4.3 4.3L19 7.4")],
    .shield: [.path("M12 3.4l7 2.7v5.2c0 4.4-2.9 7.4-7 9-4.1-1.6-7-4.6-7-9V6.1z")],
    .shieldCheck: [
        .path("M12 3.4l7 2.7v5.2c0 4.4-2.9 7.4-7 9-4.1-1.6-7-4.6-7-9V6.1z"),
        .path("M8.8 12.1l2.3 2.3 4.3-4.6"),
    ],
    .x: [.path("M6.5 6.5l11 11M17.5 6.5l-11 11")],
    .smile: [
        .circle(12, 12, 8.2, filled: false),
        .circle(9.1, 10.2, 1.1, filled: true),
        .circle(14.9, 10.2, 1.1, filled: true),
        .path("M8.7 14.2a4.5 4.5 0 0 0 6.6 0"),
    ],
    .navArrow: [.path("M20.4 3.6 3.8 10.2l6.6 3.4 3.4 6.6z")],
    .dice: [
        .rect(4.2, 4.2, 15.6, 15.6, 4),
        .circle(8.8, 8.8, 1.2, filled: true),
        .circle(15.2, 8.8, 1.2, filled: true),
        .circle(12, 12, 1.2, filled: true),
        .circle(8.8, 15.2, 1.2, filled: true),
        .circle(15.2, 15.2, 1.2, filled: true),
    ],
    .slash: [.path("M14.5 4.5l-5 15")],
    .rings: [
        .circle(12, 12, 2, filled: true),
        .circle(12, 12, 5.8, filled: false),
        .circle(12, 12, 9.4, filled: false),
    ],
    .pencil: [.path("M16.8 4.6l2.6 2.6L8.6 18l-3.4.8.8-3.4z")],
    .key: [.circle(8.5, 12, 3.4, filled: false), .path("M11.9 12h8M17 12v2.8M19.9 12v2")],
    .inbox: [.rect(4.5, 5.5, 15, 14, 3), .path("M4.5 13.5h4l1.5 2.5h4l1.5-2.5h4")],
    .arrowOut: [.path("M8 16L16.5 7.5M9.5 7h7v7")],
    .faceid: [
        .path("M4.5 8V6.5a2 2 0 0 1 2-2H8M16 4.5h1.5a2 2 0 0 1 2 2V8M19.5 16v1.5a2 2 0 0 1-2 2H16M8 19.5H6.5a2 2 0 0 1-2-2V16"),
        .circle(9.2, 10.4, 0.9, filled: true),
        .circle(14.8, 10.4, 0.9, filled: true),
        .path("M9.6 14.4a3.4 3.4 0 0 0 4.8 0"),
    ],
    .drive: [
        .rect(4.5, 7.5, 15, 9.5, 2.5),
        .circle(8, 14, 0.9, filled: true),
        .path("M4.5 11.5h15"),
    ],
    .data: [.path("M8 18.5V8.8M8 8.8 5.2 11.6M8 8.8l2.8 2.8M16 5.5v9.7M16 15.2l2.8-2.8M16 15.2l-2.8-2.8")],
    .list: [
        .path("M9 6.5h11M9 12h11M9 17.5h11"),
        .circle(4.6, 6.5, 1.2, filled: true),
        .circle(4.6, 12, 1.2, filled: true),
        .circle(4.6, 17.5, 1.2, filled: true),
    ],
    .moon: [.path("M19 13.8A7.6 7.6 0 1 1 10.2 5 6.1 6.1 0 0 0 19 13.8z")],
    .bell: [
        .path("M12 4a5.5 5.5 0 0 1 5.5 5.5c0 3 .8 4.6 1.7 5.7H4.8c.9-1.1 1.7-2.7 1.7-5.7A5.5 5.5 0 0 1 12 4z"),
        .path("M10 18.8a2.1 2.1 0 0 0 4 0"),
    ],
    .trash: [
        .path("M5 7h14M10 7V5.6A1.6 1.6 0 0 1 11.6 4h.8A1.6 1.6 0 0 1 14 5.6V7"),
        .path("M7 7l.8 12a1.8 1.8 0 0 0 1.8 1.7h4.8a1.8 1.8 0 0 0 1.8-1.7L17 7"),
    ],
    // design icons.jsx `mic`: a rounded mic body + the stand/arc.
    .mic: [
        .rect(9.2, 3.4, 5.6, 11, 2.8),
        .path("M5.8 11.5a6.2 6.2 0 0 0 12.4 0M12 17.7V20.4M9 20.6h6"),
    ],
    .info: [
        .circle(12, 12, 8.2, filled: false),
        .path("M12 11.2v5"),
        .circle(12, 8, 1.1, filled: true),
    ],
    .compose: [
        .path("M12 5.2H7.2A2.4 2.4 0 0 0 4.8 7.6v9a2.4 2.4 0 0 0 2.4 2.4h9a2.4 2.4 0 0 0 2.4-2.4V12"),
        .path("M17.7 4.5l1.8 1.8-6.6 6.6-2.5.7.7-2.5z"),
    ],
    .coin: [
        .circle(12, 12, 8.4, filled: false),
        .path("M9.9 8.2h3a1.9 1.9 0 0 1 0 3.8h-3zM9.9 12h3.5a1.9 1.9 0 0 1 0 3.8H9.9zM9.9 8.2V16M11.4 6.6v1.6M11.4 16v1.6"),
    ],
    .bolt: [.path("M13 3 6 13.5h4.5L11 21l7-10.5h-4.5z")],
    .phone: [.path("M6.5 4.5c-1 0-2 .9-2 2 0 7 6 13 13 13 1.1 0 2-1 2-2v-2.6c0-.5-.4-.9-.9-1l-3-.6c-.4-.1-.9.1-1.1.5l-1 1.6a11 11 0 0 1-5-5l1.6-1c.4-.2.6-.7.5-1.1l-.6-3c-.1-.5-.5-.9-1-.9z")],
    .videocam: [
        .rect(3.5, 7, 12, 10, 2.5),
        .path("M15.5 11l5-2.6v7.2l-5-2.6z"),
    ],
    .phoneDown: [.path("M3.5 13.5c4.7-4 12.3-4 17 0l-2.2 2.6c-.4.5-1.1.5-1.6.2l-1.9-1.2a1.1 1.1 0 0 1-.5-1.2l.3-1.4a11 11 0 0 0-5.7 0l.3 1.4c.1.5-.1 1-.5 1.2l-1.9 1.2c-.5.3-1.2.3-1.6-.2z")],
    .micOff: [
        .path("M9.2 5.4a2.8 2.8 0 0 1 5.6.8v4M14.8 12.8a2.8 2.8 0 0 1-5.6-1.2V9.2M5.8 11.5a6.2 6.2 0 0 0 9.5 5.3M18.2 11.5a6.2 6.2 0 0 1-.4 2.2M12 17.7V20.4M9 20.6h6"),
        .path("M4.5 4.5l15 15"),
    ],
    .videoOff: [
        .path("M3.5 7h9a2.5 2.5 0 0 1 2.5 2.5v.5l5-2.6v7.2l-5-2.6"),
        .path("M4.5 4.5l15 15"),
    ],
    .speaker: [
        .path("M5 9.5v5h3l4 3.5v-12L8 9.5z"),
        .path("M15.5 9a4 4 0 0 1 0 6M17.8 6.8a7 7 0 0 1 0 10.4"),
    ],
    .cameraFlip: [
        .rect(3.5, 6.5, 17, 13, 3),
        .path("M8.5 13a3.5 3.5 0 0 1 6-2.4M15.5 13a3.5 3.5 0 0 1-6 2.4"),
        .path("M14.2 8.2 14.6 10.4 12.4 10.2M9.8 17.8 9.4 15.6 11.6 15.8"),
        .path("M8 6.5l1-2h6l1 2"),
    ],
    .copy: [
        .rect(8.5, 8.5, 11, 11, 2.6),
        .path("M15.5 8.5V6a2 2 0 0 0-2-2h-7a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h2.5"),
    ],
    .share: [
        .circle(6.5, 12, 2.4, filled: false),
        .circle(17, 6, 2.4, filled: false),
        .circle(17, 18, 2.4, filled: false),
        .path("M8.6 10.9 14.9 7.1M8.6 13.1l6.3 3.8"),
    ],
    .eye: [
        .path("M2.5 12s3.5-6.5 9.5-6.5S21.5 12 21.5 12s-3.5 6.5-9.5 6.5S2.5 12 2.5 12z"),
        .circle(12, 12, 2.8, filled: false),
    ],
    .eyeOff: [
        .path("M4.5 5 19.5 19"),
        .path("M9.5 5.7A9 9 0 0 1 12 5.5c6 0 9.5 6.5 9.5 6.5a16 16 0 0 1-2.9 3.6M6.4 7.6A16 16 0 0 0 2.5 12s3.5 6.5 9.5 6.5a8.8 8.8 0 0 0 3.1-.55"),
        .path("M9.8 10.2a2.8 2.8 0 0 0 3.9 4"),
    ],
    .importKey: [
        .circle(8, 12, 3.2, filled: false),
        .path("M11.2 12h9M16.5 12v3M20.2 12v2.4"),
        .path("M14 5.5 11 8.5M14 5.5l-3-3M11 8.5l-2.4-2.4"),
    ],
]

// MARK: - SVG path-data parser (M/L/H/V/C/S/A/Z + lowercase)

private struct SNPathParser {
    private let scalars: [Character]
    private var i = 0
    private var path = Path()
    private var current = CGPoint.zero
    private var subpathStart = CGPoint.zero
    private var lastCubicControl: CGPoint?

    init(_ d: String) {
        scalars = Array(d)
    }

    static func parse(_ d: String) -> Path {
        var p = SNPathParser(d)
        p.run()
        return p.path
    }

    private mutating func skipSeparators() {
        while i < scalars.count, scalars[i] == " " || scalars[i] == "," || scalars[i] == "\n" {
            i += 1
        }
    }

    private mutating func peekIsNumber() -> Bool {
        skipSeparators()
        guard i < scalars.count else { return false }
        let c = scalars[i]
        return c.isNumber || c == "-" || c == "+" || c == "."
    }

    private mutating func number() -> Double {
        skipSeparators()
        var s = ""
        var seenDot = false
        if i < scalars.count, scalars[i] == "-" || scalars[i] == "+" {
            s.append(scalars[i]); i += 1
        }
        while i < scalars.count {
            let c = scalars[i]
            if c.isNumber {
                s.append(c); i += 1
            } else if c == ".", !seenDot {
                seenDot = true
                s.append(c); i += 1
            } else {
                break
            }
        }
        return Double(s) ?? 0
    }

    private mutating func point(relative: Bool) -> CGPoint {
        let x = number()
        let y = number()
        return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
    }

    private mutating func run() {
        var cmd: Character = " "
        while true {
            skipSeparators()
            guard i < scalars.count else { break }
            let c = scalars[i]
            if c.isLetter {
                cmd = c
                i += 1
            } else {
                // implicit repeat; M/m repeats as L/l
                if cmd == "M" { cmd = "L" }
                if cmd == "m" { cmd = "l" }
            }
            execute(cmd)
        }
    }

    private mutating func execute(_ cmd: Character) {
        let rel = cmd.isLowercase
        switch Character(cmd.lowercased()) {
        case "m":
            let p = point(relative: rel)
            path.move(to: p)
            current = p
            subpathStart = p
            lastCubicControl = nil
        case "l":
            let p = point(relative: rel)
            path.addLine(to: p)
            current = p
            lastCubicControl = nil
        case "h":
            let x = number()
            let p = CGPoint(x: rel ? current.x + x : x, y: current.y)
            path.addLine(to: p)
            current = p
            lastCubicControl = nil
        case "v":
            let y = number()
            let p = CGPoint(x: current.x, y: rel ? current.y + y : y)
            path.addLine(to: p)
            current = p
            lastCubicControl = nil
        case "c":
            let c1 = point(relative: rel)
            let c2 = point(relative: rel)
            let p = point(relative: rel)
            path.addCurve(to: p, control1: c1, control2: c2)
            current = p
            lastCubicControl = c2
        case "s":
            let c1: CGPoint
            if let last = lastCubicControl {
                c1 = CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
            } else {
                c1 = current
            }
            let c2 = point(relative: rel)
            let p = point(relative: rel)
            path.addCurve(to: p, control1: c1, control2: c2)
            current = p
            lastCubicControl = c2
        case "a":
            let rx = number()
            let ry = number()
            let rotation = number()
            let largeArc = number() != 0
            let sweep = number() != 0
            let p = point(relative: rel)
            addArc(to: p, rx: rx, ry: ry, rotationDeg: rotation, largeArc: largeArc, sweep: sweep)
            current = p
            lastCubicControl = nil
        case "z":
            path.closeSubpath()
            current = subpathStart
            lastCubicControl = nil
        default:
            // Unknown command: bail to avoid an infinite loop.
            i = scalars.count
        }
    }

    /// Elliptical arc (endpoint parameterization) approximated with cubics.
    private mutating func addArc(to end: CGPoint, rx rxIn: Double, ry ryIn: Double, rotationDeg: Double, largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if rx == 0 || ry == 0 || (end.x == current.x && end.y == current.y) {
            path.addLine(to: end)
            return
        }
        let phi = rotationDeg * .pi / 180
        let dx2 = (current.x - end.x) / 2
        let dy2 = (current.y - end.y) / 2
        let x1p = cos(phi) * dx2 + sin(phi) * dy2
        let y1p = -sin(phi) * dx2 + cos(phi) * dy2
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cos(phi) * cxp - sin(phi) * cyp + (current.x + end.x) / 2
        let cy = sin(phi) * cxp + cos(phi) * cyp + (current.y + end.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            guard len > 0 else { return 0 }
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let segDelta = delta / Double(segments)
        let t = 4.0 / 3.0 * tan(segDelta / 4)

        func pointAt(_ a: Double) -> CGPoint {
            CGPoint(
                x: cx + rx * cos(a) * cos(phi) - ry * sin(a) * sin(phi),
                y: cy + rx * cos(a) * sin(phi) + ry * sin(a) * cos(phi)
            )
        }
        func derivativeAt(_ a: Double) -> CGPoint {
            CGPoint(
                x: -rx * sin(a) * cos(phi) - ry * cos(a) * sin(phi),
                y: -rx * sin(a) * sin(phi) + ry * cos(a) * cos(phi)
            )
        }

        var th = theta1
        for _ in 0..<segments {
            let th2 = th + segDelta
            let p1 = pointAt(th)
            let p2 = pointAt(th2)
            let d1 = derivativeAt(th)
            let d2 = derivativeAt(th2)
            let c1 = CGPoint(x: p1.x + t * d1.x, y: p1.y + t * d1.y)
            let c2 = CGPoint(x: p2.x - t * d2.x, y: p2.y - t * d2.y)
            path.addCurve(to: p2, control1: c1, control2: c2)
            th = th2
        }
    }
}

// MARK: - Path cache

private enum SNIconCache {
    struct Rendered {
        let stroked: Path
        let filled: Path
    }

    private static var cache: [SNIconName: Rendered] = [:]
    private static let lock = NSLock()

    static func paths(for name: SNIconName) -> Rendered {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        var stroked = Path()
        var filled = Path()
        for element in snIconTable[name] ?? [] {
            switch element {
            case .path(let d):
                stroked.addPath(SNPathParser.parse(d))
            case .circle(let cx, let cy, let r, let isFilled):
                let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                if isFilled {
                    filled.addEllipse(in: rect)
                } else {
                    stroked.addEllipse(in: rect)
                }
            case .rect(let x, let y, let w, let h, let rx):
                stroked.addRoundedRect(
                    in: CGRect(x: x, y: y, width: w, height: h),
                    cornerSize: CGSize(width: rx, height: rx)
                )
            }
        }
        let rendered = Rendered(stroked: stroked, filled: filled)
        cache[name] = rendered
        return rendered
    }
}

// MARK: - Icon view (BCIcon equivalent)

struct SNIcon: View {
    let name: SNIconName
    var size: CGFloat = 20
    var weight: CGFloat = 1.8

    var body: some View {
        let rendered = SNIconCache.paths(for: name)
        let scale = CGAffineTransform(scaleX: size / 24, y: size / 24)
        ZStack {
            rendered.stroked
                .applying(scale)
                .stroke(style: StrokeStyle(lineWidth: weight * size / 24, lineCap: .round, lineJoin: .round))
            rendered.filled
                .applying(scale)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
