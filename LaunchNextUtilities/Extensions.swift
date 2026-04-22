import SwiftUI
import AppKit

// MARK: - Color Extensions
public extension Color {
    static var launchpadBorder: Color {
        Color(.systemBlue)
    }
}

// MARK: - Font Extensions
public extension Font {
    static var launchpadDefault: Font {
        .system(size: 11, weight: .medium)
    }
}

// MARK: - View Extensions for Glass Effect
public extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, isEnabled: Bool = true) -> some View {
        if #available(macOS 26.0, iOS 18.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func liquidGlass(isEnabled: Bool = true) -> some View {
        if #available(macOS 26.0, iOS 18.0, *) {
            self.glassEffect(.regular)
        } else {
            self.background(.ultraThinMaterial)
        }
    }
}
