import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
/// Partner theming for the Zennopay PaymentSheet, mirroring Stripe's
/// `PaymentSheet.Appearance` (design spec §5.1). Partners set colors, corner
/// radius, font, logo, and light/dark so the sheet reads as part of their app —
/// while `DESIGN.md`'s structural rules stay non-overridable.
///
/// **Guardrails (design spec §5 / open decision #3):** corner radii are clamped
/// to ≤ 12px on rectangular surfaces via `RadiusGuard`; the accent-as-state,
/// tabular-nums, and no-gradient rules are enforced by the SDK, not the partner.
///
/// UIKit-only: `UIColor`/`UIImage` are UIKit types, so this whole surface is
/// compiled out on the macOS SwiftPM host (the SDK still builds there; the
/// checkout screens fall back to the built-in `ZTheme.automatic`).
public struct ZennopayAppearance: @unchecked Sendable {

    /// Light/dark resolution strategy. `.automatic` follows the system.
    public enum Mode: Sendable { case automatic, light, dark }

    public var mode: Mode
    public var colors: Colors
    public var cornerRadius: CornerRadius
    public var font: Font
    public var primaryButton: PrimaryButton
    /// Optional partner logo shown in the sheet header.
    public var logo: UIImage?

    /// The palette. Each value applies to both light and dark unless the partner
    /// supplies dynamic (trait-resolving) `UIColor`s. Defaults are the
    /// `DESIGN.md` tokens.
    public struct Colors: Sendable {
        public var primary: UIColor
        public var background: UIColor
        public var surface: UIColor
        public var textPrimary: UIColor
        public var textSecondary: UIColor
        public var textTertiary: UIColor
        public var border: UIColor
        public var success: UIColor
        public var pending: UIColor
        public var failure: UIColor

        public init(
            // Defaults are DYNAMIC (light/dark trait-resolving) `DESIGN.md`
            // tokens, so `.automatic` mode actually follows the system. A
            // partner overriding any slot with a static UIColor gets that
            // color in both modes (pair it with `mode: .light`/`.dark`, or
            // supply their own dynamic colors).
            primary: UIColor = UIColor(zpLight: 0x1B6B2F, zpDark: 0x4DA866),
            background: UIColor = UIColor(zpLight: 0xFAFAF8, zpDark: 0x0F1217),
            surface: UIColor = UIColor(zpLight: 0xFFFFFF, zpDark: 0x1A1E25),
            textPrimary: UIColor = UIColor(zpLight: 0x0A0F14, zpDark: 0xF0F2F4),
            textSecondary: UIColor = UIColor(zpLight: 0x5A6675, zpDark: 0xA0A8B3),
            textTertiary: UIColor = UIColor(zpLight: 0x687280, zpDark: 0x8A93A0),
            border: UIColor = UIColor(zpLight: 0xE8E9EC, zpDark: 0x2A3038),
            success: UIColor = UIColor(zpLight: 0x15803D, zpDark: 0x4DA866),
            pending: UIColor = UIColor(zpLight: 0x7C5E1A, zpDark: 0xC9A24B),
            failure: UIColor = UIColor(zpLight: 0xA53939, zpDark: 0xC26464)
        ) {
            self.primary = primary
            self.background = background
            self.surface = surface
            self.textPrimary = textPrimary
            self.textSecondary = textSecondary
            self.textTertiary = textTertiary
            self.border = border
            self.success = success
            self.pending = pending
            self.failure = failure
        }
    }

    /// Rectangular-surface radii. Defaults 4/8/12; every value is clamped to
    /// ≤ 12px on assignment via the initializer (DESIGN.md anti-slop rule).
    public struct CornerRadius: Sendable {
        public var input: CGFloat
        public var card: CGFloat
        public var slide: CGFloat
        public init(input: CGFloat = 4, card: CGFloat = 8, slide: CGFloat = 12) {
            self.input = RadiusGuard.clamp(input)
            self.card = RadiusGuard.clamp(card)
            self.slide = RadiusGuard.clamp(slide)
        }
    }

    /// Font family + Dynamic-Type scale. `family` defaults to "General Sans";
    /// it must resolve a `tabular-nums` variant (DESIGN.md).
    public struct Font: Sendable {
        public var family: String?
        public var scale: CGFloat
        public init(family: String? = "General Sans", scale: CGFloat = 1) {
            self.family = family
            self.scale = scale
        }
    }

    /// The accent-fill primary action (Review / Done / Try again, and the
    /// slide-to-pay track fill).
    public struct PrimaryButton: Sendable {
        public var background: UIColor
        public var textColor: UIColor
        public var cornerRadius: CGFloat
        public init(
            background: UIColor = UIColor(zpRGB: 0x1B6B2F),
            textColor: UIColor = UIColor(zpRGB: 0xFFFFFF),
            cornerRadius: CGFloat = 8
        ) {
            self.background = background
            self.textColor = textColor
            self.cornerRadius = RadiusGuard.clamp(cornerRadius)
        }
    }

    public init(
        mode: Mode = .automatic,
        colors: Colors = Colors(),
        cornerRadius: CornerRadius = CornerRadius(),
        font: Font = Font(),
        primaryButton: PrimaryButton = PrimaryButton(),
        logo: UIImage? = nil
    ) {
        self.mode = mode
        self.colors = colors
        // Re-clamp defensively in case a caller mutated the struct's radii after
        // construction (public `var`s bypass the CornerRadius init otherwise).
        self.cornerRadius = CornerRadius(
            input: cornerRadius.input,
            card: cornerRadius.card,
            slide: cornerRadius.slide
        )
        self.font = font
        self.primaryButton = primaryButton
        self.logo = logo
    }

    /// The default look: `DESIGN.md` tokens with system light/dark. A partner
    /// who passes nothing gets the bank-solid Zennopay appearance.
    public static let automatic = ZennopayAppearance()

    /// Alias for `.automatic` (Stripe-style spelling).
    public static let `default` = ZennopayAppearance()
}

extension UIColor {
    /// Build an opaque `UIColor` from a packed `0xRRGGBB` value.
    public convenience init(zpRGB rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Build a DYNAMIC (light/dark trait-resolving) `UIColor` from packed
    /// `0xRRGGBB` values. Used for the default appearance palette so
    /// `.automatic` mode follows the system.
    public convenience init(zpLight: UInt32, zpDark: UInt32) {
        self.init { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(zpRGB: zpDark) : UIColor(zpRGB: zpLight)
        }
    }
}
#endif
