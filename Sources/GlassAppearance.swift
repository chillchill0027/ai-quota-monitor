import SwiftUI
import AppKit

enum DashboardPresentation {
    case window, popover
}

/// Each dashboard window owns one NSGlassEffectView. System-owned popover surfaces
/// can use the transparent branch; older standalone windows need vibrancy.
struct DashboardSurfaceBackground: View {
    let presentation: DashboardPresentation

    @ViewBuilder var body: some View {
        if case .window = presentation {
            if #available(macOS 26.0, *) {
                Color.clear
            } else {
                VisualEffectBackground().ignoresSafeArea()
            }
        } else {
            Color.clear
        }
    }
}

/// A quiet content surface over the shared glass panel, without a second blur/refraction layer.
struct GlassContentSurface: View {
    var cornerRadius: CGFloat = 18
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        Group {
            if reduceTransparency {
                shape.fill(Color(NSColor.controlBackgroundColor))
            } else {
                shape.fill(LinearGradient(
                    colors: colorScheme == .dark
                        ? [.black.opacity(0.16), .black.opacity(0.10)]
                        : [.white.opacity(0.30), .white.opacity(0.14)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .overlay(shape.strokeBorder(
            contrast == .increased ? Color.primary.opacity(0.35) : Color.white.opacity(colorScheme == .dark ? 0.13 : 0.65),
            lineWidth: contrast == .increased ? 1 : 0.5))
        .allowsHitTesting(false)
    }
}

struct GlassControlGroup<Content: View>: View {
    @ViewBuilder var content: Content

    @ViewBuilder var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) { content }
        } else {
            content
        }
    }
}

struct QuotaGlassControl: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
