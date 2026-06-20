import SwiftUI

// MARK: - Shell-level design-system components
// Added in M6 for the app shell. Mirror these as cards in DesignKit and re-sync.

// (NavRail removed in the Swiss redesign — navigation is a top bar now.)

// MARK: OmniPrompt — the central AI input bar

public struct OmniPrompt: View {
    @Binding var text: String
    var placeholder: String
    var isBusy: Bool
    /// Bump this value to programmatically focus the field (e.g. ⌘K).
    var focusRequest: Int
    var onSend: () -> Void
    var onStop: () -> Void
    @FocusState private var focused: Bool

    public init(text: Binding<String>, placeholder: String = "Ask your knowledge…",
                isBusy: Bool, focusRequest: Int = 0,
                onSend: @escaping () -> Void, onStop: @escaping () -> Void) {
        self._text = text; self.placeholder = placeholder; self.isBusy = isBusy
        self.focusRequest = focusRequest; self.onSend = onSend; self.onStop = onStop
    }

    public var body: some View {
        // Center-align so a single-line prompt sits vertically centered in the bar
        // (with `.bottom` the placeholder dropped to the bottom edge). It still reads
        // well when the field grows to multiple lines.
        HStack(alignment: .center, spacing: DS.Space.x3) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Typo.body)
                .foregroundStyle(DS.ColorToken.textPrimary)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
                .onChange(of: focusRequest) { _, _ in focused = true }

            Button(action: isBusy ? onStop : send) {
                Image(systemName: isBusy ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(DS.Gradient.intelligence, in: Circle())
                    .dsShadow(DS.Elevation.glow)
                    .opacity(text.isEmpty && !isBusy ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty && !isBusy)
        }
        .padding(.horizontal, DS.Space.x5)
        .padding(.vertical, DS.Space.x4)
        .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .strokeBorder(focused ? DS.ColorToken.iris : DS.ColorToken.borderStrong,
                              lineWidth: focused ? 2 : 1)
        )
        .animation(DS.Motion.base, value: focused)
    }

    private func send() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSend()
    }
}

// MARK: KnowledgeCard — one ingested item in the library grid

public struct KnowledgeCard: View {
    var icon: String
    var kindLabel: String
    var title: String
    var summary: String
    var meta: String
    var citedCount: Int
    var thumbnail: NSImage?
    @State private var hovering = false

    public init(icon: String, kindLabel: String, title: String, summary: String,
                meta: String, citedCount: Int = 0, thumbnail: NSImage? = nil) {
        self.icon = icon; self.kindLabel = kindLabel; self.title = title
        self.summary = summary; self.meta = meta; self.citedCount = citedCount
        self.thumbnail = thumbnail
    }

    public var body: some View {
        GlassPanel(radius: DS.Radius.lg, elevation: hovering ? DS.Elevation.e3 : DS.Elevation.e2) {
            VStack(alignment: .leading, spacing: DS.Space.x3) {
                HStack(spacing: DS.Space.x2) {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        Image(systemName: icon).foregroundStyle(DS.ColorToken.iris)
                    }
                    Text(kindLabel.uppercased()).font(DS.Typo.caption)
                        .foregroundStyle(DS.ColorToken.textTertiary)
                    Spacer()
                    if citedCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "quote.bubble").font(.system(size: 9))
                            Text("\(citedCount)").font(DS.Typo.caption)
                        }
                        .foregroundStyle(DS.ColorToken.provenance)
                        .padding(.horizontal, DS.Space.x2).padding(.vertical, 1)
                        .background(DS.ColorToken.provenance.opacity(0.12), in: Capsule())
                    }
                }
                Text(title).font(DS.Typo.title3).foregroundStyle(DS.ColorToken.textPrimary)
                    .lineLimit(1)
                Text(summary).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                Text(meta).font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
            }
            .padding(DS.Space.x4)
            .frame(height: 168, alignment: .top)
        }
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(DS.Motion.snappy, value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: ProgressRing — circular ingestion progress

public struct ProgressRing: View {
    var fraction: Double
    var size: CGFloat
    var lineWidth: CGFloat

    public init(fraction: Double, size: CGFloat = 64, lineWidth: CGFloat = 7) {
        self.fraction = fraction; self.size = size; self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle().stroke(DS.ColorToken.borderDefault, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(DS.Gradient.intelligence,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(DS.Motion.smooth, value: fraction)
            Text("\(Int(fraction * 100))%")
                .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textSecondary)
        }
        .frame(width: size, height: size)
    }
}

// MARK: StatCard — a headline metric tile for the Insights dashboard

public struct StatCard: View {
    var value: String
    var label: String
    var icon: String
    public init(value: String, label: String, icon: String) {
        self.value = value; self.label = label; self.icon = icon
    }
    public var body: some View {
        GlassPanel(radius: DS.Radius.lg, elevation: DS.Elevation.e2) {
            VStack(alignment: .leading, spacing: DS.Space.x2) {
                Image(systemName: icon).font(.system(size: 16))
                    .foregroundStyle(DS.ColorToken.iris)
                Text(value).font(DS.Typo.statBig).foregroundStyle(DS.ColorToken.textPrimary)
                    .contentTransition(.numericText())
                Text(label).font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.x5)
        }
    }
}

// MARK: StatBar — a labelled proportional bar (kind breakdown)

public struct StatBar: View {
    var label: String
    var icon: String
    var count: Int
    var fraction: Double
    public init(label: String, icon: String, count: Int, fraction: Double) {
        self.label = label; self.icon = icon; self.count = count; self.fraction = fraction
    }
    public var body: some View {
        HStack(spacing: DS.Space.x3) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(DS.ColorToken.textTertiary)
                .frame(width: 18)
            Text(label).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
                .frame(width: 120, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.ColorToken.surfaceRaised)
                    Capsule().fill(DS.Gradient.intelligence)
                        .frame(width: max(6, geo.size.width * fraction))
                }
            }
            .frame(height: 10)
            Text("\(count)").font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.ColorToken.textTertiary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: Sparkline — compact per-bucket activity bars

public struct Sparkline: View {
    var values: [Int]
    var height: CGFloat
    public init(values: [Int], height: CGFloat = 48) {
        self.values = values; self.height = height
    }
    public var body: some View {
        let maxV = CGFloat(max(values.max() ?? 1, 1))
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(values.indices, id: \.self) { i in
                Capsule()
                    .fill(DS.Gradient.intelligence)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, CGFloat(values[i]) / maxV * height))
                    .opacity(values[i] == 0 ? 0.18 : 1)
            }
        }
        .frame(height: height, alignment: .bottom)
    }
}

// MARK: StatusDot — service health indicator

public struct StatusDot: View {
    var ok: Bool
    var label: String
    public init(ok: Bool, label: String) { self.ok = ok; self.label = label }
    public var body: some View {
        HStack(spacing: DS.Space.x2) {
            Circle()
                .fill(ok ? DS.ColorToken.success : DS.ColorToken.danger)
                .frame(width: 8, height: 8)
                .dsShadow(DS.Shadow(color: (ok ? DS.ColorToken.success : DS.ColorToken.danger).opacity(0.6),
                                    radius: 6, x: 0, y: 0))
            Text(label).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
        }
    }
}
