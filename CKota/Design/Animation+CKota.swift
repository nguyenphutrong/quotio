import AppKit
import SwiftUI

// MARK: - CKota Animation Presets

extension Animation {
    /// 0.1s easeOut - Hover states, button press
    static let ckMicro = Animation.easeOut(duration: 0.1)

    /// 0.15s easeOut - Navigation, toggles, tabs
    static let ckStandard = Animation.easeOut(duration: 0.15)

    /// 0.2s easeInOut - Card expand, modal open
    static let ckExpand = Animation.easeInOut(duration: 0.2)

    /// Spring animation - Success feedback, attention
    static let ckEmphasis = Animation.spring(response: 0.3, dampingFraction: 0.6)
}

// MARK: - Pulse Animation (Live Status)

struct PulseAnimation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(0.6)
        } else {
            content
                .scaleEffect(isAnimating ? 1.8 : 1.0)
                .opacity(isAnimating ? 0 : 1)
                .animation(
                    .easeOut(duration: 1.5)
                        .repeatForever(autoreverses: false),
                    value: isAnimating
                )
                .onAppear { isAnimating = true }
        }
    }
}

// MARK: - Shimmer Animation (Loading)

struct ShimmerAnimation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                Group {
                    if !reduceMotion {
                        LinearGradient(
                            gradient: Gradient(colors: [
                                .clear,
                                Color.ckBorder.opacity(0.3),
                                .clear,
                            ]),
                            startPoint: .init(x: phase - 0.5, y: 0.5),
                            endPoint: .init(x: phase + 0.5, y: 0.5)
                        )
                    }
                }
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
    }
}

// MARK: - Reduced Motion Support

/// View modifier that conditionally applies animation based on reduce motion setting
struct CKAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Applies animation only when reduce motion is disabled (responds to live setting changes)
    func ckAnimation(_ animation: Animation?, value: some Equatable) -> some View {
        modifier(CKAnimationModifier(animation: animation, value: value))
    }
}
