#if canImport(SwiftUI)
import SwiftUI

/// Dynamic Type support for the themed screens.
///
/// `ZTheme.font(_:_:)` resolves a *fixed*-size font (system or partner family)
/// — on its own it ignores the user's content-size setting. Every text role in
/// the PaymentSheet therefore goes through the `.zpFont(...)` modifier below,
/// which reads the environment's `sizeCategory` and multiplies the DESIGN.md
/// point size by the platform Dynamic Type curve (anchored on the body style:
/// 17pt at `.large`).
///
/// The scale is CAPPED so accessibility sizes stay usable without destroying
/// the fixed-chrome layout (slide-to-pay, keypad, hero + card must all remain
/// reachable):
///   - regular text caps at the accessibility-medium multiplier (~1.65×)
///   - hero / display numerals cap earlier (~1.35×, the XXXL multiplier) —
///     they are already the largest thing on screen and additionally carry
///     `minimumScaleFactor` floors for long amounts.
enum ZTypeScale {

    /// Multiplier ceiling for regular text: the accessibility-medium body
    /// size (28pt) relative to the default body (17pt).
    static let regularMaxMultiplier: CGFloat = 28.0 / 17.0
    /// Multiplier ceiling for hero/display numerals: the XXXL body size
    /// (23pt) relative to the default body (17pt).
    static let heroMaxMultiplier: CGFloat = 23.0 / 17.0

    /// Apple's body-style point size for each content size category, relative
    /// to `.large` (17pt). Pure + platform-neutral so it is unit-testable on
    /// the macOS SwiftPM host.
    static func multiplier(for category: ContentSizeCategory) -> CGFloat {
        let bodyPoints: CGFloat
        switch category {
        case .extraSmall:                        bodyPoints = 14
        case .small:                             bodyPoints = 15
        case .medium:                            bodyPoints = 16
        case .large:                             bodyPoints = 17
        case .extraLarge:                        bodyPoints = 19
        case .extraExtraLarge:                   bodyPoints = 21
        case .extraExtraExtraLarge:              bodyPoints = 23
        case .accessibilityMedium:               bodyPoints = 28
        case .accessibilityLarge:                bodyPoints = 33
        case .accessibilityExtraLarge:           bodyPoints = 40
        case .accessibilityExtraExtraLarge:      bodyPoints = 47
        case .accessibilityExtraExtraExtraLarge: bodyPoints = 53
        @unknown default:                        bodyPoints = 17
        }
        return bodyPoints / 17.0
    }

    /// Scale a DESIGN.md point size for the user's content size category,
    /// clamped to `maxMultiplier`. Never scales below the smallest platform
    /// multiplier (extra-small, ~0.82×).
    static func scaled(
        _ size: CGFloat,
        category: ContentSizeCategory,
        maxMultiplier: CGFloat = ZTypeScale.regularMaxMultiplier
    ) -> CGFloat {
        let m = min(multiplier(for: category), maxMultiplier)
        return (size * m).rounded()
    }
}

/// Applies a theme font scaled for the current Dynamic Type setting.
@available(iOS 14.0, macOS 13.0, *)
private struct ZPFontModifier: ViewModifier {
    @Environment(\.sizeCategory) private var sizeCategory
    let theme: ZTheme
    let size: CGFloat
    let weight: Font.Weight
    let maxMultiplier: CGFloat

    func body(content: Content) -> some View {
        content.font(
            theme.font(
                ZTypeScale.scaled(size, category: sizeCategory, maxMultiplier: maxMultiplier),
                weight
            )
        )
    }
}

/// Applies a Dynamic-Type-scaled *system* font (used on the scanner's white
/// chrome, which does not take the partner theme).
@available(iOS 14.0, macOS 13.0, *)
private struct ZPSystemFontModifier: ViewModifier {
    @Environment(\.sizeCategory) private var sizeCategory
    let size: CGFloat
    let weight: Font.Weight
    let maxMultiplier: CGFloat

    func body(content: Content) -> some View {
        content.font(
            .system(
                size: ZTypeScale.scaled(size, category: sizeCategory, maxMultiplier: maxMultiplier),
                weight: weight
            )
        )
    }
}

@available(iOS 14.0, macOS 13.0, *)
extension View {
    /// Themed text that honors Dynamic Type (capped; see `ZTypeScale`).
    /// `hero: true` uses the earlier display-numeral cap.
    func zpFont(
        _ theme: ZTheme, _ size: CGFloat, _ weight: Font.Weight = .regular,
        hero: Bool = false
    ) -> some View {
        modifier(ZPFontModifier(
            theme: theme, size: size, weight: weight,
            maxMultiplier: hero ? ZTypeScale.heroMaxMultiplier : ZTypeScale.regularMaxMultiplier
        ))
    }

    /// System-font text (scanner chrome) that honors Dynamic Type (capped).
    func zpSystemFont(
        _ size: CGFloat, _ weight: Font.Weight = .regular, hero: Bool = false
    ) -> some View {
        modifier(ZPSystemFontModifier(
            size: size, weight: weight,
            maxMultiplier: hero ? ZTypeScale.heroMaxMultiplier : ZTypeScale.regularMaxMultiplier
        ))
    }
}

/// Horizontal shake used when keypad input is refused (over the per-payment
/// limit). Drive by incrementing a trigger value inside `withAnimation`.
@available(iOS 13.0, macOS 13.0, *)
struct ShakeEffect: GeometryEffect {
    /// Peak travel in points.
    var travel: CGFloat = 6
    /// Full oscillations per unit of `animatableData`.
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: travel * sin(animatableData * .pi * shakes * 2), y: 0
            )
        )
    }
}
#endif
