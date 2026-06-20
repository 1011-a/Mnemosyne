import SwiftUI

/// A live "Knowledge City at Night" — a pixel-art skyline whose windows light up
/// as files are indexed, with a little robot mascot, twinkling stars, CRT scanlines
/// + glow, a hand-drawn pixel font counter, and a typewriter activity ticker with a
/// blinking cursor. Purely a generated scene (Canvas), driven by `IngestProgress`.
///
/// This is a deliberate retro art element, so it uses its own small pixel palette
/// rather than the app's Swiss tokens.
struct PixelCityView: View {
    @Bindable var progress: IngestProgress
    @State private var ticker = ""
    @State private var tickerSince = Date()

    // Pixel palette (night city).
    private let sky1 = Color(red: 0.04, green: 0.05, blue: 0.15)
    private let sky2 = Color(red: 0.16, green: 0.10, blue: 0.28)
    private let bldg = Color(red: 0.07, green: 0.09, blue: 0.20)
    private let bldgEdge = Color(red: 0.11, green: 0.14, blue: 0.30)
    private let winOn = Color(red: 1.00, green: 0.82, blue: 0.42)
    private let winOff = Color(red: 0.10, green: 0.13, blue: 0.27)
    private let starC = Color(red: 0.85, green: 0.88, blue: 1.0)
    private let moonC = Color(red: 0.98, green: 0.95, blue: 0.80)
    private let ink = Color(red: 1.0, green: 0.93, blue: 0.78)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let s: CGFloat = 4                       // one pixel = 4pt (chunky)
                let gw = Int(size.width / s)
                let gh = Int(size.height / s)
                func px(_ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1, _ c: Color) {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s,
                                         width: CGFloat(w) * s, height: CGFloat(h) * s)),
                             with: .color(c))
                }

                // Sky gradient
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [sky1, sky2]),
                                               startPoint: .zero,
                                               endPoint: CGPoint(x: 0, y: size.height)))

                // Stars (twinkle)
                for i in 0..<60 {
                    let sx = Int(rnd(i &* 2) * Double(gw))
                    let sy = Int(rnd(i &* 2 &+ 1) * Double(gh) * 0.6)
                    let tw = 0.35 + 0.65 * abs(sin(t * 1.6 + Double(i)))
                    px(sx, sy, 1, 1, starC.opacity(tw))
                }

                // Moon (top-right) with a couple craters
                let mx = gw - 11, my = 7, mr = 5
                for dy in -mr...mr { for dx in -mr...mr where dx*dx + dy*dy <= mr*mr {
                    px(mx + dx, my + dy, 1, 1, moonC)
                } }
                px(mx - 1, my - 1, 1, 1, moonC.opacity(0.5))
                px(mx + 2, my + 1, 1, 1, moonC.opacity(0.5))

                // Skyline — buildings with windows that light up by progress fraction.
                let frac = progress.fraction
                let groundY = gh - 1
                var bx = 1
                var b = 0
                var roofForMascot: (x: Int, y: Int)? = nil
                while bx < gw - 2 {
                    let w = 5 + Int(rnd(b &* 7 &+ 1) * 5)
                    let maxH = max(8, gh - 6)
                    let h = 8 + Int(rnd(b &* 7 &+ 2) * Double(maxH - 8))
                    let topY = groundY - h
                    px(bx, topY, w, h, bldg)
                    px(bx, topY, w, 1, bldgEdge)                 // roof line
                    // windows: 1px on a 2px grid, inset 1
                    var wy = topY + 2, wi = 0
                    while wy < groundY - 1 {
                        var wx = bx + 1
                        while wx < bx + w - 1 {
                            let on = rnd((b &* 131 &+ wi) &* 7 &+ 3) < frac
                            let flick = on && (Int(t * 6 + Double(wi)) % 23 == 0) // rare flicker
                            px(wx, wy, 1, 1, on ? (flick ? winOff : winOn) : winOff)
                            wx += 2; wi += 1
                        }
                        wy += 2
                    }
                    if roofForMascot == nil && h > gh / 2 { roofForMascot = (bx + w / 2 - 3, topY) }
                    bx += w + 1 + Int(rnd(b &* 7 &+ 4) * 2)
                    b += 1
                }

                // Mascot robot on a rooftop (bobs + blinks).
                if let roof = roofForMascot {
                    let bob = Int(sin(t * 3) * 1.4) >= 1 ? 1 : 0
                    drawRobot(px, ox: roof.x, oy: roof.y - 7 - bob, t: t)
                }

                // Scanlines + soft top glow (CRT)
                for y in stride(from: 0, to: gh, by: 2) { px(0, y, gw, 1, .black.opacity(0.10)) }
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.5)),
                         with: .linearGradient(Gradient(colors: [Color.white.opacity(0.05), .clear]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.5)))

                // HUD — counter (pixel font) + progress bar
                PixelFont.draw(&ctx, "KNOWLEDGE INDEXED", x: 2, y: 2, s: s, color: ink.opacity(0.7))
                PixelFont.draw(&ctx, grouped(progress.libraryItems), x: 2, y: 8, s: s * 2, color: ink)
                let barW = gw - 4, fillW = Int(Double(barW) * frac)
                px(2, gh - 9, barW, 1, winOff)
                if fillW > 0 { px(2, gh - 9, fillW, 1, winOn) }

                // Ticker (typewriter + blinking cursor) along the very bottom.
                let reveal = min(ticker.count, Int(tl.date.timeIntervalSince(tickerSince) * 30))
                let shown = String(ticker.prefix(reveal))
                let cursor = (Int(t * 2) % 2 == 0) ? "_" : " "
                PixelFont.draw(&ctx, shown + cursor, x: 2, y: gh - 6, s: s, color: winOn.opacity(0.95))
            }
        }
        .frame(height: 250)
        .background(sky1)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
            .strokeBorder(DS.ColorToken.borderDefault))
        .onChange(of: progress.log.last?.id) { _, _ in
            if let last = progress.log.last {
                ticker = "\(last.symbol) \(last.text)"
                tickerSince = Date()
            }
        }
    }

    /// A tiny robot sprite drawn relative to (ox, oy). Blinks every few seconds.
    private func drawRobot(_ px: (Int, Int, Int, Int, Color) -> Void, ox: Int, oy: Int, t: Double) {
        let body = Color(red: 0.80, green: 0.84, blue: 0.95)
        let dark = Color(red: 0.30, green: 0.34, blue: 0.48)
        let eye = Color(red: 1.0, green: 0.82, blue: 0.42)
        let blink = Int(t) % 4 == 0 && (t.truncatingRemainder(dividingBy: 1) < 0.18)
        px(ox + 3, oy, 1, 1, eye.opacity(0.9))        // antenna tip
        px(ox + 3, oy + 1, 1, 1, dark)                 // antenna
        px(ox + 1, oy + 2, 5, 3, body)                 // head
        px(ox + 1, oy + 2, 5, 1, dark)                 // brow
        if !blink { px(ox + 2, oy + 3, 1, 1, eye); px(ox + 4, oy + 3, 1, 1, eye) }
        px(ox + 2, oy + 5, 3, 2, body)                 // body
        px(ox + 2, oy + 5, 3, 1, dark)
    }

    private func grouped(_ n: Int) -> String {
        let s = String(n); var out = ""; var c = 0
        for ch in s.reversed() { if c != 0 && c % 3 == 0 { out.append(",") }; out.append(ch); c += 1 }
        return String(out.reversed())
    }

    /// Deterministic hash → 0..1 (stable stars/buildings across frames).
    private func rnd(_ n: Int) -> Double {
        var x = UInt64(bitPattern: Int64(n &* 2654435761)) & 0xFFFFFFFF
        x ^= x >> 13; x = x &* 1274126177; x ^= x >> 16
        return Double(x & 0xFFFF) / 65535.0
    }
}

/// A hand-authored 3×5 pixel font (uppercase + digits + a few symbols) so the HUD
/// and ticker render as authentic pixel text. Each row's low 3 bits are columns
/// (bit 2 = left). Unknown characters render as blank.
enum PixelFont {
    static func draw(_ ctx: inout GraphicsContext, _ text: String, x: Int, y: Int, s: CGFloat, color: Color) {
        var cx = x
        for ch in text.uppercased() {
            let g = glyphs[ch] ?? glyphs[" "]!
            for (r, row) in g.enumerated() {
                for c in 0..<3 where (row & (UInt8(4) >> UInt8(c))) != 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(cx + c) * s, y: CGFloat(y + r) * s,
                                         width: s, height: s)), with: .color(color))
                }
            }
            cx += 4
        }
    }

    static let glyphs: [Character: [UInt8]] = [
        "0": [7,5,5,5,7], "1": [2,6,2,2,7], "2": [7,1,7,4,7], "3": [7,1,7,1,7],
        "4": [5,5,7,1,1], "5": [7,4,7,1,7], "6": [7,4,7,5,7], "7": [7,1,2,2,2],
        "8": [7,5,7,5,7], "9": [7,5,7,1,7],
        "A": [2,5,7,5,5], "B": [6,5,6,5,6], "C": [3,4,4,4,3], "D": [6,5,5,5,6],
        "E": [7,4,6,4,7], "F": [7,4,6,4,4], "G": [3,4,5,5,3], "H": [5,5,7,5,5],
        "I": [7,2,2,2,7], "J": [1,1,1,5,2], "K": [5,5,6,5,5], "L": [4,4,4,4,7],
        "M": [5,7,7,5,5], "N": [5,7,7,7,5], "O": [7,5,5,5,7], "P": [6,5,6,4,4],
        "Q": [7,5,5,7,1], "R": [6,5,6,5,5], "S": [3,4,2,1,6], "T": [7,2,2,2,2],
        "U": [5,5,5,5,7], "V": [5,5,5,5,2], "W": [5,5,7,7,5], "X": [5,5,2,5,5],
        "Y": [5,5,2,2,2], "Z": [7,1,2,4,7],
        " ": [0,0,0,0,0], ".": [0,0,0,0,2], "_": [0,0,0,0,7], "-": [0,0,7,0,0],
        "/": [1,1,2,4,4], ":": [0,2,0,2,0], ",": [0,0,0,2,4], "(": [1,2,2,2,1],
        ")": [4,2,2,2,4], "!": [2,2,2,0,2], "?": [7,1,2,0,2], "+": [0,2,7,2,0],
        "#": [5,7,5,7,5], "<": [1,2,4,2,1], ">": [4,2,1,2,4], "*": [5,2,7,2,5],
    ]
}
