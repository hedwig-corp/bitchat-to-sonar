package chat.bitchat.sonar.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Sonar icon set — a 1:1 port of design/handoff/project/sonar/icons.jsx (24×24
 * viewBox, 1.7px stroke, round caps), mirroring iOS SonarIcons.swift. Strokes
 * and filled sub-shapes are drawn from the same SVG path data.
 */
enum class SNIconName {
    Back, Chevron, Lock, Plus, Pin, People, Mesh, Globe, Check, Shield,
    ShieldCheck, X, Smile, NavArrow, Dice, Rings, Moon, Trash, Info, Coin, Bolt,
    Pencil, Key, Search, Mic, Play, Pause, Bookmark, BookmarkFill, ImportKey,
    // Call glyphs (design icons.jsx): voice/video buttons + in-call controls.
    Phone, Videocam, PhoneDown, MicOff, VideoOff, Speaker, CameraFlip,
}

private sealed interface Shape {
    data class P(val d: String, val fill: Boolean = false) : Shape
    data class C(val cx: Float, val cy: Float, val r: Float, val fill: Boolean = false) : Shape
    data class R(val x: Float, val y: Float, val w: Float, val h: Float, val rx: Float) : Shape
}

private val ICONS: Map<SNIconName, List<Shape>> = mapOf(
    SNIconName.Back to listOf(Shape.P("M14.5 4.5 7 12l7.5 7.5")),
    SNIconName.Chevron to listOf(Shape.P("M9.5 5l7 7-7 7")),
    // design icons.jsx `mic`: rounded mic body + the stand/arc.
    SNIconName.Mic to listOf(Shape.R(9.2f, 3.4f, 5.6f, 11f, 2.8f), Shape.P("M5.8 11.5a6.2 6.2 0 0 0 12.4 0M12 17.7V20.4M9 20.6h6")),
    SNIconName.Play to listOf(Shape.P("M7.5 5.5v13l11-6.5z", fill = true)),
    // Two filled bars — the playing-state toggle for the audio bubble.
    SNIconName.Pause to listOf(Shape.P("M8.5 5.5h2.4v13H8.5zM13.1 5.5h2.4v13h-2.4z", fill = true)),
    // Bookmark — the "save channel" toggle (outline = not saved, fill = saved).
    SNIconName.Bookmark to listOf(Shape.P("M6.8 4.8h10.4a.6.6 0 0 1 .6.6v14.3l-5.8-3.4-5.8 3.4V5.4a.6.6 0 0 1 .6-.6z")),
    SNIconName.BookmarkFill to listOf(Shape.P("M6.8 4.8h10.4a.6.6 0 0 1 .6.6v14.3l-5.8-3.4-5.8 3.4V5.4a.6.6 0 0 1 .6-.6z", fill = true)),
    SNIconName.Lock to listOf(Shape.R(5.5f, 10.5f, 13f, 9.5f, 2.6f), Shape.P("M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5")),
    SNIconName.Plus to listOf(Shape.P("M12 5.5v13M5.5 12h13")),
    SNIconName.Pin to listOf(Shape.P("M12 20.8s-6.3-5.3-6.3-10.2a6.3 6.3 0 0 1 12.6 0c0 4.9-6.3 10.2-6.3 10.2z"), Shape.C(12f, 10.4f, 2.2f)),
    SNIconName.People to listOf(Shape.C(9f, 8.4f, 3.1f), Shape.P("M3.6 19.4c.6-3.3 2.8-5 5.4-5s4.8 1.7 5.4 5"), Shape.C(16.8f, 9.4f, 2.5f), Shape.P("M16.6 14.5c2.1.4 3.5 2 3.9 4.7")),
    SNIconName.Mesh to listOf(Shape.C(12f, 12f, 1.7f, fill = true), Shape.P("M8.7 8.7a4.7 4.7 0 0 0 0 6.6M15.3 8.7a4.7 4.7 0 0 1 0 6.6M6.2 6.2a8.2 8.2 0 0 0 0 11.6M17.8 6.2a8.2 8.2 0 0 1 0 11.6")),
    SNIconName.Globe to listOf(Shape.C(12f, 12f, 8.2f), Shape.P("M3.8 12h16.4M12 3.8c-2.7 2.5-4.1 5.2-4.1 8.2s1.4 5.7 4.1 8.2c2.7-2.5 4.1-5.2 4.1-8.2S14.7 6.3 12 3.8z")),
    SNIconName.Check to listOf(Shape.P("M5 12.8l4.3 4.3L19 7.4")),
    SNIconName.Shield to listOf(Shape.P("M12 3.4l7 2.7v5.2c0 4.4-2.9 7.4-7 9-4.1-1.6-7-4.6-7-9V6.1z")),
    SNIconName.ShieldCheck to listOf(Shape.P("M12 3.4l7 2.7v5.2c0 4.4-2.9 7.4-7 9-4.1-1.6-7-4.6-7-9V6.1z"), Shape.P("M8.8 12.1l2.3 2.3 4.3-4.6")),
    SNIconName.X to listOf(Shape.P("M6.5 6.5l11 11M17.5 6.5l-11 11")),
    SNIconName.Smile to listOf(Shape.C(12f, 12f, 8.2f), Shape.C(9.1f, 10.2f, 1.1f, fill = true), Shape.C(14.9f, 10.2f, 1.1f, fill = true), Shape.P("M8.7 14.2a4.5 4.5 0 0 0 6.6 0")),
    SNIconName.NavArrow to listOf(Shape.P("M20.4 3.6 3.8 10.2l6.6 3.4 3.4 6.6z")),
    SNIconName.Dice to listOf(Shape.R(4.2f, 4.2f, 15.6f, 15.6f, 4f), Shape.C(8.8f, 8.8f, 1.2f, fill = true), Shape.C(15.2f, 8.8f, 1.2f, fill = true), Shape.C(12f, 12f, 1.2f, fill = true), Shape.C(8.8f, 15.2f, 1.2f, fill = true), Shape.C(15.2f, 15.2f, 1.2f, fill = true)),
    SNIconName.Rings to listOf(Shape.C(12f, 12f, 2f, fill = true), Shape.C(12f, 12f, 5.8f), Shape.C(12f, 12f, 9.4f)),
    SNIconName.Moon to listOf(Shape.P("M19 13.8A7.6 7.6 0 1 1 10.2 5 6.1 6.1 0 0 0 19 13.8z")),
    SNIconName.Trash to listOf(Shape.P("M5 7h14M10 7V5.6A1.6 1.6 0 0 1 11.6 4h.8A1.6 1.6 0 0 1 14 5.6V7"), Shape.P("M7 7l.8 12a1.8 1.8 0 0 0 1.8 1.7h4.8a1.8 1.8 0 0 0 1.8-1.7L17 7")),
    SNIconName.Info to listOf(Shape.C(12f, 12f, 8.2f), Shape.P("M12 11.2v5"), Shape.C(12f, 8f, 1.1f, fill = true)),
    SNIconName.Coin to listOf(Shape.C(12f, 12f, 8.4f), Shape.P("M9.9 8.2h3a1.9 1.9 0 0 1 0 3.8h-3zM9.9 12h3.5a1.9 1.9 0 0 1 0 3.8H9.9zM9.9 8.2V16M11.4 6.6v1.6M11.4 16v1.6")),
    SNIconName.Bolt to listOf(Shape.P("M13 3 6 13.5h4.5L11 21l7-10.5h-4.5z")),
    SNIconName.Pencil to listOf(Shape.P("M16.8 4.6l2.6 2.6L8.6 18l-3.4.8.8-3.4z")),
    SNIconName.Key to listOf(Shape.C(8.5f, 12f, 3.4f), Shape.P("M11.9 12h8M17 12v2.8M19.9 12v2")),
    SNIconName.ImportKey to listOf(
        Shape.C(8f, 12f, 3.2f),
        Shape.P("M11.2 12h9M16.5 12v3M20.2 12v2.4"),
        Shape.P("M14 5.5 11 8.5M14 5.5l-3-3M11 8.5l-2.4-2.4"),
    ),
    SNIconName.Search to listOf(Shape.C(10.5f, 10.5f, 5.5f), Shape.P("M14.5 14.5L20 20")),
    // ── call glyphs (verbatim from design icons.jsx) ──
    SNIconName.Phone to listOf(Shape.P("M6.5 4.5c-1 0-2 .9-2 2 0 7 6 13 13 13 1.1 0 2-1 2-2v-2.6c0-.5-.4-.9-.9-1l-3-.6c-.4-.1-.9.1-1.1.5l-1 1.6a11 11 0 0 1-5-5l1.6-1c.4-.2.6-.7.5-1.1l-.6-3c-.1-.5-.5-.9-1-.9z")),
    SNIconName.Videocam to listOf(Shape.R(3.5f, 7f, 12f, 10f, 2.5f), Shape.P("M15.5 11l5-2.6v7.2l-5-2.6z")),
    SNIconName.PhoneDown to listOf(Shape.P("M3.5 13.5c4.7-4 12.3-4 17 0l-2.2 2.6c-.4.5-1.1.5-1.6.2l-1.9-1.2a1.1 1.1 0 0 1-.5-1.2l.3-1.4a11 11 0 0 0-5.7 0l.3 1.4c.1.5-.1 1-.5 1.2l-1.9 1.2c-.5.3-1.2.3-1.6-.2z")),
    SNIconName.MicOff to listOf(Shape.P("M9.2 5.4a2.8 2.8 0 0 1 5.6.8v4M14.8 12.8a2.8 2.8 0 0 1-5.6-1.2V9.2M5.8 11.5a6.2 6.2 0 0 0 9.5 5.3M18.2 11.5a6.2 6.2 0 0 1-.4 2.2M12 17.7V20.4M9 20.6h6"), Shape.P("M4.5 4.5l15 15")),
    SNIconName.VideoOff to listOf(Shape.P("M3.5 7h9a2.5 2.5 0 0 1 2.5 2.5v.5l5-2.6v7.2l-5-2.6"), Shape.P("M4.5 4.5l15 15")),
    SNIconName.Speaker to listOf(Shape.P("M5 9.5v5h3l4 3.5v-12L8 9.5z"), Shape.P("M15.5 9a4 4 0 0 1 0 6M17.8 6.8a7 7 0 0 1 0 10.4")),
    SNIconName.CameraFlip to listOf(Shape.R(3.5f, 6.5f, 17f, 13f, 3f), Shape.P("M8.5 13a3.5 3.5 0 0 1 6-2.4M15.5 13a3.5 3.5 0 0 1-6 2.4"), Shape.P("M14.2 8.2 14.6 10.4 12.4 10.2M9.8 17.8 9.4 15.6 11.6 15.8"), Shape.P("M8 6.5l1-2h6l1 2")),
)

@Composable
fun SNIcon(name: SNIconName, size: Dp, color: Color, weight: Float = 1.7f) {
    val shapes = ICONS[name] ?: return
    Canvas(Modifier.size(size)) {
        val scale = this.size.minDimension / 24f
        val sw = weight * scale
        val strokePaths = Path()
        val fillPaths = Path()
        for (s in shapes) {
            when (s) {
                is Shape.P -> {
                    val p = parseSvgPath(s.d, scale)
                    if (s.fill) fillPaths.addPath(p) else strokePaths.addPath(p)
                }
                is Shape.C -> {
                    val target = if (s.fill) fillPaths else strokePaths
                    target.addCircle(s.cx * scale, s.cy * scale, s.r * scale)
                }
                is Shape.R -> strokePaths.addRoundRectPath(
                    s.x * scale, s.y * scale, s.w * scale, s.h * scale, s.rx * scale
                )
            }
        }
        if (!fillPaths.isEmpty) drawPath(fillPaths, color)
        if (!strokePaths.isEmpty) drawPath(
            strokePaths, color,
            style = Stroke(width = sw, cap = StrokeCap.Round, join = StrokeJoin.Round)
        )
    }
}

private fun Path.addCircle(cx: Float, cy: Float, r: Float) {
    addOval(Rect(Offset(cx - r, cy - r), Size(r * 2, r * 2)))
}

private fun Path.addRoundRectPath(x: Float, y: Float, w: Float, h: Float, rx: Float) {
    val p = Path()
    p.addRoundRect(
        androidx.compose.ui.geometry.RoundRect(
            x, y, x + w, y + h,
            androidx.compose.ui.geometry.CornerRadius(rx, rx)
        )
    )
    addPath(p)
}

// ── Minimal SVG path parser: M m L l H h V v C c S s A a Z z ──
private fun parseSvgPath(d: String, scale: Float): Path {
    val path = Path()
    val tokens = tokenize(d)
    var i = 0
    var cx = 0f; var cy = 0f          // current point (unscaled units)
    var sx = 0f; var sy = 0f          // subpath start
    var prevCtrlX = 0f; var prevCtrlY = 0f
    var prevCmd = ' '
    fun num(): Float = tokens[i++].toFloat()
    fun mv(x: Float, y: Float) { cx = x; cy = y; path.moveTo(x * scale, y * scale) }
    fun ln(x: Float, y: Float) { cx = x; cy = y; path.lineTo(x * scale, y * scale) }
    fun cube(x1: Float, y1: Float, x2: Float, y2: Float, x: Float, y: Float) {
        path.cubicTo(x1 * scale, y1 * scale, x2 * scale, y2 * scale, x * scale, y * scale)
        prevCtrlX = x2; prevCtrlY = y2; cx = x; cy = y
    }
    while (i < tokens.size) {
        val t = tokens[i]
        val cmd = if (t.length == 1 && t[0].isLetter()) { i++; t[0] } else prevCmd
        prevCmd = cmd
        when (cmd) {
            'M' -> { mv(num(), num()); sx = cx; sy = cy; prevCmd = 'L' }
            'm' -> { mv(cx + num(), cy + num()); sx = cx; sy = cy; prevCmd = 'l' }
            'L' -> ln(num(), num())
            'l' -> ln(cx + num(), cy + num())
            'H' -> ln(num(), cy)
            'h' -> ln(cx + num(), cy)
            'V' -> ln(cx, num())
            'v' -> ln(cx, cy + num())
            'C' -> cube(num(), num(), num(), num(), num(), num())
            'c' -> cube(cx + num(), cy + num(), cx + num(), cy + num(), cx + num(), cy + num())
            'S' -> { val x2 = num(); val y2 = num(); val x = num(); val y = num(); val r = reflect(cx, cy, prevCtrlX, prevCtrlY); cube(r.first, r.second, x2, y2, x, y) }
            's' -> { val x2 = cx + num(); val y2 = cy + num(); val x = cx + num(); val y = cy + num(); val r = reflect(cx, cy, prevCtrlX, prevCtrlY); cube(r.first, r.second, x2, y2, x, y) }
            'A' -> { val rx = num(); val ry = num(); val rot = num(); val laf = num(); val sf = num(); val x = num(); val y = num(); arc(path, cx, cy, rx, ry, rot, laf != 0f, sf != 0f, x, y, scale); cx = x; cy = y }
            'a' -> { val rx = num(); val ry = num(); val rot = num(); val laf = num(); val sf = num(); val x = cx + num(); val y = cy + num(); arc(path, cx, cy, rx, ry, rot, laf != 0f, sf != 0f, x, y, scale); cx = x; cy = y }
            'Z', 'z' -> { path.close(); cx = sx; cy = sy }
            else -> i++
        }
    }
    return path
}

private fun reflect(cx: Float, cy: Float, px: Float, py: Float) = Pair(2 * cx - px, 2 * cy - py)

private fun tokenize(d: String): List<String> {
    val out = ArrayList<String>()
    val sb = StringBuilder()
    fun flush() { if (sb.isNotEmpty()) { out.add(sb.toString()); sb.clear() } }
    for (c in d) {
        when {
            c.isLetter() -> { flush(); out.add(c.toString()) }
            c == '-' -> { if (sb.isNotEmpty() && sb.last() != 'e' && sb.last() != 'E') flush(); sb.append(c) }
            c == ' ' || c == ',' || c == '\n' || c == '\t' -> flush()
            c == '.' -> { if (sb.contains('.')) { flush() }; sb.append(c) }
            else -> sb.append(c)
        }
    }
    flush()
    return out
}

// SVG endpoint-arc → Compose cubic segments (handles rx==ry circular arcs used by the set).
private fun arc(
    path: Path, x0f: Float, y0f: Float, rxIn: Float, ryIn: Float, rotDeg: Float,
    largeArc: Boolean, sweep: Boolean, xf: Float, yf: Float, scale: Float
) {
    val x0 = x0f.toDouble(); val y0 = y0f.toDouble(); val x = xf.toDouble(); val y = yf.toDouble()
    var rx = abs(rxIn.toDouble()); var ry = abs(ryIn.toDouble())
    if (rx == 0.0 || ry == 0.0) { path.lineTo(xf * scale, yf * scale); return }
    val phi = rotDeg.toDouble() * PI / 180.0
    val cosP = cos(phi); val sinP = sin(phi)
    val dx = (x0 - x) / 2.0; val dy = (y0 - y) / 2.0
    val x1p = cosP * dx + sinP * dy
    val y1p = -sinP * dx + cosP * dy
    var rxs = rx * rx; var rys = ry * ry
    val x1ps = x1p * x1p; val y1ps = y1p * y1p
    val lambda = x1ps / rxs + y1ps / rys
    if (lambda > 1) { val s = sqrt(lambda); rx *= s; ry *= s; rxs = rx * rx; rys = ry * ry }
    var sign = if (largeArc != sweep) 1.0 else -1.0
    var num = rxs * rys - rxs * y1ps - rys * x1ps
    if (num < 0) num = 0.0
    val den = rxs * y1ps + rys * x1ps
    val co = sign * sqrt(num / den)
    val cxp = co * (rx * y1p / ry)
    val cyp = co * -(ry * x1p / rx)
    val cxc = cosP * cxp - sinP * cyp + (x0 + x) / 2.0
    val cyc = sinP * cxp + cosP * cyp + (y0 + y) / 2.0
    fun angle(ux: Double, uy: Double, vx: Double, vy: Double): Double {
        val dot = ux * vx + uy * vy
        val len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
        var a = kotlin.math.acos((dot / len).coerceIn(-1.0, 1.0))
        if (ux * vy - uy * vx < 0) a = -a
        return a
    }
    val theta1 = angle(1.0, 0.0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if (!sweep && dTheta > 0) dTheta -= 2 * PI
    if (sweep && dTheta < 0) dTheta += 2 * PI
    val segs = ceil(abs(dTheta) / (PI / 2)).toInt().coerceAtLeast(1)
    val delta = dTheta / segs
    val t = 4.0 / 3.0 * kotlin.math.tan(delta / 4.0)
    var ang = theta1
    for (s in 0 until segs) {
        val cosA = cos(ang); val sinA = sin(ang)
        val cosB = cos(ang + delta); val sinB = sin(ang + delta)
        val p1x = cxc + rx * cosP * cosA - ry * sinP * sinA
        val p1y = cyc + rx * sinP * cosA + ry * cosP * sinA
        val p4x = cxc + rx * cosP * cosB - ry * sinP * sinB
        val p4y = cyc + rx * sinP * cosB + ry * cosP * sinB
        val d1x = -rx * cosP * sinA - ry * sinP * cosA
        val d1y = -rx * sinP * sinA + ry * cosP * cosA
        val d4x = -rx * cosP * sinB - ry * sinP * cosB
        val d4y = -rx * sinP * sinB + ry * cosP * cosB
        val c1x = p1x + t * d1x; val c1y = p1y + t * d1y
        val c2x = p4x - t * d4x; val c2y = p4y - t * d4y
        path.cubicTo(
            (c1x * scale).toFloat(), (c1y * scale).toFloat(),
            (c2x * scale).toFloat(), (c2y * scale).toFloat(),
            (p4x * scale).toFloat(), (p4y * scale).toFloat()
        )
        ang += delta
    }
}
