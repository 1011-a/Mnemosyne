import SwiftUI

/// A warm "Starry Night" live-activity scene: a deep night sky where stars LIGHT UP as
/// files are indexed (the share of lit stars tracks ingest progress, and they twinkle),
/// a crescent moon and the odd shooting star — and, on a grassy hill below, a family of
/// four cuddled together under one blanket, gazing up at a bright "wish star". Purely a
/// generated Canvas scene driven by `IngestProgress`. Cozy by design.
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

                // 2) Crescent moon (a bright disc with an offset shadow disc).
                let moonR = min(H * 0.16, 30)
                let moon = CGPoint(x: W - moonR * 1.8, y: moonR * 1.5)
                ctx.fill(Path(ellipseIn: CGRect(x: moon.x - moonR, y: moon.y - moonR, width: moonR * 2, height: moonR * 2)),
                         with: .radialGradient(Gradient(colors: [moonC, moonC.opacity(0.85)]),
                                               center: moon, startRadius: 0, endRadius: moonR))
                ctx.fill(Path(ellipseIn: CGRect(x: moon.x - moonR * 1.35, y: moon.y - moonR, width: moonR * 2, height: moonR * 2)),
                         with: .color(skyMid))

                // 3) Stars — lit ones (by progress) glow + twinkle; the rest stay faint.
                for i in 0..<totalStars {
                    let sx = rnd(i &* 2) * Double(W)
                    let sy = rnd(i &* 2 &+ 1) * Double(H) * 0.74
                    let lit = i < litCount
                    let twinkle = 0.5 + 0.5 * abs(sin(t * 1.4 + Double(i) * 0.7))
                    let r = lit ? (1.1 + 1.4 * twinkle) : 0.8
                    let c = lit ? starLit.opacity(0.55 + 0.45 * twinkle) : starDim.opacity(0.35)
                    if lit {
                        ctx.fill(Path(ellipseIn: CGRect(x: sx - r * 2.2, y: sy - r * 2.2, width: r * 4.4, height: r * 4.4)),
                                 with: .radialGradient(Gradient(colors: [starLit.opacity(0.22 * twinkle), .clear]),
                                                       center: CGPoint(x: sx, y: sy), startRadius: 0, endRadius: r * 2.2))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2)), with: .color(c))
                }

                // 4) An occasional shooting star (only while running).
                if progress.isRunning {
                    let phase = (t.truncatingRemainder(dividingBy: 6.0)) / 6.0
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

                // 6) The "wish star" the family gazes at — extra bright, gently pulsing.
                let cx = W * 0.5
                let groundY = H - H * 0.085
                let wish = CGPoint(x: cx + 6, y: H * 0.26)
                let pulse = 0.7 + 0.3 * abs(sin(t * 1.1))
                ctx.fill(Path(ellipseIn: CGRect(x: wish.x - 15, y: wish.y - 15, width: 30, height: 30)),
                         with: .radialGradient(Gradient(colors: [starLit.opacity(0.4 * pulse), .clear]),
                                               center: wish, startRadius: 0, endRadius: 15))
                ctx.fill(Path(ellipseIn: CGRect(x: wish.x - 2.4, y: wish.y - 2.4, width: 4.8, height: 4.8)), with: .color(starLit))

                // 7) Warm lantern glow pooled gently around the family.
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 70, y: groundY - 40, width: 150, height: 78)),
                         with: .radialGradient(Gradient(colors: [warm.opacity(0.26), warmDeep.opacity(0.08), .clear]),
                                               center: CGPoint(x: cx + 30, y: groundY - 4), startRadius: 2, endRadius: 84))

                drawFamily(&ctx, centerX: cx, groundY: groundY, t: t)

                // The lantern itself.
                let lan = CGPoint(x: cx + 34, y: groundY - 6)
                ctx.fill(Path(ellipseIn: CGRect(x: lan.x - 9, y: lan.y - 9, width: 18, height: 18)),
                         with: .radialGradient(Gradient(colors: [warm.opacity(0.95), .clear]), center: lan, startRadius: 0, endRadius: 9))
                ctx.fill(Path(ellipseIn: CGRect(x: lan.x - 1.6, y: lan.y - 2.6, width: 3.2, height: 5.2)), with: .color(warm))

                // 8) Soft HUD.
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

    private func hillPath(width W: CGFloat, baseY: CGFloat, amp: CGFloat, phase: Double) -> Path? {
        guard W > 1 else { return nil }
        var p = Path()
        p.move(to: CGPoint(x: 0, y: baseY))
        var x: CGFloat = 0
        while x <= W {
            p.addLine(to: CGPoint(x: x, y: baseY - amp * CGFloat(sin(Double(x) / 90.0 + phase)) - amp))
            x += 8
        }
        p.addLine(to: CGPoint(x: W, y: baseY + 200)); p.addLine(to: CGPoint(x: 0, y: baseY + 200)); p.closeSubpath()
        return p
    }

    private enum Hair { case plain, bun, pigtails, ponytail }

    /// The family, cuddled together under ONE blanket, stargazing — a soft rounded
    /// "mound" with four heads (different sizes, leaning together) emerging from it, each
    /// with a warm rim on the lantern side and a cool moonlit catchlight. Cozy by
    /// construction: no harsh outlines, just soft warm-lit forms against the cool night.
    private func drawFamily(_ ctx: inout GraphicsContext, centerX cx: CGFloat, groundY: CGFloat, t: Double) {
        let breathe = CGFloat(sin(t * 0.9)) * 0.6
        let blanketLow = Color(red: 0.10, green: 0.08, blue: 0.18)

        // The blanket mound — a smooth rounded dome the family is wrapped in.
        let mb = groundY + 10 + breathe, mt = groundY - 36 + breathe, mw: CGFloat = 60
        var mound = Path()
        mound.move(to: CGPoint(x: cx - mw, y: mb))
        mound.addCurve(to: CGPoint(x: cx, y: mt),
                       control1: CGPoint(x: cx - mw, y: mt + 6), control2: CGPoint(x: cx - mw * 0.46, y: mt))
        mound.addCurve(to: CGPoint(x: cx + mw, y: mb),
                       control1: CGPoint(x: cx + mw * 0.46, y: mt), control2: CGPoint(x: cx + mw, y: mt + 6))
        mound.closeSubpath()
        ctx.fill(mound, with: .linearGradient(Gradient(colors: [figure, blanketLow]),
                                              startPoint: CGPoint(x: cx, y: mt), endPoint: CGPoint(x: cx, y: mb)))
        ctx.fill(mound, with: .radialGradient(Gradient(colors: [warm.opacity(0.16), .clear]),
                                              center: CGPoint(x: cx + 34, y: groundY - 6), startRadius: 2, endRadius: 62))
        for dx: CGFloat in [-26, 4, 30] {
            var fold = Path()
            fold.move(to: CGPoint(x: cx + dx, y: mb - 2))
            fold.addQuadCurve(to: CGPoint(x: cx + dx + 5, y: mt + 14), control: CGPoint(x: cx + dx + 10, y: mb - 18))
            ctx.stroke(fold, with: .color(.black.opacity(0.18)), lineWidth: 1)
        }

        /// One head emerging from the blanket, leaning by `tilt`, with hair, a warm rim and
        /// a cool catchlight.
        func head(dx: CGFloat, r: CGFloat, tilt: CGFloat, hair: Hair, rise: CGFloat) {
            let hx = cx + dx + tilt
            let hy = mt - r * 0.55 - rise + breathe
            let rect = CGRect(x: hx - r, y: hy - r, width: r * 2, height: r * 2)
            // hair (behind), framing the head
            ctx.fill(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)), with: .color(figure))
            switch hair {
            case .plain: break
            case .bun:
                ctx.fill(Path(ellipseIn: CGRect(x: hx - r * 0.42, y: hy - r - r * 0.6, width: r * 0.84, height: r * 0.84)), with: .color(figure))
            case .pigtails:
                for s in [-1.0, 1.0] as [CGFloat] {
                    ctx.fill(Path(ellipseIn: CGRect(x: hx + s * (r + 1) - r * 0.4, y: hy - r * 0.1, width: r * 0.8, height: r * 1.1)), with: .color(figure))
                }
            case .ponytail:
                ctx.fill(Path(ellipseIn: CGRect(x: hx - r - r * 0.5, y: hy - r * 0.2, width: r * 0.8, height: r * 1.5)), with: .color(figure))
            }
            ctx.fill(Path(ellipseIn: rect), with: .color(figure))
            // warm rim on the lantern (right) side
            ctx.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [warm.opacity(0.5), .clear]),
                                                                  center: CGPoint(x: hx + r * 0.7, y: hy + r * 0.2),
                                                                  startRadius: 0, endRadius: r * 1.3))
            // cool moonlit catchlight, upper-left
            ctx.fill(Path(ellipseIn: CGRect(x: hx - r * 0.55, y: hy - r * 0.7, width: r * 0.5, height: r * 0.5)),
                     with: .color(starLit.opacity(0.5)))
        }

        // dad (tall, left) · mom (bun, right) · two girls leaning together in front.
        head(dx: -22, r: 11,  tilt:  1.5, hair: .plain,    rise: 12)
        head(dx:  22, r: 10,  tilt: -1.5, hair: .bun,      rise: 10)
        head(dx:  -7, r: 7.5, tilt: -2.0, hair: .pigtails, rise: 3)
        head(dx:   8, r: 6.8, tilt:  2.0, hair: .ponytail, rise: 1)
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
