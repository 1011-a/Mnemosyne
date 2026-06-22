import SwiftUI

/// A warm "Starry Night" live-activity scene. Stars LIGHT UP as files index (their count
/// tracks ingest progress, and they twinkle); a warm horizon glow and crescent moon set a
/// 小王子-ish storybook mood. On the hill, two figures sit in PROFILE gazing up at the
/// sky, while two little girls RUN AND CHASE each other (animated) in front. A generated
/// Canvas scene driven by `IngestProgress`.
struct StarrySkyView: View {
    @Bindable var progress: IngestProgress

    // Palette — warmer night so it reads as illustration, not mud.
    private let skyTop = Color(red: 0.05, green: 0.05, blue: 0.17)
    private let skyMid = Color(red: 0.15, green: 0.11, blue: 0.26)
    private let skyLow = Color(red: 0.30, green: 0.17, blue: 0.27)
    private let horizon = Color(red: 1.00, green: 0.62, blue: 0.36)
    private let starLit = Color(red: 1.00, green: 0.95, blue: 0.82)
    private let starDim = Color(red: 0.62, green: 0.64, blue: 0.82)
    private let moonC = Color(red: 1.00, green: 0.93, blue: 0.78)
    private let hillBack = Color(red: 0.14, green: 0.10, blue: 0.20)
    private let hillFront = Color(red: 0.09, green: 0.07, blue: 0.13)
    private let warm = Color(red: 1.00, green: 0.78, blue: 0.45)
    private let warmDeep = Color(red: 0.96, green: 0.52, blue: 0.28)
    private let bodyC = Color(red: 0.11, green: 0.06, blue: 0.10)      // warm-dark figures
    private let girlC = Color(red: 0.20, green: 0.09, blue: 0.12)      // girls a touch warmer

    private let totalStars = 150

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { tl in   // 20fps for smooth running
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let W = size.width, H = size.height
                let frac = progress.fraction
                let litCount = max(progress.isRunning ? 8 : 4, Int(Double(totalStars) * frac))

                // Sky + warm horizon glow.
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [skyTop, skyMid, skyLow]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: H)))
                ctx.fill(Path(CGRect(x: 0, y: H * 0.55, width: W, height: H * 0.45)),
                         with: .linearGradient(Gradient(colors: [.clear, horizon.opacity(0.18)]),
                                               startPoint: CGPoint(x: 0, y: H * 0.55), endPoint: CGPoint(x: 0, y: H)))

                // Crescent moon.
                let moonR = min(H * 0.15, 28)
                let moon = CGPoint(x: W - moonR * 1.9, y: moonR * 1.6)
                ctx.fill(Path(ellipseIn: CGRect(x: moon.x - moonR, y: moon.y - moonR, width: moonR * 2, height: moonR * 2)),
                         with: .radialGradient(Gradient(colors: [moonC, moonC.opacity(0.85)]), center: moon, startRadius: 0, endRadius: moonR))
                ctx.fill(Path(ellipseIn: CGRect(x: moon.x - moonR * 1.35, y: moon.y - moonR, width: moonR * 2, height: moonR * 2)), with: .color(skyMid))

                // Stars.
                for i in 0..<totalStars {
                    let sx = rnd(i &* 2) * Double(W), sy = rnd(i &* 2 &+ 1) * Double(H) * 0.66
                    let lit = i < litCount
                    let tw = 0.5 + 0.5 * abs(sin(t * 1.4 + Double(i) * 0.7))
                    let r = lit ? (1.1 + 1.4 * tw) : 0.8
                    if lit {
                        ctx.fill(Path(ellipseIn: CGRect(x: sx - r * 2.2, y: sy - r * 2.2, width: r * 4.4, height: r * 4.4)),
                                 with: .radialGradient(Gradient(colors: [starLit.opacity(0.22 * tw), .clear]), center: CGPoint(x: sx, y: sy), startRadius: 0, endRadius: r * 2.2))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2)),
                             with: .color(lit ? starLit.opacity(0.55 + 0.45 * tw) : starDim.opacity(0.35)))
                }

                // Shooting star while running.
                if progress.isRunning {
                    let phase = (t.truncatingRemainder(dividingBy: 6.0)) / 6.0
                    if phase < 0.18 {
                        let p = phase / 0.18, sx = W * (0.15 + 0.6 * p), sy = H * (0.12 + 0.18 * p)
                        var tail = Path(); tail.move(to: CGPoint(x: sx, y: sy)); tail.addLine(to: CGPoint(x: sx - 26, y: sy - 9))
                        ctx.stroke(tail, with: .linearGradient(Gradient(colors: [starLit.opacity(0.9), .clear]),
                                                               startPoint: CGPoint(x: sx, y: sy), endPoint: CGPoint(x: sx - 26, y: sy - 9)), lineWidth: 1.6)
                    }
                }

                // The "wish star" they gaze at.
                let cx = W * 0.5, groundY = H - H * 0.07
                let wish = CGPoint(x: cx - 70, y: H * 0.22)
                let pulse = 0.7 + 0.3 * abs(sin(t * 1.1))
                ctx.fill(Path(ellipseIn: CGRect(x: wish.x - 15, y: wish.y - 15, width: 30, height: 30)),
                         with: .radialGradient(Gradient(colors: [starLit.opacity(0.4 * pulse), .clear]), center: wish, startRadius: 0, endRadius: 15))
                ctx.fill(Path(ellipseIn: CGRect(x: wish.x - 2.4, y: wish.y - 2.4, width: 4.8, height: 4.8)), with: .color(starLit))

                // Hills.
                hillPath(W, baseY: H - H * 0.15, amp: 9, phase: 0.6).map { ctx.fill($0, with: .color(hillBack)) }
                hillPath(W, baseY: H - H * 0.085, amp: 6, phase: 2.1).map { ctx.fill($0, with: .color(hillFront)) }

                // Lantern glow.
                let lan = CGPoint(x: cx + 4, y: groundY - 4)
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 64, y: groundY - 36, width: 150, height: 74)),
                         with: .radialGradient(Gradient(colors: [warm.opacity(0.26), warmDeep.opacity(0.07), .clear]), center: lan, startRadius: 2, endRadius: 90))

                // Two stargazers (profile, looking up) — left of the lantern.
                gazer(&ctx, x: cx - 34, base: groundY, s: 1.18, bun: false, t: t)   // taller
                gazer(&ctx, x: cx - 12, base: groundY, s: 1.00, bun: true,  t: t)   // bun

                // The lantern itself, between the gazers and the playing girls.
                ctx.fill(Path(ellipseIn: CGRect(x: lan.x - 8, y: lan.y - 8, width: 16, height: 16)),
                         with: .radialGradient(Gradient(colors: [warm.opacity(0.95), .clear]), center: lan, startRadius: 0, endRadius: 8))
                ctx.fill(Path(ellipseIn: CGRect(x: lan.x - 1.4, y: lan.y - 2.4, width: 2.8, height: 4.8)), with: .color(warm))

                // Two little girls running & chasing each other — the dynamic bit.
                let run = t * 1.25
                let aX = cx + 40 + 34 * CGFloat(sin(run))            // girl A weaves
                let aDir: CGFloat = cos(run) >= 0 ? 1 : -1
                let bX = aX - 26 * aDir - 4                          // girl B chases, just behind
                let bDir = aDir
                runner(&ctx, x: bX, base: groundY, dir: bDir, phase: run * 6 + 1.0, s: 0.8, pig: true)  // chaser (behind)
                runner(&ctx, x: aX, base: groundY, dir: aDir, phase: run * 6,        s: 0.86, pig: true) // leader (front)

                // HUD.
                ctx.draw(Text("Knowledge indexed").font(.system(size: 11, weight: .semibold)).foregroundStyle(warm.opacity(0.85)), at: CGPoint(x: 14, y: 16), anchor: .topLeading)
                ctx.draw(Text(grouped(progress.libraryItems)).font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(starLit), at: CGPoint(x: 14, y: 28), anchor: .topLeading)
                ctx.draw(Text("\(litCount) stars lit").font(.system(size: 10, weight: .medium)).foregroundStyle(starDim), at: CGPoint(x: 14, y: 62), anchor: .topLeading)
            }
        }
        .frame(height: 320)
        .background(skyTop)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.ColorToken.borderDefault))
    }

    // MARK: figures

    /// A person sitting in PROFILE (facing right), knees up, leaning back, head tilted up
    /// with a little nose — so it clearly reads as "gazing at the sky". Warm rim-lit.
    private func gazer(_ ctx: inout GraphicsContext, x: CGFloat, base baseY: CGFloat, s: CGFloat, bun: Bool, t: Double) {
        let b = baseY + CGFloat(sin(t * 0.9)) * 0.5
        var body = Path()
        body.move(to: CGPoint(x: x - 9 * s, y: b))                                           // back hip on ground
        body.addQuadCurve(to: CGPoint(x: x - 6 * s, y: b - 24 * s), control: CGPoint(x: x - 11 * s, y: b - 12 * s)) // up the leaning back
        body.addQuadCurve(to: CGPoint(x: x - 1 * s, y: b - 29 * s), control: CGPoint(x: x - 7 * s, y: b - 29 * s))  // shoulder
        body.addQuadCurve(to: CGPoint(x: x + 7 * s, y: b - 15 * s), control: CGPoint(x: x + 8 * s, y: b - 26 * s))  // chest/front
        body.addQuadCurve(to: CGPoint(x: x + 14 * s, y: b - 9 * s), control: CGPoint(x: x + 13 * s, y: b - 14 * s)) // thigh→knee
        body.addLine(to: CGPoint(x: x + 15 * s, y: b))                                         // shin→foot
        body.closeSubpath()
        ctx.fill(body, with: .color(bodyC))
        ctx.fill(body, with: .radialGradient(Gradient(colors: [warm.opacity(0.16), .clear]),
                                             center: CGPoint(x: x + 18 * s, y: b - 8 * s), startRadius: 0, endRadius: 30 * s))
        // Head tilted up + a tiny nose pointing skyward.
        let hc = CGPoint(x: x - 4 * s, y: b - 35 * s), hr = 6.4 * s
        ctx.fill(Path(ellipseIn: CGRect(x: hc.x - hr, y: hc.y - hr, width: hr * 2, height: hr * 2)), with: .color(bodyC))
        ctx.fill(Path(ellipseIn: CGRect(x: hc.x + hr * 0.6, y: hc.y - hr * 0.7, width: hr * 0.8, height: hr * 0.7)), with: .color(bodyC)) // nose
        if bun { ctx.fill(Path(ellipseIn: CGRect(x: hc.x - hr * 0.9, y: hc.y - hr * 1.1, width: hr * 0.9, height: hr * 0.9)), with: .color(bodyC)) }
        // warm rim on the head (sky/lantern side) + cool moon catchlight.
        ctx.fill(Path(ellipseIn: CGRect(x: hc.x - hr, y: hc.y - hr, width: hr * 2, height: hr * 2)),
                 with: .radialGradient(Gradient(colors: [warm.opacity(0.5), .clear]), center: CGPoint(x: hc.x + hr * 0.6, y: hc.y), startRadius: 0, endRadius: hr * 1.3))
        ctx.fill(Path(ellipseIn: CGRect(x: hc.x - hr * 0.6, y: hc.y - hr * 0.7, width: hr * 0.45, height: hr * 0.45)), with: .color(starLit.opacity(0.5)))
    }

    /// A little girl running (chibi: big head, flying pigtails, alternating legs). `dir`
    /// is facing/run direction; `phase` drives the stride. Leaves a small dust puff behind.
    private func runner(_ ctx: inout GraphicsContext, x: CGFloat, base baseY: CGFloat, dir: CGFloat, phase: Double, s: CGFloat, pig: Bool) {
        let bob = CGFloat(abs(sin(phase))) * 2.0 * s
        let y = baseY - bob
        let stride = CGFloat(sin(phase))
        // dust puff behind the back foot
        for k in 0..<3 {
            let dp = 0.4 + 0.2 * Double(k)
            ctx.fill(Path(ellipseIn: CGRect(x: x - dir * (10 + CGFloat(k) * 5) * s - 2, y: baseY - 1, width: (4 - CGFloat(k)) * s + 2, height: (4 - CGFloat(k)) * s + 2)),
                     with: .color(warm.opacity(0.12 * dp)))
        }
        // legs (alternating)
        let hipY = y - 9 * s
        for (i, ph) in [stride, -stride].enumerated() {
            var leg = Path(); leg.move(to: CGPoint(x: x, y: hipY))
            leg.addLine(to: CGPoint(x: x + dir * (3 + ph * 5) * s, y: baseY - (i == 0 ? abs(ph) * 3 * s : 0)))
            ctx.stroke(leg, with: .color(girlC), style: StrokeStyle(lineWidth: 2.4 * s, lineCap: .round))
        }
        // body
        ctx.fill(Path(ellipseIn: CGRect(x: x - 4 * s, y: y - 15 * s, width: 8 * s, height: 9 * s)), with: .color(girlC))
        // arms out (swinging)
        var arm = Path(); arm.move(to: CGPoint(x: x, y: y - 12 * s))
        arm.addLine(to: CGPoint(x: x + dir * 6 * s, y: y - 13 * s - stride * 2 * s))
        ctx.stroke(arm, with: .color(girlC), style: StrokeStyle(lineWidth: 2.0 * s, lineCap: .round))
        // head (big) + flying pigtails
        let hc = CGPoint(x: x + dir * 1.5 * s, y: y - 19 * s), hr = 6.5 * s
        if pig {
            for sy: CGFloat in [-1, 0.4] {
                ctx.fill(Path(ellipseIn: CGRect(x: hc.x - dir * (hr + 2) * s, y: hc.y + sy * hr * 0.7 - stride * 2 * s,
                                                width: 5 * s, height: 6 * s)), with: .color(girlC))
            }
        }
        ctx.fill(Path(ellipseIn: CGRect(x: hc.x - hr, y: hc.y - hr, width: hr * 2, height: hr * 2)), with: .color(girlC))
        // warm rim so they pop
        ctx.fill(Path(ellipseIn: CGRect(x: hc.x - hr, y: hc.y - hr, width: hr * 2, height: hr * 2)),
                 with: .radialGradient(Gradient(colors: [warm.opacity(0.45), .clear]), center: CGPoint(x: hc.x + dir * hr * 0.5, y: hc.y), startRadius: 0, endRadius: hr * 1.3))
    }

    private func hillPath(_ W: CGFloat, baseY: CGFloat, amp: CGFloat, phase: Double) -> Path? {
        guard W > 1 else { return nil }
        var p = Path(); p.move(to: CGPoint(x: 0, y: baseY)); var x: CGFloat = 0
        while x <= W { p.addLine(to: CGPoint(x: x, y: baseY - amp * CGFloat(sin(Double(x) / 90.0 + phase)) - amp)); x += 8 }
        p.addLine(to: CGPoint(x: W, y: baseY + 220)); p.addLine(to: CGPoint(x: 0, y: baseY + 220)); p.closeSubpath()
        return p
    }

    private func grouped(_ n: Int) -> String {
        let s = String(n); var out = ""; var c = 0
        for ch in s.reversed() { if c != 0 && c % 3 == 0 { out.append(",") }; out.append(ch); c += 1 }
        return String(out.reversed())
    }

    private func rnd(_ n: Int) -> Double {
        var x = UInt64(bitPattern: Int64(n &* 2654435761)) & 0xFFFFFFFF
        x ^= x >> 13; x = x &* 1274126177; x ^= x >> 16
        return Double(x & 0xFFFF) / 65535.0
    }
}
