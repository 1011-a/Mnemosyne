import SwiftUI

// MARK: - Core design-system components
// Every page composes from these. When a page needs something new, add it
// here (and a preview card in DesignKit) rather than styling inline.

// MARK: GlassPanel — the base raised surface (translucent, hairline, sheen)

public struct GlassPanel<Content: View>: View {
    var radius: CGFloat
    var elevation: DS.Shadow
    @ViewBuilder var content: Content

    public init(radius: CGFloat = DS.Radius.lg,
                elevation: DS.Shadow = DS.Elevation.e2,
                @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.elevation = elevation
        self.content = content()
    }

    public var body: some View {
        content
            // Flat Swiss card: solid white, crisp hairline, barely-there shadow.
            .background(DS.ColorToken.surface,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1)
            )
            .dsShadow(elevation)
    }
}

// MARK: Buttons

public enum DSButtonKind { case primary, secondary, ghost }

public struct DSButton: View {
    var title: String
    var icon: String?
    var kind: DSButtonKind
    var action: () -> Void
    @State private var hovering = false

    public init(_ title: String, icon: String? = nil,
                kind: DSButtonKind = .primary, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.kind = kind; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.x2) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(DS.Typo.bodyMed)
            .foregroundStyle(foreground)
            .padding(.horizontal, DS.Space.x4)
            .padding(.vertical, DS.Space.x3)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .dsShadow(kind == .primary ? DS.Elevation.glow : DS.Elevation.e1)
            .scaleEffect(hovering ? 1.02 : 1.0)
            .animation(DS.Motion.snappy, value: hovering)
        }
        .buttonStyle(.plain)
        // Our buttons carry their own hover/fill states; suppress the macOS blue
        // keyboard-focus ring so the only accent on screen is the vermilion.
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .primary:   DS.Gradient.intelligence
        case .secondary: DS.ColorToken.surfaceOverlay
        case .ghost:     Color.clear
        }
    }
    private var foreground: Color {
        switch kind {
        case .primary:   return .white
        case .secondary: return DS.ColorToken.textPrimary
        case .ghost:     return DS.ColorToken.textSecondary
        }
    }
    private var borderColor: Color {
        switch kind {
        case .primary:   return .clear
        case .secondary: return DS.ColorToken.borderDefault
        case .ghost:     return DS.ColorToken.borderSubtle
        }
    }
}

// MARK: AIOrb — the "presence" of the assistant; animates while thinking

public struct AIOrb: View {
    var size: CGFloat
    var active: Bool
    @State private var phase = false

    public init(size: CGFloat = 28, active: Bool = false) {
        self.size = size; self.active = active
    }

    public var body: some View {
        ZStack {
            // Soft outer halo of light.
            Circle()
                .fill(DS.ColorToken.magenta)
                .frame(width: size * 1.5, height: size * 1.5)
                .blur(radius: size * 0.45)
                .opacity(active ? (phase ? 0.55 : 0.32) : 0.30)

            // The orb body with a rotating nebula sheen.
            Circle()
                .fill(DS.Gradient.aurora)
                .overlay(
                    Circle().fill(
                        AngularGradient(colors: [.white.opacity(0.35), .clear, .white.opacity(0.18), .clear],
                                        center: .center,
                                        angle: .degrees(phase ? 360 : 0)))
                    .blendMode(.overlay)
                )
                .overlay(
                    // Specular highlight (lit from upper-left).
                    Circle().fill(.white.opacity(0.5))
                        .frame(width: size * 0.28, height: size * 0.28)
                        .blur(radius: size * 0.08)
                        .offset(x: -size * 0.18, y: -size * 0.2)
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                .frame(width: size, height: size)
                .scaleEffect(active && phase ? 1.06 : 1.0)
        }
        .onAppear {
            guard active else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { phase = true }
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) { /* rotation via phase */ }
        }
    }
}

// MARK: ThinkingIndicator — three pulsing dots in the accent gradient

public struct ThinkingIndicator: View {
    @State private var t = 0
    private let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()
    public init() {}
    public var body: some View {
        HStack(spacing: DS.Space.x1) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(DS.ColorToken.iris)
                    .frame(width: 6, height: 6)
                    .opacity(t % 3 == i ? 1.0 : 0.3)
            }
        }
        .onReceive(timer) { _ in t &+= 1 }
        .animation(DS.Motion.fast, value: t)
    }
}

// MARK: CitationChip — provenance is first-class in an AI-native app

public struct CitationChip: View {
    var index: Int
    var title: String
    public init(index: Int, title: String) { self.index = index; self.title = title }
    public var body: some View {
        HStack(spacing: DS.Space.x1) {
            Text("\(index)")
                .font(DS.Typo.caption)
                .foregroundStyle(DS.ColorToken.canvas)
                .frame(width: 16, height: 16)
                .background(DS.ColorToken.provenance, in: Circle())
            Text(title)
                .font(DS.Typo.caption)
                .foregroundStyle(DS.ColorToken.provenance)
                .lineLimit(1)
        }
        .padding(.horizontal, DS.Space.x2)
        .padding(.vertical, DS.Space.x1)
        .background(DS.ColorToken.provenance.opacity(0.10),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(DS.ColorToken.provenance.opacity(0.30), lineWidth: 1))
    }
}

// MARK: ChatBubble

public enum ChatRole { case user, assistant }

public struct ChatBubble<Content: View>: View {
    var role: ChatRole
    @ViewBuilder var content: Content
    public init(role: ChatRole, @ViewBuilder content: () -> Content) {
        self.role = role; self.content = content()
    }
    public var body: some View {
        // The user's question reads as a quiet, flat prompt — ink on faint
        // paper, right-aligned, no heavy bubble.
        content
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(DS.ColorToken.textPrimary)
            .multilineTextAlignment(.trailing)
            .padding(.vertical, DS.Space.x2)
            .padding(.horizontal, DS.Space.x4)
            .background(DS.ColorToken.canvasRaised,
                        in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            .frame(maxWidth: 520, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: SectionHeader

public struct SectionHeader: View {
    var title: String
    var subtitle: String?
    public init(_ title: String, subtitle: String? = nil) {
        self.title = title; self.subtitle = subtitle
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x1) {
            Text(title).font(DS.Typo.title3).foregroundStyle(DS.ColorToken.textPrimary)
            if let subtitle {
                Text(subtitle).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textTertiary)
            }
        }
    }
}
