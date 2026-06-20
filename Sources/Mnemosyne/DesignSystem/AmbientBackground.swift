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
