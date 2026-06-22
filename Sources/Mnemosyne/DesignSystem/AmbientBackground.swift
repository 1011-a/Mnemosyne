import SwiftUI

/// The signature atmosphere of the app: deep ink with soft nebula glows so no
/// screen ever reads as a flat black rectangle. Place at the back of any root.
public struct AmbientBackground: View {
    var intensity: Double

    public init(intensity: Double = 1.0) { self.intensity = intensity }

    // Airy & flat: just clean paper. No glow, no gradients, no decoration.
    public var body: some View {
        DS.ColorToken.canvas.ignoresSafeArea()
    }
}

extension View {
    /// Place an ambient nebula behind this view.
    public func dsAmbient(_ intensity: Double = 1.0) -> some View {
        background(AmbientBackground(intensity: intensity))
    }
}

/// A faint field of drifting "ink motes" for the Ask hero (design system "Ambient
/// Ask"). At rest they drift; as `energy` rises — 0.45 when the prompt is focused,
/// 1.0 when it has text — they gather into a slowly-rotating ring around `focal`,
/// ~6% of them vermilion, with connective threads and a vermilion focus pulse.
/// Honors Reduce Motion (pauses the drift). DS tokens only.
public struct AmbientMotesField: View {
    var energy: Double
    var focal: UnitPoint
    var count: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(energy: Double, focal: UnitPoint = .center, count: Int = 130) {
        self.energy = energy; self.focal = focal; self.count = count
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { tl in
            Canvas { ctx, size in
                let t = reduceMotion ? 7.0 : tl.date.timeIntervalSinceReferenceDate
                let f = CGPoint(x: size.width * focal.x, y: size.height * focal.y)
                let e = max(0, min(1, energy))
                let ink = DS.ColorToken.textPrimary
                let accent = DS.ColorToken.iris

                for i in 0..<count {
                    let hx = Self.rnd(i * 3) * size.width
                    let hy = Self.rnd(i * 3 + 1) * size.height
                    let speed = 0.2 + Self.rnd(i * 3 + 2) * 0.5
                    let isAccent = Self.rnd(i + 7919) < 0.06
                    // resting Brownian drift
                    let drift = Self.rnd(i) * 2 * .pi + t * 0.3
                    let rx = hx + cos(drift) * 16 + cos(t * speed + hx) * 6
                    let ry = hy + sin(drift * 1.3) * 16 + sin(t * speed + hy) * 6
                    // gather: a slowly-rotating ring around the focus, per-mote radius
                    let ang = (hx + hy) * 0.01 + t * 0.2
                    let ring = 70 + hx.truncatingRemainder(dividingBy: 130)
                    let gx = f.x + cos(ang) * ring
                    let gy = f.y + sin(ang) * ring * 0.6
                    let x = rx + (gx - rx) * e
                    let y = ry + (gy - ry) * e
                    // connective thread from every 3rd mote
                    if e > 0.15, i % 3 == 0 {
                        var thread = Path(); thread.move(to: CGPoint(x: x, y: y)); thread.addLine(to: f)
                        ctx.stroke(thread, with: .color(ink.opacity(0.05 * e)), lineWidth: 1)
                    }
                    let rad = (0.8 + Self.rnd(i * 3 + 5) * 1.8) + e * 0.6
                    let alpha = 0.16 + 0.5 * e
                    ctx.fill(Path(ellipseIn: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2)),
                             with: .color(isAccent ? accent.opacity(min(1, alpha + 0.25)) : ink.opacity(alpha)))
                }
                // focus pulse when active
                if e > 0.2 {
                    let pr = 6 + sin(t * 3) * 2
                    ctx.fill(Path(ellipseIn: CGRect(x: f.x - pr, y: f.y - pr, width: pr * 2, height: pr * 2)),
                             with: .color(accent.opacity(0.18 * e)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func rnd(_ n: Int) -> Double {
        var x = UInt64(bitPattern: Int64(n &* 2654435761)) & 0xFFFFFFFF
        x ^= x >> 13; x = x &* 1274126177; x ^= x >> 16
        return Double(x & 0xFFFF) / 65535.0
    }
}

#Preview("Ambient motes — gathered") {
    AmbientMotesField(energy: 1, focal: UnitPoint(x: 0.5, y: 0.46))
        .frame(width: 600, height: 420)
        .background(DS.ColorToken.canvas)
}
