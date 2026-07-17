#if canImport(SwiftUI)
import SwiftUI

/// Swift translation of `DESIGN.md`. All colors, spacing, radii, and motion
/// specs come from that doc — do not introduce values not defined there.
/// "Felt as solid as a real bank": typography carries the load, accent is a
/// state signal only.
@available(iOS 13.0, macOS 13.0, *)
enum ZTokens {

    // MARK: Color (light / dark pairs from DESIGN.md)

    static let bg       = dynamic(light: 0xFAFAF8, dark: 0x0F1217)
    static let surface  = dynamic(light: 0xFFFFFF, dark: 0x1A1E25)
    static let text     = dynamic(light: 0x0A0F14, dark: 0xF0F2F4)
    static let text2    = dynamic(light: 0x5A6675, dark: 0xA0A8B3)
    // text3 tuned 2026-07-17 for WCAG AA on fine print (was 0x8A949F/0x6B7480,
    // which measured 2.95:1 / 3.53:1 against surface): now ≥4.5:1 on both bg
    // and surface in both modes while staying below text2 for hierarchy.
    static let text3    = dynamic(light: 0x687280, dark: 0x8A93A0)
    static let border   = dynamic(light: 0xE8E9EC, dark: 0x2A3038)
    static let accent   = dynamic(light: 0x1B6B2F, dark: 0x4DA866)
    static let success  = dynamic(light: 0x15803D, dark: 0x4DA866)
    static let pending  = dynamic(light: 0x7C5E1A, dark: 0xC9A24B)
    static let failure  = dynamic(light: 0xA53939, dark: 0xC26464)
    /// 8% (light) / 12% (dark) tint of failure — the circular halo behind the
    /// failure glyph. Background only, never a text/surface fill (DESIGN.md).
    static let failureSoft = dynamicAlpha(light: (0xA53939, 0.08), dark: (0xC26464, 0.12))

    // MARK: Spacing (4px base unit)

    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48

    // MARK: Radius (max 12px on rectangular surfaces)

    static let radiusInput: CGFloat = 4
    static let radiusCard: CGFloat = 8
    static let radiusSlide: CGFloat = 12

    // MARK: Motion (durations in seconds)

    static let durMicro = 0.10
    static let durShort = 0.20
    static let durMedium = 0.35

    /// ease-out-expo for entrances.
    static var easeOutExpo: Animation { .timingCurve(0.16, 1, 0.3, 1, duration: durShort) }
    /// state-change curve.
    static var stateChange: Animation { .timingCurve(0.4, 0, 0.2, 1, duration: durShort) }

    // MARK: - Helpers

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
        #else
        return Color(rgb: light)
        #endif
    }

    private static func dynamicAlpha(light: (UInt32, Double), dark: (UInt32, Double)) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { trait in
            let (rgb, a) = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(rgb: rgb).withAlphaComponent(a)
        })
        #else
        return Color(rgb: light.0).opacity(light.1)
        #endif
    }
}

/// The palette actually consumed by the SwiftUI screens. Resolved either from
/// the built-in `DESIGN.md` tokens (`.automatic`) or, when a partner supplies a
/// `ZennopayAppearance`, from that appearance. Screens read colors + radii from
/// a `ZTheme` value threaded down from the view model; spacing and motion stay
/// on `ZTokens` (they are not partner-themeable).
@available(iOS 13.0, macOS 13.0, *)
struct ZTheme {
    var bg: Color
    var surface: Color
    var text: Color
    var text2: Color
    var text3: Color
    var border: Color
    var accent: Color
    var success: Color
    var pending: Color
    var failure: Color
    var failureSoft: Color

    var radiusInput: CGFloat
    var radiusCard: CGFloat
    var radiusSlide: CGFloat

    var primaryButtonBackground: Color
    var primaryButtonTextColor: Color
    var primaryButtonRadius: CGFloat

    /// nil = follow the system; forced for `.light`/`.dark` appearance modes.
    var forcedColorScheme: ColorScheme?

    /// Partner font-family override (`ZennopayAppearance.Font.family`). Nil or
    /// an unresolvable name falls back to the system font.
    var fontFamily: String? = nil

    /// Themed font: the partner family when set, else the system font. Numeric
    /// display should additionally apply `.monospacedDigit()` at the call site.
    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let fontFamily, !fontFamily.isEmpty {
            return .custom(fontFamily, size: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    /// The default `DESIGN.md` theme (system light/dark). Available on every
    /// host so the macOS build and the iOS default both resolve without UIKit.
    static let automatic = ZTheme(
        bg: ZTokens.bg, surface: ZTokens.surface, text: ZTokens.text,
        text2: ZTokens.text2, text3: ZTokens.text3, border: ZTokens.border,
        accent: ZTokens.accent, success: ZTokens.success, pending: ZTokens.pending,
        failure: ZTokens.failure, failureSoft: ZTokens.failureSoft,
        radiusInput: ZTokens.radiusInput, radiusCard: ZTokens.radiusCard,
        radiusSlide: ZTokens.radiusSlide,
        primaryButtonBackground: ZTokens.accent, primaryButtonTextColor: .white,
        primaryButtonRadius: ZTokens.radiusCard,
        forcedColorScheme: nil
    )
}

#if canImport(UIKit)
@available(iOS 13.0, macOS 13.0, *)
extension ZTheme {
    /// Resolve a partner `ZennopayAppearance` (UIColor-based) into the SwiftUI
    /// palette the screens render. Radii are re-clamped here as the definitive
    /// guardrail (a partner may have mutated the struct past the CornerRadius
    /// initializer's clamp).
    init(appearance: ZennopayAppearance) {
        let c = appearance.colors
        self.bg = Color(c.background)
        self.surface = Color(c.surface)
        self.text = Color(c.textPrimary)
        self.text2 = Color(c.textSecondary)
        self.text3 = Color(c.textTertiary)
        self.border = Color(c.border)
        self.accent = Color(c.primary)
        self.success = Color(c.success)
        self.pending = Color(c.pending)
        self.failure = Color(c.failure)
        // DESIGN.md: 8% light / 12% dark tint of failure for the icon halo.
        self.failureSoft = Color(UIColor { trait in
            c.failure.resolvedColor(with: trait).withAlphaComponent(
                trait.userInterfaceStyle == .dark ? 0.12 : 0.08
            )
        })
        self.radiusInput = RadiusGuard.clamp(appearance.cornerRadius.input)
        self.radiusCard = RadiusGuard.clamp(appearance.cornerRadius.card)
        self.radiusSlide = RadiusGuard.clamp(appearance.cornerRadius.slide)
        self.primaryButtonBackground = Color(appearance.primaryButton.background)
        self.primaryButtonTextColor = Color(appearance.primaryButton.textColor)
        self.primaryButtonRadius = RadiusGuard.clamp(appearance.primaryButton.cornerRadius)
        // "General Sans" is the DESIGN.md default label, not a bundled font —
        // treat it as "system" unless the partner ships a real family.
        let family = appearance.font.family
        self.fontFamily = (family == "General Sans") ? nil : family
        switch appearance.mode {
        case .automatic: self.forcedColorScheme = nil
        case .light: self.forcedColorScheme = .light
        case .dark: self.forcedColorScheme = .dark
        }
    }
}
#endif

#if canImport(UIKit)
import UIKit
extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif

@available(iOS 13.0, macOS 13.0, *)
extension Color {
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
#endif
