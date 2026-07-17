#if canImport(SwiftUI)
import SwiftUI

/// Slide-to-pay control per the partner-approved reference: a filled pill
/// track with a round white knob that carries the accent arrow. Dragging past
/// the end fires `onConfirm` exactly once (the parent view model also guards
/// single-fire); while the confirm+poll runs the knob pins to the track end
/// and becomes a spinner (reference f22). Honors `prefers-reduced-motion` by
/// snapping instead of animating; VoiceOver users confirm via a custom action.
@available(iOS 14.0, macOS 13.0, *)
struct SlideToConfirm: View {
    let label: String
    var theme: ZTheme = .automatic
    /// When true the control is inert (amount invalid / over limit): the track
    /// greys out and the gesture is ignored. Accessibility marks it disabled.
    var isDisabled: Bool = false
    /// When true the knob pins to the end and shows a spinner (confirm+poll in
    /// flight). The gesture is ignored.
    var isConfirming: Bool = false
    let onConfirm: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragX: CGFloat = 0
    @State private var confirmed = false

    private let knobSize: CGFloat = 56
    private let trackHeight: CGFloat = 68
    private let inset: CGFloat = 6

    private var spinning: Bool { isConfirming || confirmed }

    var body: some View {
        GeometryReader { geo in
            let maxX = geo.size.width - knobSize - inset * 2
            let x = spinning ? maxX : dragX
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(isDisabled ? theme.text3.opacity(0.4) : theme.primaryButtonBackground)

                if !spinning {
                    Text(label)
                        .zpSystemFont(17, .semibold)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundColor(theme.primaryButtonTextColor)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, knobSize + inset)
                        .opacity(1 - Double(x / max(maxX, 1)))
                }

                knob
                    .offset(x: inset + x)
                    .gesture(dragGesture(maxX: maxX))
                    .accessibilityIdentifier("zp.slide.handle")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(spinning ? "Processing payment" : label)
                    // The default custom action IS the VoiceOver activation
                    // fallback: double-tap confirms without performing the
                    // drag (sliding is not VoiceOver-operable).
                    .accessibilityHint(
                        isDisabled || spinning ? "" : "Double tap to confirm the payment"
                    )
                    .accessibilityAction {
                        // VoiceOver users confirm without performing the drag.
                        guard !isDisabled, !spinning else { return }
                        confirmed = true
                        onConfirm()
                    }
            }
            .frame(height: trackHeight)
        }
        .frame(height: trackHeight)
        .opacity(isDisabled ? 0.6 : 1)
        .allowsHitTesting(!isDisabled && !spinning)
    }

    private var knob: some View {
        Circle()
            .fill(Color.white)
            .frame(width: knobSize, height: knobSize)
            .overlay(
                Group {
                    if spinning {
                        ProgressView().tint(theme.accent)
                    } else {
                        Image(systemName: "chevron.right")
                            .foregroundColor(theme.accent)
                            .font(.system(size: 20, weight: .bold))
                    }
                }
            )
            .shadow(color: Color.black.opacity(0.15), radius: 3, y: 1)
    }

    private func dragGesture(maxX: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !confirmed, !isDisabled, !isConfirming else { return }
                dragX = min(max(0, value.translation.width), maxX)
            }
            .onEnded { _ in
                guard !confirmed, !isDisabled, !isConfirming else { return }
                if dragX >= maxX * 0.9 {
                    confirmed = true
                    dragX = maxX
                    onConfirm()
                } else if reduceMotion {
                    dragX = 0
                } else {
                    // Mass-spring decay back to origin — the "metal latch"
                    // feel. Never a linear snap.
                    withAnimation(.interpolatingSpring(stiffness: 180, damping: 18)) {
                        dragX = 0
                    }
                }
            }
    }
}
#endif
