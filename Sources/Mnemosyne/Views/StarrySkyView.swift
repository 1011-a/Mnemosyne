import SwiftUI

/// A warm "Starry Night" live-activity scene: a deep night sky where stars LIGHT UP as
/// files are indexed (the share of lit stars tracks ingest progress, and they twinkle),
/// a crescent moon and the odd shooting star — and, on a grassy hill below, a family of
/// four (two parents and two girls) sitting close together by a warm lantern, gazing up.
/// Purely a generated Canvas scene driven by `IngestProgress`. Cozy by design.
struct StarrySkyView: View {
    @Bindable var progress: IngestProgress

    // Palette — cool sky, warm family/lantern (the warmth is the point).
    private let skyTop = Color(red: 0.03, green: 0.04, blue: 0.13)
    private let skyMid = Color(red: 0.08, green: 0.07, blue: 0.20)
    private let skyLow = Color(red: 0.16, green: 0.12, blue: 0.26)
    private let starLit = Color(red: 1.00, green: 0.95, blue: 0.82)
    private let starDim = Color(red: 0.55, green: 0.60, blue: 0.78)
    private let moonC = Color(red: 0.99, green: 0.96, blue: 0.86)
    private let hill = Color(red: 0.05, green: 0.06, blue: 0.12)
    private let hill2 = Color(red: 0.09, green: 0.08, blue: 0.16)
    private let warm = Color(red: 1.00, green: 0.78, blue: 0.45)
    private let warmDeep = Color(red: 0.95, green: 0.55, blue: 0.28)
    private let figure = Color(red: 0.04, green: 0.03, blue: 0.07)

    private let totalStars = 150

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let W = size.width, H = size.height
                let frac = progress.fraction
                let litCount = max(progress.isRunning ? 8 : 4, Int(Double(totalStars) * frac))

                // 1) Sky gradient.
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [skyTop, skyMid, skyLow]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: H)))

                // 2) Crescent moon, top-right (a bright disc with an offset shadow disc).
                let moonR = min(H * 0.16, 30)
                let moon = CGPoint(x: W - moonR * 1.8, y: moonR * 1.5)
                ctx.fill(Path(ellipseIn: CGRect(x: moon.x - moonR, y: moon.y - moonR,
                                                width: moonR * 2, height: moonR * 2)),
                         with: .radialGradient(Gradient(colors: [moonC, moonC.opacity(0.85)]),
                                               center: moon, startRadius: 0, endRadius: moonR))
                ctx.fill(Path(ellipseIn: CGRect(x: moon.x - moonR * 1.35, y: moon.y - moonR,
                                                width: moonR * 2, height: moonR * 2)),
                         with: .color(skyMid))   // bite out the crescent

                // 3) Stars — lit ones (by progress) glow + twinkle; the rest stay faint.
                for i in 0..<totalStars {
                    let sx = rnd(i &* 2) * Double(W)
                    let sy = rnd(i &* 2 &+ 1) * Double(H) * 0.74     // keep above the hills
                    let lit = i < litCount
                    let twinkle = 0.5 + 0.5 * abs(sin(t * 1.4 + Double(i) * 0.7))
                    let r = lit ? (1.1 + 1.4 * twinkle) : 0.8
                    let c = lit ? starLit.opacity(0.55 + 0.45 * twinkle) : starDim.opacity(0.35)
                    if lit {   // soft halo on lit stars
                        ctx.fill(Path(ellipseIn: CGRect(x: sx - r * 2.2, y: sy - r * 2.2,
                                                        width: r * 4.4, height: r * 4.4)),
                                 with: .radialGradient(Gradient(colors: [starLit.opacity(0.22 * twinkle), .clear]),
                                                       center: CGPoint(x: sx, y: sy), startRadius: 0, endRadius: r * 2.2))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2)), with: .color(c))
                }

                // 4) An occasional shooting star (only while running).
                if progress.isRunning {
                    let period = 6.0
                    let phase = (t.truncatingRemainder(dividingBy: period)) / period   // 0..1
                    if phase < 0.18 {
                        let p = phase / 0.18
                        let sx = W * (0.15 + 0.6 * p), sy = H * (0.12 + 0.18 * p)
                        var tail = Path(); tail.move(to: CGPoint(x: sx, y: sy))
                        tail.addLine(to: CGPoint(x: sx - 26, y: sy - 9))
                        ctx.stroke(tail, with: .linearGradient(Gradient(colors: [starLit.opacity(0.9), .clear]),
                                                               startPoint: CGPoint(x: sx, y: sy),
                                                               endPoint: CGPoint(x: sx - 26, y: sy - 9)), lineWidth: 1.6)
                    }
                }

                // 5) Rolling hills (two layers for depth).
                hillPath(width: W, baseY: H - H * 0.16, amp: 10, phase: 0.6).map { ctx.fill($0, with: .color(hill2)) }
                hillPath(width: W, baseY: H - H * 0.10, amp: 7, phase: 2.1).map { ctx.fill($0, with: .color(hill)) }

                // 6) The family, centered low on the front hill, with a warm lantern glow.
                let groundY = H - H * 0.085
                let cx = W * 0.5
                // Warm lantern glow pooled around them.
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 90, y: groundY - 46, width: 180, height: 90)),
                         with: .radialGradient(Gradient(colors: [warm.opacity(0.30), warmDeep.opacity(0.10), .clear]),
                                               center: CGPoint(x: cx + 34, y: groundY - 6), startRadius: 2, endRadius: 96))
                drawFamily(&ctx, centerX: cx, groundY: groundY, t: t)
                // The lantern itself (small warm point with a glow), to one side.
                let lan = CGPoint(x: cx + 40, y: groundY - 6)
                ctx.fill(Path(ellipseIn: CGRect(x: lan.x - 9, y: lan.y - 9, width: 18, height: 18)),
                         with: .radialGradient(Gradient(colors: [warm.opacity(0.9), .clear]),
                                               center: lan, startRadius: 0, endRadius: 9))
                ctx.fill(Path(ellipseIn: CGRect(x: lan.x - 1.6, y: lan.y - 2.4, width: 3.2, height: 4.8)), with: .color(warm))

                // 7) Soft HUD — count + "stars lit", in a warm tint so it reads as cozy.
                ctx.draw(Text("Knowledge indexed").font(.system(size: 11, weight: .semibold)).foregroundStyle(warm.opacity(0.8)),
                         at: CGPoint(x: 14, y: 16), anchor: .topLeading)
                ctx.draw(Text(grouped(progress.libraryItems)).font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(starLit),
                         at: CGPoint(x: 14, y: 28), anchor: .topLeading)
                ctx.draw(Text("\(litCount) stars lit").font(.system(size: 10, weight: .medium)).foregroundStyle(starDim),
                         at: CGPoint(x: 14, y: 62), anchor: .topLeading)
            }
        }
        .frame(height: 320)
        .background(skyTop)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
            .strokeBorder(DS.ColorToken.borderDefault))
    }

    // MARK: scene pieces

    /// A smooth hill silhouette across the width, or nil if degenerate.
    private func hillPath(width W: CGFloat, baseY: CGFloat, amp: CGFloat, phase: Double) -> Path? {
        guard W > 1 else { return nil }
        var p = Path()
        p.move(to: CGPoint(x: 0, y: baseY))
        var x: CGFloat = 0
        while x <= W {
            let y = baseY - amp * CGFloat(sin(Double(x) / 90.0 + phase)) - amp
            p.addLine(to: CGPoint(x: x, y: y))
            x += 8
        }
        p.addLine(to: CGPoint(x: W, y: baseY + 200))
        p.addLine(to: CGPoint(x: 0, y: baseY + 200))
        p.closeSubpath()
        return p
    }

    /// A family of four seen from behind, sitting close on the hill, looking up:
    /// two taller parents flanking two smaller girls. Simple warm-dark silhouettes.
    private func drawFamily(_ ctx: inout GraphicsContext, centerX cx: CGFloat, groundY: CGFloat, t: Double) {
        // gentle "breathing" sway so it feels alive
        let sway = CGFloat(sin(t * 0.8)) * 0.6
        func person(_ x: CGFloat, headR: CGFloat, bodyH: CGFloat, bodyW: CGFloat, lean: CGFloat) {
            // body: a rounded shoulders shape (sitting)
            let bx = x - bodyW / 2 + lean
            let by = groundY - bodyH
            ctx.fill(Path(roundedRect: CGRect(x: bx, y: by, width: bodyW, height: bodyH + 8),
                          cornerSize: CGSize(width: bodyW * 0.5, height: bodyW * 0.5)),
                     with: .color(figure))
            // head
            let hx = x + lean * 1.4
            ctx.fill(Path(ellipseIn: CGRect(x: hx - headR, y: by - headR * 1.7, width: headR * 2, height: headR * 2)),
                     with: .color(figure))
        }
        // Two girls in the middle (smaller), leaning toward the parents; parents outside.
        person(cx - 30 + sway, headR: 7,   bodyH: 26, bodyW: 22, lean: -1)   // parent (left)
        person(cx - 11 + sway, headR: 5,   bodyH: 18, bodyW: 15, lean: -2.5) // girl  (leans left, onto parent)
        person(cx + 11 + sway, headR: 5,   bodyH: 18, bodyW: 15, lean:  2.5) // girl  (leans right)
        person(cx + 31 + sway, headR: 7.5, bodyH: 27, bodyW: 23, lean:  1)   // parent (right)
        // A small blanket line under them.
        ctx.stroke(Path { p in p.move(to: CGPoint(x: cx - 46, y: groundY + 4)); p.addLine(to: CGPoint(x: cx + 48, y: groundY + 4)) },
                   with: .color(warmDeep.opacity(0.5)), lineWidth: 2)
    }

    private func grouped(_ n: Int) -> String {
        let s = String(n); var out = ""; var c = 0
        for ch in s.reversed() { if c != 0 && c % 3 == 0 { out.append(",") }; out.append(ch); c += 1 }
        return String(out.reversed())
    }

    /// Deterministic hash → 0..1, so star positions are stable across frames.
    private func rnd(_ n: Int) -> Double {
        var x = UInt64(bitPattern: Int64(n &* 2654435761)) & 0xFFFFFFFF
        x ^= x >> 13; x = x &* 1274126177; x ^= x >> 16
        return Double(x & 0xFFFF) / 65535.0
    }
}
