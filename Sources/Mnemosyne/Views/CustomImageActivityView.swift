import SwiftUI
import AppKit

/// A live-activity scene that uses YOUR OWN illustration/photo as the backdrop, with
/// twinkling stars (whose count tracks ingest progress) and the indexed-count HUD layered
/// over it. This is the path to book-cover-quality art that procedural drawing can't reach:
/// the beauty comes from a real image, the "live" feeling from the animation on top.
struct CustomImageActivityView: View {
    @Bindable var progress: IngestProgress
    let imagePath: String
    /// Invoked when the user taps to choose / change the image.
    var onChoose: () -> Void

    private let totalStars = 90

    var body: some View {
        ZStack {
            if let image = loadImage() {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 320)
                    .clipped()
                // Live twinkling stars sparkling over the art.
                starOverlay
                // Top scrim so the HUD stays legible over any image.
                LinearGradient(colors: [.black.opacity(0.45), .clear],
                               startPoint: .top, endPoint: .center)
                hud
                // A small, unobtrusive "change image" affordance.
                VStack { Spacer(); HStack {
                    Spacer()
                    Button(action: onChoose) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(7)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain).help("Change backdrop image")
                } }.padding(10)
            } else {
                placeholder
            }
        }
        .frame(height: 320)
        .background(Color(red: 0.04, green: 0.05, blue: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
            .strokeBorder(DS.ColorToken.borderDefault))
    }

    private var starOverlay: some View {
        let lit = max(progress.isRunning ? 6 : 3, Int(Double(totalStars) * progress.fraction))
        return TimelineView(.periodic(from: .now, by: 0.12)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for i in 0..<totalStars where i < lit {
                    let sx = rnd(i &* 2) * Double(size.width)
                    let sy = rnd(i &* 2 &+ 1) * Double(size.height) * 0.7
                    let tw = 0.4 + 0.6 * abs(sin(t * 1.5 + Double(i)))
                    let r = 0.9 + 1.2 * tw
                    ctx.fill(Path(ellipseIn: CGRect(x: sx - r * 2, y: sy - r * 2, width: r * 4, height: r * 4)),
                             with: .radialGradient(Gradient(colors: [.white.opacity(0.5 * tw), .clear]),
                                                   center: CGPoint(x: sx, y: sy), startRadius: 0, endRadius: r * 2))
                    ctx.fill(Path(ellipseIn: CGRect(x: sx - r * 0.6, y: sy - r * 0.6, width: r * 1.2, height: r * 1.2)),
                             with: .color(.white.opacity(0.85 * tw)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Knowledge indexed").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(grouped(progress.libraryItems)).font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
    }

    private var placeholder: some View {
        VStack(spacing: DS.Space.x3) {
            Image(systemName: "photo.badge.plus").font(.system(size: 34, weight: .light))
                .foregroundStyle(DS.ColorToken.textTertiary)
            Text("Choose a backdrop image").font(DS.Typo.body).foregroundStyle(DS.ColorToken.textSecondary)
            Text("Use any illustration or photo — live stars sparkle over it.")
                .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
            DSButton("Choose image…", icon: "photo", kind: .secondary, action: onChoose)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadImage() -> NSImage? {
        guard !imagePath.isEmpty, FileManager.default.fileExists(atPath: imagePath) else { return nil }
        return NSImage(contentsOfFile: imagePath)
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
